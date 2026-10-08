import Foundation
import Synchronization

/// Live counters a UI can poll while a scan runs.
public struct ScanProgress: Sendable {
    public var files: Int
    public var folders: Int
    public var bytes: Int64

    public init(files: Int, folders: Int, bytes: Int64) {
        self.files = files
        self.folders = folders
        self.bytes = bytes
    }
}

/// Scans a folder tree with a pool of threads, each reading whole directories with
/// `getattrlistbulk`. Stays on the starting volume, doesn't follow symlinks, and
/// counts each hard-linked file once.
public final class DiskScanner: Sendable {
    /// Folder extensions treated as one item (apps, libraries, bundles).
    public static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "prefpane", "saver",
        "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
        "aplibrary", "migratedphotolibrary", "logicx", "band", "garageband",
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "swiftpm", "docc",
        "sparsebundle", "pages", "numbers", "key", "rtfd", "scptd", "lpdf", "pkg", "mpkg",
        "dSYM", "simruntime", "nib", "storyboardc", "momd", "car",
    ]

    final class RawDir: @unchecked Sendable {
        let path: String
        let name: String
        let kind: NodeKind
        let modified: UInt32
        let accessed: UInt32
        let bsdFlags: UInt32
        var flags: NodeFlags
        var files: [BulkEntry] = []
        var subdirs: [RawDir] = []

        init(path: String, name: String, kind: NodeKind, modified: UInt32, accessed: UInt32,
             bsdFlags: UInt32, flags: NodeFlags) {
            self.path = path
            self.name = name
            self.kind = kind
            self.modified = modified
            self.accessed = accessed
            self.bsdFlags = bsdFlags
            self.flags = flags
        }
    }

    public let root: String
    public let classifier: SafetyClassifier
    private let threadCount: Int

    private let files = Atomic<Int>(0)
    private let folders = Atomic<Int>(0)
    private let bytes = Atomic<Int64>(0)
    private let cancelled = Atomic<Bool>(false)
    private let seenInodes = Mutex<Set<UInt64>>([])

    public init(root: String, classifier: SafetyClassifier = SafetyClassifier(),
                threads: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        self.classifier = classifier
        self.threadCount = max(1, threads)
    }

    public var progress: ScanProgress {
        ScanProgress(files: files.load(ordering: .relaxed), folders: folders.load(ordering: .relaxed),
                     bytes: bytes.load(ordering: .relaxed))
    }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Runs a full scan on background threads. Throws `CancellationError` if cancelled.
    public func run() async throws -> FileTree {
        try await onThread { $0.scanSync() }
    }

    /// Rebuilds `old`, re-reading only the folders in `changes` (and any folder that
    /// couldn't be read last time). Throws `CancellationError` if cancelled.
    public func rescan(_ old: FileTree, changes: ChangeSet) async throws -> FileTree {
        try await onThread { $0.rescanSync(old, changes: changes) }
    }

    private func onThread(_ work: @escaping @Sendable (DiskScanner) -> FileTree?) async throws -> FileTree {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread { [self] in
                    if let tree = work(self) { continuation.resume(returning: tree) }
                    else { continuation.resume(throwing: CancellationError()) }
                }
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            cancel()
        }
    }

    /// Scans and builds the tree on the calling thread (plus workers). Nil if cancelled.
    public func scanSync() -> FileTree? {
        let eventID = ChangeTracker.currentEventID()
        var info = stat()
        let haveInfo = lstat(root, &info) == 0
        let rootDir = RawDir(path: root, name: root, kind: .directory,
                             modified: haveInfo ? UInt32(clamping: info.st_mtimespec.tv_sec) : 0,
                             accessed: haveInfo ? UInt32(clamping: info.st_atimespec.tv_sec) : 0,
                             bsdFlags: haveInfo ? info.st_flags : 0, flags: [])
        guard scanRecursively([rootDir]) else { return nil }
        let tree = TreeBuilder(classifier: classifier).build(root: rootDir, rootPath: root)
        tree.eventID = eventID
        return tree
    }

    public func rescanSync(_ old: FileTree, changes: ChangeSet) -> FileTree? {
        let eventID = ChangeTracker.currentEventID()
        let reader = BulkDirectoryReader()
        var fresh: [RawDir] = []

        func rawDir(_ id: NodeID, path: String) -> RawDir {
            RawDir(path: path, name: id == FileTree.root ? path : old.name(id), kind: old.kind(id),
                   modified: old.modifiedTimes[Int(id)], accessed: old.accessedTimes[Int(id)],
                   bsdFlags: old.bsdFlagValues[Int(id)],
                   flags: old.flags(id).intersection([.mountPoint]))
        }

        func oldFile(_ id: NodeID) -> BulkEntry {
            let i = Int(id)
            var entry = BulkEntry(name: old.names[i], kind: .other, allocated: old.allocatedSizes[i],
                                  logical: old.logicalSizes[i], modified: old.modifiedTimes[i],
                                  accessed: old.accessedTimes[i], inode: 0, linkCount: 1,
                                  bsdFlags: old.bsdFlagValues[i], isMountPoint: false)
            entry.kind = switch old.kinds[i] {
            case .file: .file
            case .symlink: .symlink
            default: .other
            }
            entry.isHardLinkDuplicate = old.flagValues[i].contains(.hardLinkDuplicate)
            if entry.isHardLinkDuplicate { entry.allocated = 0 }
            return entry
        }

        func rebuild(_ id: NodeID, into dir: RawDir) {
            if isCancelled { return }
            let path = dir.path
            if changes.deep.contains(path) || old.flags(id).contains(.unreadable) {
                fresh.append(dir)
                return
            }
            folders.add(1, ordering: .relaxed)
            let oldChildren = Dictionary(old.children(id).filter { !old.isRemoved($0) }.map { (old.name($0), $0) },
                                         uniquingKeysWith: { a, _ in a })
            let prefix = path == "/" ? "/" : path + "/"
            if changes.shallow.contains(path) {
                // Read the whole listing before descending: the recursion reuses the reader's buffer.
                var entries: [BulkEntry] = []
                do {
                    try reader.read(path) { entries.append($0) }
                } catch {
                    dir.flags.insert(.unreadable)
                    return
                }
                for var entry in entries {
                    if entry.kind == .directory {
                        let sub = makeSubdir(entry, prefix: prefix)
                        dir.subdirs.append(sub)
                        if sub.flags.contains(.mountPoint) { continue }
                        if let previous = oldChildren[entry.name], old.kind(previous).isContainer {
                            rebuild(previous, into: sub)
                        } else {
                            fresh.append(sub)
                        }
                    } else {
                        if entry.linkCount > 1, let previous = oldChildren[entry.name],
                           old.flags(previous).contains(.hardLinkDuplicate) {
                            entry.allocated = 0
                            entry.isHardLinkDuplicate = true
                        }
                        files.add(1, ordering: .relaxed)
                        bytes.add(entry.allocated, ordering: .relaxed)
                        dir.files.append(entry)
                    }
                }
                return
            }
            for child in old.children(id) where !old.isRemoved(child) {
                if old.kind(child).isContainer {
                    let sub = rawDir(child, path: prefix + old.name(child))
                    dir.subdirs.append(sub)
                    if !sub.flags.contains(.mountPoint) { rebuild(child, into: sub) }
                } else {
                    let entry = oldFile(child)
                    files.add(1, ordering: .relaxed)
                    bytes.add(entry.allocated, ordering: .relaxed)
                    dir.files.append(entry)
                }
            }
        }

        let rootDir = rawDir(FileTree.root, path: root)
        rebuild(FileTree.root, into: rootDir)
        guard !isCancelled, scanRecursively(fresh) else { return nil }
        let tree = TreeBuilder(classifier: classifier).build(root: rootDir, rootPath: root)
        tree.eventID = eventID
        return tree
    }

    /// Scans `dirs` and everything below them with the worker threads. False if cancelled.
    private func scanRecursively(_ dirs: [RawDir]) -> Bool {
        guard !dirs.isEmpty else { return !isCancelled }
        let queue = WorkQueue(dirs)
        let group = DispatchGroup()
        for _ in 0..<threadCount {
            group.enter()
            let worker = Thread { [self] in
                let reader = BulkDirectoryReader()
                while let dir = queue.pop() {
                    scan(dir, with: reader, queue: queue)
                    queue.finished()
                }
                group.leave()
            }
            worker.qualityOfService = .userInitiated
            worker.stackSize = 1 << 20
            worker.start()
        }
        group.wait()
        return !isCancelled
    }

    private func makeSubdir(_ entry: BulkEntry, prefix: String) -> RawDir {
        let ext = (entry.name as NSString).pathExtension
        let isPackage = !ext.isEmpty && (Self.packageExtensions.contains(ext)
            || Self.packageExtensions.contains(ext.lowercased()))
        var flags: NodeFlags = []
        if entry.isMountPoint { flags.insert(.mountPoint) }
        return RawDir(path: prefix + entry.name, name: entry.name,
                      kind: isPackage ? .package : .directory,
                      modified: entry.modified, accessed: entry.accessed,
                      bsdFlags: entry.bsdFlags, flags: flags)
    }

    private func scan(_ dir: RawDir, with reader: BulkDirectoryReader, queue: WorkQueue) {
        if isCancelled { return }
        folders.add(1, ordering: .relaxed)
        var subdirs: [RawDir] = []
        let prefix = dir.path == "/" ? "/" : dir.path + "/"
        do {
            try reader.read(dir.path) { entry in
                switch entry.kind {
                case .directory:
                    subdirs.append(makeSubdir(entry, prefix: prefix))
                default:
                    var entry = entry
                    if entry.kind == .file, entry.linkCount > 1 {
                        let firstSighting = seenInodes.withLock { $0.insert(entry.inode).inserted }
                        if !firstSighting {
                            entry.allocated = 0
                            entry.isHardLinkDuplicate = true
                        }
                    }
                    files.add(1, ordering: .relaxed)
                    bytes.add(entry.allocated, ordering: .relaxed)
                    dir.files.append(entry)
                }
            }
        } catch {
            dir.flags.insert(.unreadable)
        }
        dir.subdirs = subdirs
        queue.push(subdirs.filter { !$0.flags.contains(.mountPoint) })
    }
}

/// A LIFO of folders to scan, shared by the worker threads. Finishes when no folder
/// is queued or in progress.
private final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var stack: [DiskScanner.RawDir]
    private var outstanding: Int

    init(_ roots: [DiskScanner.RawDir]) {
        stack = roots
        outstanding = roots.count
    }

    func push(_ dirs: [DiskScanner.RawDir]) {
        guard !dirs.isEmpty else { return }
        condition.lock()
        stack.append(contentsOf: dirs)
        outstanding += dirs.count
        condition.broadcast()
        condition.unlock()
    }

    func pop() -> DiskScanner.RawDir? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && outstanding > 0 { condition.wait() }
        return stack.popLast()
    }

    func finished() {
        condition.lock()
        outstanding -= 1
        if outstanding == 0 { condition.broadcast() }
        condition.unlock()
    }
}

/// Flattens the scanned folders breadth-first into a `FileTree`, classifying each
/// item and rolling sizes and safety levels up into their folders.
struct TreeBuilder {
    let classifier: SafetyClassifier

    func build(root: DiskScanner.RawDir, rootPath: String, scannedAt: Date = Date()) -> FileTree {
        let tree = FileTree(rootPath: rootPath, scannedAt: scannedAt, classifier: classifier)
        let (rootRule, rootCursor) = classifier.start(at: rootPath)
        append(tree, name: rootPath, parent: -1, kind: .directory, allocated: 0, logical: 0,
               modified: root.modified, accessed: root.accessed, flags: root.flags,
               bsdFlags: root.bsdFlags, rule: rootRule)

        var queue: [(NodeID, DiskScanner.RawDir, SafetyClassifier.Cursor)] = [(FileTree.root, root, rootCursor)]
        var head = 0
        while head < queue.count {
            let (id, dir, cursor) = queue[head]
            head += 1
            tree.firstChild[Int(id)] = NodeID(tree.count)
            tree.childCounts[Int(id)] = Int32(dir.subdirs.count + dir.files.count)
            let packageFlag: NodeFlags = cursor.insidePackage ? .insidePackage : []

            for sub in dir.subdirs {
                let (rule, childCursor) = classifier.child(of: cursor, name: sub.name, kind: sub.kind, bsdFlags: sub.bsdFlags)
                let child = append(tree, name: sub.name, parent: id, kind: sub.kind, allocated: 0, logical: 0,
                                   modified: sub.modified, accessed: sub.accessed,
                                   flags: sub.flags.union(packageFlag), bsdFlags: sub.bsdFlags, rule: rule)
                queue.append((child, sub, childCursor))
            }
            for file in dir.files {
                let kind: NodeKind = switch file.kind {
                case .file: .file
                case .symlink: .symlink
                default: .other
                }
                var flags = packageFlag
                if file.isHardLinkDuplicate { flags.insert(.hardLinkDuplicate) }
                if file.bsdFlags & UInt32(SF_DATALESS) != 0 { flags.insert(.dataless) }
                let (rule, _) = classifier.child(of: cursor, name: file.name, kind: kind,
                                                 bsdFlags: file.bsdFlags)
                append(tree, name: file.name, parent: id, kind: kind, allocated: file.allocated,
                       logical: file.logical, modified: file.modified, accessed: file.accessed,
                       flags: flags, bsdFlags: file.bsdFlags, rule: rule)
            }
            dir.files = []
        }

        // Children always come after their parent, so one backwards pass rolls everything up.
        for index in stride(from: tree.count - 1, to: 0, by: -1) {
            let parent = Int(tree.parents[index])
            tree.allocatedSizes[parent] += tree.allocatedSizes[index]
            tree.logicalSizes[parent] += tree.logicalSizes[index]
            tree.fileCounts[parent] += tree.fileCounts[index]
            var contributed = tree.effectiveLevels[index]
            if tree.flagValues[index].contains(.insidePackage), contributed == .caution {
                contributed = .safe
            }
            if contributed > tree.effectiveLevels[parent] { tree.effectiveLevels[parent] = contributed }
        }
        return tree
    }

    @discardableResult
    private func append(_ tree: FileTree, name: String, parent: NodeID, kind: NodeKind,
                        allocated: Int64, logical: Int64, modified: UInt32, accessed: UInt32,
                        flags: NodeFlags, bsdFlags: UInt32, rule: Int16) -> NodeID {
        let id = NodeID(tree.count)
        tree.names.append(name)
        tree.parents.append(parent)
        tree.firstChild.append(0)
        tree.childCounts.append(0)
        tree.allocatedSizes.append(allocated)
        tree.logicalSizes.append(logical)
        tree.modifiedTimes.append(modified)
        tree.accessedTimes.append(accessed)
        tree.kinds.append(kind)
        tree.flagValues.append(flags)
        tree.ownRules.append(rule)
        tree.effectiveLevels.append(classifier.level(ruleIndex: rule))
        tree.fileCounts.append(kind.isContainer ? 0 : 1)
        tree.bsdFlagValues.append(bsdFlags)
        return id
    }
}

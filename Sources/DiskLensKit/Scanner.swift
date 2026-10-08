import Foundation
import Synchronization

/// Live counters a UI can poll while a scan runs.
public struct ScanProgress: Sendable {
    public var files: Int
    public var folders: Int
    public var bytes: Int64
}

/// Scans a folder tree with a pool of threads, each reading whole directories with
/// `getattrlistbulk`. Stays on the starting volume, doesn't follow symlinks, and
/// counts each hard-linked file once.
public final class Scanner: Sendable {
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

    /// Runs the scan on background threads. Throws `CancellationError` if cancelled.
    public func run() async throws -> FileTree {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread { [self] in
                    let tree = scanSync()
                    if let tree { continuation.resume(returning: tree) }
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
        var info = stat()
        let haveInfo = lstat(root, &info) == 0
        let rootDir = RawDir(path: root, name: root, kind: .directory,
                             modified: haveInfo ? UInt32(clamping: info.st_mtimespec.tv_sec) : 0,
                             accessed: haveInfo ? UInt32(clamping: info.st_atimespec.tv_sec) : 0,
                             bsdFlags: haveInfo ? info.st_flags : 0, flags: [])
        let queue = WorkQueue(rootDir)

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
        guard !isCancelled else { return nil }
        return TreeBuilder(classifier: classifier).build(root: rootDir, rootPath: root)
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
                    let ext = (entry.name as NSString).pathExtension
                    let isPackage = !ext.isEmpty && (Self.packageExtensions.contains(ext)
                        || Self.packageExtensions.contains(ext.lowercased()))
                    var flags: NodeFlags = []
                    if entry.isMountPoint { flags.insert(.mountPoint) }
                    let sub = RawDir(path: prefix + entry.name, name: entry.name,
                                     kind: isPackage ? .package : .directory,
                                     modified: entry.modified, accessed: entry.accessed,
                                     bsdFlags: entry.bsdFlags, flags: flags)
                    subdirs.append(sub)
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
    private var stack: [Scanner.RawDir]
    private var outstanding: Int

    init(_ root: Scanner.RawDir) {
        stack = [root]
        outstanding = 1
    }

    func push(_ dirs: [Scanner.RawDir]) {
        guard !dirs.isEmpty else { return }
        condition.lock()
        stack.append(contentsOf: dirs)
        outstanding += dirs.count
        condition.broadcast()
        condition.unlock()
    }

    func pop() -> Scanner.RawDir? {
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

    func build(root: Scanner.RawDir, rootPath: String, scannedAt: Date = Date()) -> FileTree {
        let tree = FileTree(rootPath: rootPath, scannedAt: scannedAt, classifier: classifier)
        let (rootRule, rootCursor) = classifier.start(at: rootPath)
        append(tree, name: rootPath, parent: -1, kind: .directory, allocated: 0, logical: 0,
               modified: root.modified, accessed: root.accessed, flags: root.flags, rule: rootRule)

        var queue: [(NodeID, Scanner.RawDir, SafetyClassifier.Cursor)] = [(FileTree.root, root, rootCursor)]
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
                                   flags: sub.flags.union(packageFlag), rule: rule)
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
                       flags: flags, rule: rule)
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
                        flags: NodeFlags, rule: Int16) -> NodeID {
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
        return id
    }
}

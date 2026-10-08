import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Files with identical contents.
public struct DuplicateGroup: Identifiable, Sendable {
    public let id: Int
    /// Size of one copy.
    public let size: Int64
    /// Sorted by path; the user chooses which copies to delete.
    public let items: [NodeID]
    /// APFS clone family of each item; items sharing one share storage on disk.
    public let cloneIDs: [NodeID: UInt64]

    /// Bytes freed by keeping one copy and deleting the rest. Copies that are APFS
    /// clones of each other share storage, so each clone family counts once.
    public var reclaimable: Int64 {
        size * Int64(max(0, Set(items.map { cloneIDs[$0] ?? UInt64($0) }).count - 1))
    }

    /// True if deleting `id` frees nothing because a clone stays behind.
    public init(id: Int, size: Int64, items: [NodeID], cloneIDs: [NodeID: UInt64]) {
        self.id = id
        self.size = size
        self.items = items
        self.cloneIDs = cloneIDs
    }

    public func isClone(_ id: NodeID) -> Bool {
        guard let clone = cloneIDs[id] else { return false }
        return items.contains { $0 != id && cloneIDs[$0] == clone }
    }
}

/// Finds identical files in three passes, each cheaper than the next: same size,
/// same first and last 64 KB, same SHA-256 of the whole file.
public final class DuplicateFinder: Sendable {
    public struct Progress: Sendable {
        public var filesToCheck: Int
        public var filesChecked: Int

        public init(filesToCheck: Int, filesChecked: Int) {
            self.filesToCheck = filesToCheck
            self.filesChecked = filesChecked
        }
    }

    private let toCheck = Atomic<Int>(0)
    private let checked = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)

    public init() {}

    public var progress: Progress {
        Progress(filesToCheck: toCheck.load(ordering: .relaxed), filesChecked: checked.load(ordering: .relaxed))
    }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }

    public func find(in tree: FileTree, under root: NodeID = FileTree.root,
                     minimumSize: Int64 = 1_000_000) async -> [DuplicateGroup] {
        // Pass 1: candidates grouped by listed size.
        var bySize: [Int64: [NodeID]] = [:]
        tree.walk(from: root) { id in
            let flags = tree.flags(id)
            if flags.contains(.removed) { return false }
            guard tree.kind(id) == .file else { return tree.kind(id) == .directory }
            if flags.contains(.hardLinkDuplicate) || flags.contains(.dataless) { return false }
            let size = tree.logicalSize(id)
            if size >= minimumSize { bySize[size, default: []].append(id) }
            return false
        }
        let sizeGroups = bySize.values.filter { $0.count > 1 }
        toCheck.store(sizeGroups.reduce(0) { $0 + $1.count }, ordering: .relaxed)

        // Pass 2: the first and last 64 KB. Pass 3: the whole file.
        let paths = sizeGroups.flatMap { $0 }.reduce(into: [NodeID: String]()) { $0[$1] = tree.path($1) }
        let quick = await hashAll(paths, sample: true)
        var quickGroups: [[NodeID]] = []
        for group in sizeGroups {
            let split = Dictionary(grouping: group.filter { quick[$0] != nil }) { quick[$0]! }
            quickGroups += split.values.filter { $0.count > 1 }
        }
        guard !cancelled.load(ordering: .relaxed) else { return [] }
        let needsFull = Set(quickGroups.flatMap { $0 }.filter { tree.logicalSize($0) > 2 * Int64(Self.sampleSize) })
        toCheck.add(needsFull.count, ordering: .relaxed)
        let full = await hashAll(paths.filter { needsFull.contains($0.key) }, sample: false)

        var result: [DuplicateGroup] = []
        for group in quickGroups {
            let split = Dictionary(grouping: group) { full[$0] ?? quick[$0] ?? "" }
            for (hash, items) in split where items.count > 1 && !hash.isEmpty {
                var clones: [NodeID: UInt64] = [:]
                for item in items {
                    if let clone = Self.cloneID(path: paths[item]!) { clones[item] = clone }
                }
                result.append(DuplicateGroup(id: result.count, size: tree.size(items[0]),
                                             items: items.sorted { paths[$0]! < paths[$1]! }, cloneIDs: clones))
            }
        }
        return result.sorted { $0.reclaimable > $1.reclaimable }
    }

    static let sampleSize = 64 * 1024

    private func hashAll(_ paths: [NodeID: String], sample: Bool) async -> [NodeID: String] {
        let entries = Array(paths)
        return await withTaskGroup(of: [(NodeID, String)].self) { group in
            let workers = 6
            for worker in 0..<workers {
                group.addTask { [self] in
                    var out: [(NodeID, String)] = []
                    var index = worker
                    while index < entries.count, !cancelled.load(ordering: .relaxed) {
                        let (id, path) = entries[index]
                        if let hash = Self.hash(path: path, sample: sample) { out.append((id, hash)) }
                        checked.add(1, ordering: .relaxed)
                        index += workers
                    }
                    return out
                }
            }
            var all: [NodeID: String] = [:]
            for await pairs in group { for (id, hash) in pairs { all[id] = hash } }
            return all
        }
    }

    static func hash(path: String, sample: Bool) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        let chunk = sample ? sampleSize : 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        func readChunk(at offset: off_t?) -> Int {
            buffer.withUnsafeMutableBytes { raw in
                offset.map { pread(fd, raw.baseAddress, chunk, $0) } ?? read(fd, raw.baseAddress, chunk)
            }
        }
        if sample {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            let first = readChunk(at: 0)
            guard first >= 0 else { return nil }
            hasher.update(data: buffer[0..<first])
            if info.st_size > off_t(chunk) {
                let last = readChunk(at: info.st_size - off_t(chunk))
                guard last >= 0 else { return nil }
                hasher.update(data: buffer[0..<last])
            }
        } else {
            while true {
                let count = readChunk(at: nil)
                if count < 0 { return nil }
                if count == 0 { break }
                hasher.update(data: buffer[0..<count])
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The APFS clone family, or nil off APFS. Clones share their data blocks.
    static func cloneID(path: String) -> UInt64? {
        cloneInfo(path: path)?.cloneID
    }

    /// Bytes deleting the file would actually free (zero for a clone whose data is
    /// shared), and its clone family.
    public static func cloneInfo(path: String) -> (cloneID: UInt64, privateSize: Int64)? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = getattrlist(path, &request, &buffer, buffer.count,
                                 UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            var offset = 4 + MemoryLayout<attribute_set_t>.size
            var privateSize: Int64 = -1
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                privateSize = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
                offset += 8
            }
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 else { return nil }
            let clone = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            return (clone, privateSize)
        }
    }
}

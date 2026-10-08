import CoreServices
import Foundation

extension NodeFlags {
    /// Moved to the Trash since the scan; counts as zero bytes.
    public static let removed = NodeFlags(rawValue: 1 << 5)
}

/// Criteria shared by the file lists and the visualizations.
public struct FileFilter: Sendable, Equatable {
    public var search = ""
    public var categories: Set<FileCategory> = []
    public var minimumSize: Int64 = 0
    /// Only items not used since this date (by `lastUsedEstimate`).
    public var unusedSince: Date?
    public var hideProtected = false

    public init() {}

    public var isActive: Bool {
        !search.isEmpty || !categories.isEmpty || minimumSize > 0 || unusedSince != nil || hideProtected
    }
}

extension FileTree {
    public func isRemoved(_ id: NodeID) -> Bool { flagValues[Int(id)].contains(.removed) }

    /// Visible children (not trashed, not empty), largest first.
    public func visibleChildren(_ id: NodeID) -> [NodeID] {
        children(id)
            .filter { !flagValues[Int($0)].contains(.removed) && (allocatedSizes[Int($0)] > 0 || !kinds[Int($0)].isContainer) }
            .sorted { allocatedSizes[Int($0)] > allocatedSizes[Int($1)] }
    }

    /// Without Spotlight's last-used date: the later of last opened (access time) and
    /// last modified. Access times are a rough signal, so lists prefer Spotlight.
    public func lastUsedEstimate(_ id: NodeID) -> Date {
        Date(timeIntervalSince1970: TimeInterval(max(accessedTimes[Int(id)], modifiedTimes[Int(id)])))
    }

    public func matches(_ id: NodeID, _ filter: FileFilter) -> Bool {
        let i = Int(id)
        if allocatedSizes[i] < filter.minimumSize { return false }
        if filter.hideProtected, effectiveLevels[i] == .locked { return false }
        if !filter.categories.isEmpty, !filter.categories.contains(category(id)) { return false }
        if let cutoff = filter.unusedSince, lastUsedEstimate(id) > cutoff { return false }
        if !filter.search.isEmpty, names[i].range(of: filter.search, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        return true
    }

    /// The largest files (packages count as one file) under `id` that pass `filter`.
    public func largestFiles(under id: NodeID = FileTree.root, limit: Int = 500,
                             filter: FileFilter = FileFilter()) -> [NodeID] {
        var heap = MinHeap(capacity: limit) { [allocatedSizes] in allocatedSizes[Int($0)] }
        walk(from: id) { node in
            let i = Int(node)
            if flagValues[i].contains(.removed) { return false }
            switch kinds[i] {
            case .directory:
                // Skip whole folders too small to hold anything that would make the list.
                return allocatedSizes[i] >= filter.minimumSize && (heap.isFull ? allocatedSizes[i] > heap.minimumKey : true)
            default:
                if allocatedSizes[i] > 0, matches(node, filter) { heap.insert(node) }
                return false
            }
        }
        return heap.sortedDescending()
    }

    /// A copy with `ids` marked as trashed and their bytes taken off every folder above them.
    public func removing(_ ids: [NodeID]) -> FileTree {
        let copy = FileTree(rootPath: rootPath, scannedAt: scannedAt, classifier: classifier)
        copy.names = names
        copy.parents = parents
        copy.firstChild = firstChild
        copy.childCounts = childCounts
        copy.allocatedSizes = allocatedSizes
        copy.logicalSizes = logicalSizes
        copy.modifiedTimes = modifiedTimes
        copy.accessedTimes = accessedTimes
        copy.kinds = kinds
        copy.flagValues = flagValues
        copy.ownRules = ownRules
        copy.effectiveLevels = effectiveLevels
        copy.fileCounts = fileCounts
        copy.bsdFlagValues = bsdFlagValues
        copy.eventID = eventID
        for id in ids where !copy.flagValues[Int(id)].contains(.removed) {
            let bytes = copy.allocatedSizes[Int(id)]
            let logical = copy.logicalSizes[Int(id)]
            let files = copy.fileCounts[Int(id)]
            // An item inside one already removed was subtracted with it.
            if copy.lineage(id).dropLast().contains(where: { copy.flagValues[Int($0)].contains(.removed) }) { continue }
            copy.flagValues[Int(id)].insert(.removed)
            var node = id
            while let up = copy.parent(node) {
                copy.allocatedSizes[Int(up)] -= bytes
                copy.logicalSizes[Int(up)] -= logical
                copy.fileCounts[Int(up)] -= files
                node = up
            }
            copy.allocatedSizes[Int(id)] = 0
        }
        return copy
    }
}

/// Keeps the `capacity` largest items by key.
struct MinHeap {
    private var items: [NodeID] = []
    private let capacity: Int
    private let key: (NodeID) -> Int64

    init(capacity: Int, key: @escaping (NodeID) -> Int64) {
        self.capacity = max(1, capacity)
        self.key = key
        items.reserveCapacity(self.capacity)
    }

    var isFull: Bool { items.count >= capacity }
    var minimumKey: Int64 { items.first.map(key) ?? 0 }

    mutating func insert(_ id: NodeID) {
        if items.count < capacity {
            items.append(id)
            siftUp(items.count - 1)
        } else if key(id) > key(items[0]) {
            items[0] = id
            siftDown(0)
        }
    }

    func sortedDescending() -> [NodeID] { items.sorted { key($0) > key($1) } }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard key(items[child]) < key(items[parent]) else { return }
            items.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            if left < items.count, key(items[left]) < key(items[smallest]) { smallest = left }
            if right < items.count, key(items[right]) < key(items[smallest]) { smallest = right }
            guard smallest != parent else { return }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

/// When a file was last opened, from Spotlight (`kMDItemLastUsedDate`). Spotlight records
/// opens by apps, which is a better "is this still used?" signal than access times,
/// but it doesn't know every file, so callers fall back to the scan's dates.
public enum UsageInfo {
    public static func spotlightLastUsed(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Last-used dates for many paths, looked up concurrently.
    public static func lastUsed(paths: [String]) async -> [String: Date] {
        await withTaskGroup(of: [(String, Date)].self) { group in
            let chunk = max(1, paths.count / 8 + 1)
            for start in stride(from: 0, to: paths.count, by: chunk) {
                let slice = Array(paths[start..<min(start + chunk, paths.count)])
                group.addTask {
                    slice.compactMap { path in spotlightLastUsed(path: path).map { (path, $0) } }
                }
            }
            var result: [String: Date] = [:]
            for await pairs in group { for (path, date) in pairs { result[path] = date } }
            return result
        }
    }
}

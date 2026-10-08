import Foundation

public typealias NodeID = Int32

public enum NodeKind: UInt8, Sendable {
    case file, directory, package, symlink, other

    /// Directories and packages: things with children.
    public var isContainer: Bool { self == .directory || self == .package }
}

public struct NodeFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Another path to a file already counted; adds nothing to the totals.
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 0)
    /// A folder the scan couldn't read (usually missing Full Disk Access).
    public static let unreadable = NodeFlags(rawValue: 1 << 1)
    /// Another volume is mounted here; not scanned.
    public static let mountPoint = NodeFlags(rawValue: 1 << 2)
    /// A cloud file that isn't downloaded, so it takes no local space.
    public static let dataless = NodeFlags(rawValue: 1 << 3)
    public static let insidePackage = NodeFlags(rawValue: 1 << 4)
}

/// An immutable scan result stored as parallel arrays, about 60 bytes per item, so
/// millions of files fit comfortably. Children of a node are contiguous, and every
/// child has a higher index than its parent.
public final class FileTree: @unchecked Sendable {
    public let rootPath: String
    public let scannedAt: Date
    public let classifier: SafetyClassifier

    var names: [String] = []
    var parents: [NodeID] = []
    var firstChild: [NodeID] = []
    var childCounts: [Int32] = []
    var allocatedSizes: [Int64] = []
    var logicalSizes: [Int64] = []
    var modifiedTimes: [UInt32] = []
    var accessedTimes: [UInt32] = []
    var kinds: [NodeKind] = []
    var flagValues: [NodeFlags] = []
    var ownRules: [Int16] = []
    var effectiveLevels: [SafetyLevel] = []
    var fileCounts: [Int32] = []

    public static let root: NodeID = 0

    init(rootPath: String, scannedAt: Date, classifier: SafetyClassifier) {
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.classifier = classifier
    }

    public var count: Int { names.count }

    public func name(_ id: NodeID) -> String { names[Int(id)] }
    public func kind(_ id: NodeID) -> NodeKind { kinds[Int(id)] }
    public func flags(_ id: NodeID) -> NodeFlags { flagValues[Int(id)] }
    public func parent(_ id: NodeID) -> NodeID? { id == Self.root ? nil : parents[Int(id)] }
    /// Bytes on disk, including everything inside a folder.
    public func size(_ id: NodeID) -> Int64 { allocatedSizes[Int(id)] }
    public func logicalSize(_ id: NodeID) -> Int64 { logicalSizes[Int(id)] }
    public func modified(_ id: NodeID) -> Date { Date(timeIntervalSince1970: TimeInterval(modifiedTimes[Int(id)])) }
    public func accessed(_ id: NodeID) -> Date { Date(timeIntervalSince1970: TimeInterval(accessedTimes[Int(id)])) }
    /// Files inside a folder (all levels), or 1 for a file.
    public func fileCount(_ id: NodeID) -> Int { Int(fileCounts[Int(id)]) }

    public func children(_ id: NodeID) -> Range<NodeID> {
        let first = firstChild[Int(id)]
        return first..<(first + childCounts[Int(id)])
    }

    /// The safety level that governs deleting this item: its own level, raised to
    /// `locked` if anything inside is locked, and to `caution` if anything inside is
    /// (package internals excepted, since deleting the whole package is fine).
    public func safety(_ id: NodeID) -> SafetyLevel { effectiveLevels[Int(id)] }

    public func safetyVerdict(_ id: NodeID) -> SafetyVerdict {
        let own = classifier.verdict(ruleIndex: ownRules[Int(id)])
        let effective = effectiveLevels[Int(id)]
        if effective > own.level {
            return SafetyVerdict(level: effective, reason: effective == .locked
                ? "Contains items macOS protects."
                : "Contains app or system data. Check inside before deleting all of it.")
        }
        return own
    }

    public func path(_ id: NodeID) -> String {
        var components: [String] = []
        var node = id
        while node != Self.root {
            components.append(names[Int(node)])
            node = parents[Int(node)]
        }
        guard !components.isEmpty else { return rootPath }
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return base + components.reversed().joined(separator: "/")
    }

    public func url(_ id: NodeID) -> URL {
        URL(fileURLWithPath: path(id), isDirectory: kind(id).isContainer)
    }

    /// Ancestors from the root down to `id`, inclusive.
    public func lineage(_ id: NodeID) -> [NodeID] {
        var chain: [NodeID] = [id]
        var node = id
        while let up = parent(node) {
            chain.append(up)
            node = up
        }
        return chain.reversed()
    }

    /// The node at `path`, if it was scanned.
    public func node(atPath path: String) -> NodeID? {
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if path == rootPath { return Self.root }
        guard path.hasPrefix(base) else { return nil }
        var node = Self.root
        for component in path.dropFirst(base.count).split(separator: "/") {
            guard let next = children(node).first(where: { names[Int($0)] == component }) else { return nil }
            node = next
        }
        return node
    }

    /// Children sorted largest first.
    public func childrenBySize(_ id: NodeID) -> [NodeID] {
        children(id).sorted { allocatedSizes[Int($0)] > allocatedSizes[Int($1)] }
    }

    /// Calls `body` for every node below `id` (not `id` itself). Return false to skip a node's children.
    public func walk(from id: NodeID = FileTree.root, _ body: (NodeID) -> Bool) {
        var stack = Array(children(id))
        while let node = stack.popLast() {
            if body(node), kinds[Int(node)].isContainer {
                stack.append(contentsOf: children(node))
            }
        }
    }

    /// Folders the scan couldn't read.
    public var unreadableFolders: [NodeID] {
        (0..<NodeID(count)).filter { flagValues[Int($0)].contains(.unreadable) }
    }
}

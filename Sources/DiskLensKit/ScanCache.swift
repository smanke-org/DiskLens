import Foundation
import Synchronization

/// Saves scan results so the app reopens instantly, then catches up by rescanning only
/// the folders FSEvents says changed. One LZFSE-compressed file per scanned folder in
/// ~/Library/Caches/com.smanke.DiskLens.
public final class ScanCache: @unchecked Sendable {
    public static let shared = ScanCache()

    private static let magic: UInt32 = 0x444C_4331 // "DLC1"
    private let directory: URL
    private let writeQueue = DispatchQueue(label: "DiskLens.ScanCache", qos: .utility)

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.smanke.DiskLens/Scans", isDirectory: true)
    }

    private func file(for rootPath: String) -> URL {
        directory.appendingPathComponent(String(format: "%016llx.scan", Self.fnv1a(rootPath)))
    }

    /// Writes in the background; a newer save of the same folder replaces it.
    public func save(_ tree: FileTree) {
        writeQueue.async { [self] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? (encode(tree) as NSData).compressed(using: .lzfse) else { return }
            try? (data as Data).write(to: file(for: tree.rootPath), options: .atomic)
        }
    }

    /// Waits for pending saves (for tests).
    public func flush() { writeQueue.sync {} }

    public func load(rootPath: String, classifier: SafetyClassifier = SafetyClassifier()) -> FileTree? {
        guard let compressed = try? Data(contentsOf: file(for: rootPath)),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return decode(data, rootPath: rootPath, classifier: classifier)
    }

    public func remove(rootPath: String) {
        try? FileManager.default.removeItem(at: file(for: rootPath))
    }

    /// What changed under a cached tree's root, or nil when only a full scan will do.
    public func changes(since tree: FileTree) -> ChangeSet? {
        guard tree.eventID != 0,
              let saved = databaseIDs.withLock({ $0[tree.rootPath] }) ?? storedDatabaseID(rootPath: tree.rootPath),
              saved == ChangeTracker.databaseID(for: tree.rootPath) else { return nil }
        return ChangeTracker.changes(under: tree.rootPath, since: tree.eventID)
    }

    private let databaseIDs = Mutex<[String: String]>([:])

    private func storedDatabaseID(rootPath: String) -> String? {
        guard let compressed = try? Data(contentsOf: file(for: rootPath)),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        var reader = ByteReader(data: data)
        guard reader.read(UInt32.self) == Self.magic else { return nil }
        _ = reader.read(UInt64.self)
        _ = reader.read(UInt64.self)
        _ = reader.read(Double.self)
        return reader.readString()
    }

    // MARK: Format

    static func fingerprint(_ classifier: SafetyClassifier) -> UInt64 {
        fnv1a(classifier.rules.map { "\($0.path)|\($0.scope)|\($0.level.rawValue)|\($0.reason)" }.joined(separator: "\n")
              + DiskScanner.packageExtensions.sorted().joined(separator: ","))
    }

    func encode(_ tree: FileTree) -> Data {
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        func append<T>(_ array: [T]) { array.withUnsafeBytes { data.append(contentsOf: $0) } }
        func appendString(_ string: String) {
            let bytes = Array(string.utf8)
            append(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }
        append(Self.magic)
        append(Self.fingerprint(tree.classifier))
        append(tree.eventID)
        append(tree.scannedAt.timeIntervalSince1970)
        appendString(ChangeTracker.databaseID(for: tree.rootPath) ?? "")
        appendString(tree.rootPath)
        append(UInt32(tree.count))
        append(tree.parents)
        append(tree.firstChild)
        append(tree.childCounts)
        append(tree.allocatedSizes)
        append(tree.logicalSizes)
        append(tree.modifiedTimes)
        append(tree.accessedTimes)
        append(tree.kinds.map(\.rawValue))
        append(tree.flagValues.map(\.rawValue))
        append(tree.ownRules)
        append(tree.effectiveLevels.map(\.rawValue))
        append(tree.fileCounts)
        append(tree.bsdFlagValues)
        var names = Data()
        for name in tree.names {
            names.append(contentsOf: name.utf8)
            names.append(0)
        }
        append(UInt64(names.count))
        data.append(names)
        return data
    }

    func decode(_ data: Data, rootPath: String, classifier: SafetyClassifier) -> FileTree? {
        var reader = ByteReader(data: data)
        guard reader.read(UInt32.self) == Self.magic,
              reader.read(UInt64.self) == Self.fingerprint(classifier),
              let eventID = reader.read(UInt64.self),
              let scannedAt = reader.read(Double.self),
              let databaseID = reader.readString(),
              reader.readString() == rootPath,
              let count = reader.read(UInt32.self).map(Int.init) else { return nil }
        let tree = FileTree(rootPath: rootPath, scannedAt: Date(timeIntervalSince1970: scannedAt), classifier: classifier)
        tree.eventID = eventID
        guard let parents = reader.readArray(Int32.self, count),
              let firstChild = reader.readArray(Int32.self, count),
              let childCounts = reader.readArray(Int32.self, count),
              let allocated = reader.readArray(Int64.self, count),
              let logical = reader.readArray(Int64.self, count),
              let modified = reader.readArray(UInt32.self, count),
              let accessed = reader.readArray(UInt32.self, count),
              let kinds = reader.readArray(UInt8.self, count),
              let flags = reader.readArray(UInt8.self, count),
              let ownRules = reader.readArray(Int16.self, count),
              let levels = reader.readArray(UInt8.self, count),
              let fileCounts = reader.readArray(Int32.self, count),
              let bsdFlags = reader.readArray(UInt32.self, count),
              let namesLength = reader.read(UInt64.self),
              let nameBytes = reader.readArray(UInt8.self, Int(namesLength)) else { return nil }
        var names: [String] = []
        names.reserveCapacity(count)
        nameBytes.withUnsafeBufferPointer { buffer in
            var start = 0
            for index in 0..<buffer.count where buffer[index] == 0 {
                names.append(String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<index]), as: UTF8.self))
                start = index + 1
            }
        }
        guard names.count == count else { return nil }
        tree.names = names
        tree.parents = parents
        tree.firstChild = firstChild
        tree.childCounts = childCounts
        tree.allocatedSizes = allocated
        tree.logicalSizes = logical
        tree.modifiedTimes = modified
        tree.accessedTimes = accessed
        tree.kinds = kinds.map { NodeKind(rawValue: $0) ?? .other }
        tree.flagValues = flags.map { NodeFlags(rawValue: $0) }
        tree.ownRules = ownRules
        tree.effectiveLevels = levels.map { SafetyLevel(rawValue: $0) ?? .locked }
        tree.fileCounts = fileCounts
        tree.bsdFlagValues = bsdFlags
        databaseIDs.withLock { $0[rootPath] = databaseID }
        return tree
    }

    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0

    mutating func read<T>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size
        return value
    }

    mutating func readString() -> String? {
        guard let length = read(UInt32.self).map(Int.init), offset + length <= data.count else { return nil }
        let string = String(decoding: data[data.startIndex + offset..<data.startIndex + offset + length], as: UTF8.self)
        offset += length
        return string
    }

    mutating func readArray<T>(_: T.Type, _ count: Int) -> [T]? {
        let bytes = MemoryLayout<T>.stride * count
        guard offset + bytes <= data.count else { return nil }
        let array = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.withUnsafeBytes { raw in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + bytes]))
            }
            initialized = count
        }
        offset += bytes
        return array
    }
}

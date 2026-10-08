import CoreServices
import Foundation

/// Folders that changed since a scan.
public struct ChangeSet: Sendable, Equatable {
    /// Folders whose own entries changed: re-read them, keep unchanged subfolders.
    public var shallow: Set<String> = []
    /// Folders FSEvents couldn't account for: rescan everything below them.
    public var deep: Set<String> = []

    public init(shallow: Set<String> = [], deep: Set<String> = []) {
        self.shallow = shallow
        self.deep = deep
    }

    public var isEmpty: Bool { shallow.isEmpty && deep.isEmpty }
}

/// Replays the FSEvents history for a folder to find out what changed since a scan.
public enum ChangeTracker {
    public static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the FSEvents database of the volume holding `path`. Event IDs from a
    /// different database (a reformatted or replaced volume) mean nothing.
    public static func databaseID(for path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private final class Collector {
        var changes = ChangeSet()
        var needsFullScan = false
        let done = DispatchSemaphore(value: 0)
        let realRoot: String
        let root: String

        init(root: String, realRoot: String) {
            self.root = root
            self.realRoot = realRoot
        }

        /// Event paths use the real path; report them under the root as the caller named it.
        func translate(_ path: String) -> String? {
            var path = path
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if realRoot == "/" { return path }
            if path == realRoot { return root }
            guard path.hasPrefix(realRoot + "/") else { return nil }
            return root + path.dropFirst(realRoot.count)
        }
    }

    /// Folders under `root` changed since `eventID`, or nil when the history can't
    /// say (dropped events, a different volume database, a timeout) and a full scan is needed.
    public static func changes(under root: String, since eventID: UInt64,
                               timeout: TimeInterval = 15) -> ChangeSet? {
        // realpath, not URL.resolvingSymlinksInPath, which strips /private and so hides
        // that /var is really /private/var (the form FSEvents reports).
        let realRoot = realpath(root, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? root
        let collector = Collector(root: root, realRoot: realRoot)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for i in 0..<count {
                let flag = Int(flags[i])
                if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                    collector.done.signal()
                    continue
                }
                if flag & (kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped
                           | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    collector.needsFullScan = true
                    continue
                }
                guard let path = collector.translate(String(cString: cPaths[i])) else { continue }
                if flag & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                    collector.changes.deep.insert(path)
                } else {
                    collector.changes.shallow.insert(path)
                }
            }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [realRoot] as CFArray, eventID, 0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else {
            return nil
        }
        let queue = DispatchQueue(label: "DiskLens.ChangeTracker")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        let finished = collector.done.wait(timeout: .now() + timeout) == .success
        // Changes too recent to be in the history yet arrive as live events; deliver those too.
        FSEventStreamFlushSync(stream)
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Read the results on the stream's queue so no callback is still writing them.
        return queue.sync {
            guard finished, !collector.needsFullScan else { return nil }
            if collector.changes.deep.contains(root) { return nil }
            return collector.changes
        }
    }
}

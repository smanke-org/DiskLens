import Foundation
import Testing
@testable import DiskLensKit

@Suite struct FeatureTests {
    let fixture: URL
    let fm = FileManager.default

    init() throws {
        fixture = fm.temporaryDirectory.appendingPathComponent("DiskLensFeatures-\(UUID().uuidString)")
        try fm.createDirectory(at: fixture.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fixture.appendingPathComponent("keep"), withIntermediateDirectories: true)
        try Data(count: 40_000).write(to: fixture.appendingPathComponent("a/one.bin"))
        try Data(count: 60_000).write(to: fixture.appendingPathComponent("a/b/c/deep.bin"))
        try Data(count: 10_000).write(to: fixture.appendingPathComponent("keep/k.txt"))
    }

    private func signature(_ tree: FileTree) -> [String: Int64] {
        var result: [String: Int64] = [:]
        tree.walk { id in
            if !tree.isRemoved(id) { result[tree.path(id)] = tree.size(id) }
            return true
        }
        return result
    }

    @Test func partialRescanMatchesFullScan() throws {
        let scanner = DiskScanner(root: fixture.path, threads: 2)
        let before = try #require(scanner.scanSync())
        // Change one folder's entries: add a file, remove one, add a new subfolder with contents.
        try Data(count: 25_000).write(to: fixture.appendingPathComponent("a/new.bin"))
        try fm.removeItem(at: fixture.appendingPathComponent("a/one.bin"))
        try fm.createDirectory(at: fixture.appendingPathComponent("a/fresh/inner"), withIntermediateDirectories: true)
        try Data(count: 33_000).write(to: fixture.appendingPathComponent("a/fresh/inner/x.bin"))

        let changes = ChangeSet(shallow: [fixture.path + "/a"])
        let rescanned = try #require(DiskScanner(root: fixture.path, threads: 2).rescanSync(before, changes: changes))
        let full = try #require(DiskScanner(root: fixture.path, threads: 2).scanSync())
        #expect(signature(rescanned) == signature(full))
        #expect(rescanned.size(FileTree.root) == full.size(FileTree.root))
    }

    @Test func cacheRoundTrip() throws {
        let tree = try #require(DiskScanner(root: fixture.path).scanSync())
        let cacheDir = fm.temporaryDirectory.appendingPathComponent("DiskLensCache-\(UUID().uuidString)")
        let cache = ScanCache(directory: cacheDir)
        cache.save(tree)
        cache.flush()
        let loaded = try #require(cache.load(rootPath: fixture.path))
        #expect(signature(loaded) == signature(tree))
        #expect(loaded.eventID == tree.eventID)
        #expect(loaded.count == tree.count)
        for id in 0..<NodeID(tree.count) {
            #expect(loaded.safety(id) == tree.safety(id))
            #expect(loaded.kind(id) == tree.kind(id))
        }
    }

    @Test func changeTrackerReportsChangedFolder() async throws {
        let tree = try #require(DiskScanner(root: fixture.path).scanSync())
        try Data(count: 1_000).write(to: fixture.appendingPathComponent("keep/added.txt"))
        // FSEvents delivers with a short delay; give the daemon time to record it.
        try await Task.sleep(for: .seconds(2))
        let changes = try #require(ChangeTracker.changes(under: fixture.path, since: tree.eventID))
        #expect(changes.shallow.contains(fixture.path + "/keep") || changes.deep.contains(fixture.path + "/keep"),
                "\(changes)")
        #expect(!changes.shallow.contains(fixture.path + "/a/b/c"))
    }

    @Test func removingSubtractsFromAncestors() throws {
        let tree = try #require(DiskScanner(root: fixture.path).scanSync())
        let deep = try #require(tree.node(atPath: fixture.path + "/a/b/c/deep.bin"))
        let a = try #require(tree.node(atPath: fixture.path + "/a"))
        let removed = tree.removing([deep])
        #expect(removed.size(a) == tree.size(a) - tree.size(deep))
        #expect(removed.size(FileTree.root) == tree.size(FileTree.root) - tree.size(deep))
        #expect(removed.isRemoved(deep))
        #expect(!tree.isRemoved(deep))
    }

    @Test func duplicatesAndClones() async throws {
        let dir = fixture.appendingPathComponent("dupes")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 2_000_000)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        try Data(bytes).write(to: dir.appendingPathComponent("original.bin"))
        try fm.copyItem(at: dir.appendingPathComponent("original.bin"), to: dir.appendingPathComponent("copy.bin"))
        // A real byte-for-byte copy (not a clone) via write.
        try Data(bytes).write(to: dir.appendingPathComponent("written.bin"))
        bytes[1_000_000] ^= 0xFF
        try Data(bytes).write(to: dir.appendingPathComponent("different.bin"))

        let tree = try #require(DiskScanner(root: fixture.path).scanSync())
        let groups = await DuplicateFinder().find(in: tree)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.items.map { tree.name($0) }) == ["original.bin", "copy.bin", "written.bin"])
        // FileManager.copyItem clones on APFS: original and copy share storage.
        let copy = try #require(group.items.first { tree.name($0) == "copy.bin" })
        let written = try #require(group.items.first { tree.name($0) == "written.bin" })
        #expect(group.isClone(copy))
        #expect(!group.isClone(written))
        #expect(group.reclaimable == group.size)
    }

    @Test func suggestionsFindInstallersAndCaches() throws {
        let home = fixture.path
        try fm.createDirectory(at: fixture.appendingPathComponent("Library/Caches/com.example"), withIntermediateDirectories: true)
        try Data(count: 50_000).write(to: fixture.appendingPathComponent("Library/Caches/com.example/blob"))
        try fm.createDirectory(at: fixture.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try Data(count: 1_500_000).write(to: fixture.appendingPathComponent("Downloads/Setup.dmg"))
        let classifier = SafetyClassifier(home: home)
        let tree = try #require(DiskScanner(root: fixture.path, classifier: classifier).scanSync())
        let suggestions = CleanupSuggestions.find(in: tree, home: home)
        #expect(suggestions.contains { $0.id == "caches" && $0.items.count == 1 })
        #expect(suggestions.contains { $0.id == "installers" && $0.items.map { tree.name($0) } == ["Setup.dmg"] })
    }

    @Test func layoutsCoverTheirArea() throws {
        let rects = TreemapLayout.squarify([600, 300, 100], in: CGRect(x: 0, y: 0, width: 50, height: 20))
        #expect(rects.count == 3)
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(area - 1000) < 0.5)
        for rect in rects { #expect(CGRect(x: 0, y: 0, width: 50, height: 20).insetBy(dx: -0.01, dy: -0.01).contains(rect)) }

        let tree = try #require(DiskScanner(root: fixture.path).scanSync())
        let sun = SunburstLayout.cells(tree: tree, root: FileTree.root)
        let ring1 = sun.filter { $0.depth == 1 }
        #expect(abs(ring1.reduce(0) { $0 + $1.endAngle - $1.startAngle } - 2 * .pi) < 0.05)
    }
}

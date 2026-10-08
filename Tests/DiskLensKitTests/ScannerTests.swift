import Foundation
import Testing
@testable import DiskLensKit

@Suite struct ScannerTests {
    let fixture: URL

    init() throws {
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskLensFixture-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: fixture.appendingPathComponent("docs/nested"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fixture.appendingPathComponent("Tool.app/Contents/MacOS"), withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: fixture.appendingPathComponent("docs/big.bin"))
        try Data(count: 5_000).write(to: fixture.appendingPathComponent("docs/nested/small.txt"))
        try Data(count: 80_000).write(to: fixture.appendingPathComponent("Tool.app/Contents/MacOS/Tool"))
        try Data(count: 1_000).write(to: fixture.appendingPathComponent("setup.dmg"))
        try fm.linkItem(at: fixture.appendingPathComponent("docs/big.bin"),
                        to: fixture.appendingPathComponent("hardlink.bin"))
        try fm.createSymbolicLink(at: fixture.appendingPathComponent("link-to-docs"),
                                  withDestinationURL: fixture.appendingPathComponent("docs"))
        // Sparse: a 50 MB listed size with almost nothing allocated.
        let sparse = fixture.appendingPathComponent("sparse.img").path
        #expect(fm.createFile(atPath: sparse, contents: nil))
        #expect(truncate(sparse, 50_000_000) == 0)
    }

    private func scan() throws -> FileTree {
        try #require(DiskScanner(root: fixture.path, threads: 3).scanSync())
    }

    private func du(_ path: String) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int64(output.split(separator: "\t").first ?? "0") ?? 0
    }

    @Test func totalMatchesDu() throws {
        let tree = try scan()
        let expected = try du(fixture.path)
        #expect(tree.size(FileTree.root) / 1024 == expected)
    }

    @Test func hardLinkCountedOnce() throws {
        let tree = try scan()
        let original = try #require(tree.node(atPath: fixture.path + "/docs/big.bin"))
        let link = try #require(tree.node(atPath: fixture.path + "/hardlink.bin"))
        let duplicate = tree.flags(original).contains(.hardLinkDuplicate) ? original : link
        #expect(tree.size(duplicate) == 0)
        #expect(tree.size(original) + tree.size(link) >= 300_000)
    }

    @Test func symlinkNotFollowedAndSparseUsesAllocatedSize() throws {
        let tree = try scan()
        let link = try #require(tree.node(atPath: fixture.path + "/link-to-docs"))
        #expect(tree.kind(link) == .symlink)
        let sparse = try #require(tree.node(atPath: fixture.path + "/sparse.img"))
        #expect(tree.logicalSize(sparse) == 50_000_000)
        #expect(tree.size(sparse) < 1_000_000)
    }

    @Test func packagesAndRollups() throws {
        let tree = try scan()
        let app = try #require(tree.node(atPath: fixture.path + "/Tool.app"))
        #expect(tree.kind(app) == .package)
        #expect(tree.fileCount(app) == 1)
        let binary = try #require(tree.node(atPath: fixture.path + "/Tool.app/Contents/MacOS/Tool"))
        #expect(tree.flags(binary).contains(.insidePackage))
        #expect(tree.safety(binary) == .caution)
        // Package internals don't make the package itself "caution".
        #expect(tree.safety(app) == .user)
        #expect(tree.path(binary) == fixture.path + "/Tool.app/Contents/MacOS/Tool")
        let total = tree.children(FileTree.root).reduce(Int64(0)) { $0 + tree.size($1) }
        #expect(total == tree.size(FileTree.root))
    }

    @Test func extensionRule() throws {
        let tree = try scan()
        let dmg = try #require(tree.node(atPath: fixture.path + "/setup.dmg"))
        #expect(tree.safety(dmg) == .safe)
    }
}

@Suite struct ClassifierTests {
    let home = "/Users/tester"
    var classifier: SafetyClassifier { SafetyClassifier(home: home) }

    func level(_ path: String, kind: NodeKind = .file, flags: UInt32 = 0) -> SafetyLevel {
        let components = path.split(separator: "/").map(String.init)
        var (rule, cursor) = classifier.start(at: "/")
        for (index, name) in components.enumerated() {
            let isLast = index == components.count - 1
            let nodeKind: NodeKind = isLast ? kind
                : (DiskScanner.packageExtensions.contains((name as NSString).pathExtension) ? .package : .directory)
            (rule, cursor) = classifier.child(of: cursor, name: name, kind: nodeKind, bsdFlags: isLast ? flags : 0)
        }
        return classifier.level(ruleIndex: rule)
    }

    @Test(arguments: [
        ("/System/Library/CoreServices/Finder.app", SafetyLevel.locked),
        ("/usr/bin/ls", .locked),
        ("/usr/local/bin/tool", .caution),
        ("/Users/tester", .locked),
        ("/Users/tester/Documents", .locked),
        ("/Users/tester/Documents/report.pdf", .user),
        ("/Users/tester/Downloads/movie.mov", .user),
        ("/Users/tester/Downloads/Installer.dmg", .safe),
        ("/Users/tester/Library", .locked),
        ("/Users/tester/Library/Preferences/com.example.plist", .caution),
        ("/Users/tester/Library/Keychains/login.keychain-db", .locked),
        ("/Users/tester/Library/Caches", .caution),
        ("/Users/tester/Library/Caches/com.example/blob", .safe),
        ("/Users/tester/Library/Containers/com.example/Data/Library/Caches/x", .safe),
        ("/Users/tester/Library/Containers/com.example/Data/Documents/x", .caution),
        ("/Users/tester/Library/Developer/Xcode/DerivedData/App-abc", .safe),
        ("/Users/tester/Library/Developer/Xcode/iOS DeviceSupport/18.0", .safe),
        ("/Users/tester/Library/Mail/V10/x.emlx", .caution),
        ("/Users/tester/Library/Caches/Installer.dmg", .safe),
        ("/Users/tester/.Trash", .locked),
        ("/Users/tester/.Trash/old.zip", .safe),
        ("/Users/tester/.zshrc", .caution),
        ("/Users/tester/Applications/Tool.app/Contents/Info.plist", .caution),
    ])
    func classifies(path: String, expected: SafetyLevel) {
        let kind: NodeKind = (path as NSString).pathExtension.isEmpty ? .directory : .file
        #expect(level(path, kind: kind) == expected, "\(path)")
    }

    @Test func protectedFlagLocks() {
        #expect(level("/Users/tester/Documents/x", flags: UInt32(SF_RESTRICTED)) == .locked)
        #expect(level("/Users/tester/Documents/x", flags: UInt32(UF_IMMUTABLE)) == .locked)
    }
}

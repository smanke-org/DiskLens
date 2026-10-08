import Foundation

/// How careful to be before deleting an item. Ordered: a folder is at least as
/// restricted as the most restricted thing it contains.
public enum SafetyLevel: UInt8, Comparable, Sendable, CaseIterable {
    /// Rebuilt or re-downloaded automatically (caches, build products, installers).
    case safe
    /// Your own files: deleting is your call.
    case user
    /// App or system data where deleting can reset or break something.
    case caution
    /// Required by macOS or protected by it. Never offered for deletion.
    case locked

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .safe: "Safe to delete"
        case .user: "Your files"
        case .caution: "Use caution"
        case .locked: "Protected"
        }
    }
}

public struct SafetyRule: Sendable {
    public enum Scope: Sendable {
        /// The path itself only.
        case item
        /// Everything inside the path, not the path itself.
        case contents
        /// The path and everything inside it.
        case subtree
    }

    /// `~` expands to the home folder. A component may be an `fnmatch` pattern (`*`, `.*`).
    public var path: String
    public var scope: Scope
    public var level: SafetyLevel
    public var reason: String

    public init(_ path: String, _ scope: Scope, _ level: SafetyLevel, _ reason: String) {
        self.path = path
        self.scope = scope
        self.level = level
        self.reason = reason
    }
}

/// Why an item got its level: a rule's reason, or nil for ordinary user files.
public struct SafetyVerdict: Sendable, Equatable {
    public var level: SafetyLevel
    public var reason: String?
}

/// Assigns a `SafetyLevel` to every scanned item from path rules, file extensions
/// and BSD protection flags. Rules are matched component by component while the tree
/// is walked, so classifying costs a dictionary lookup per item, not a path compare
/// against every rule.
public final class SafetyClassifier: Sendable {
    final class RuleNode: @unchecked Sendable {
        var exact: [String: RuleNode] = [:]
        var patterns: [(String, RuleNode)] = []
        var itemRule: Int16 = -1
        var contentsRule: Int16 = -1

        func child(_ name: String) -> RuleNode? {
            if let node = exact[name] { return node }
            return patterns.first { fnmatch($0.0, name, 0) == 0 }?.1
        }
    }

    /// Position in the rule trie while descending the file tree.
    public struct Cursor: Sendable {
        var node: RuleNode?
        var inherited: Int16
        var insidePackage: Bool
    }

    public let rules: [SafetyRule]
    private let root = RuleNode()
    private let extensionRules: [String: Int16]

    // Synthetic rules appended after the path rules, referenced by index like the others.
    private let packageRule: Int16
    private let restrictedRule: Int16
    private let immutableRule: Int16

    public init(rules pathRules: [SafetyRule] = SafetyClassifier.builtInRules,
                extensions: [(String, SafetyLevel, String)] = SafetyClassifier.builtInExtensions,
                home: String = NSHomeDirectory()) {
        var all = pathRules
        var byExtension: [String: Int16] = [:]
        for (ext, level, reason) in extensions {
            byExtension[ext] = Int16(all.count)
            all.append(SafetyRule("." + ext, .item, level, reason))
        }
        packageRule = Int16(all.count)
        all.append(SafetyRule("", .subtree, .caution,
                              "Inside an app or document package. Delete the whole package instead of parts of it."))
        restrictedRule = Int16(all.count)
        all.append(SafetyRule("", .item, .locked, "Protected by macOS (System Integrity Protection)."))
        immutableRule = Int16(all.count)
        all.append(SafetyRule("", .item, .locked, "Marked as locked, so it can't be changed or deleted."))
        rules = all
        extensionRules = byExtension

        for (index, rule) in pathRules.enumerated() {
            var expanded = rule.path
            if expanded == "~" { expanded = home } else if expanded.hasPrefix("~/") { expanded = home + expanded.dropFirst() }
            var node = root
            for component in expanded.split(separator: "/").map(String.init) {
                let isPattern = component.contains { "*?[".contains($0) }
                if isPattern {
                    if let existing = node.patterns.first(where: { $0.0 == component })?.1 {
                        node = existing
                    } else {
                        let next = RuleNode()
                        node.patterns.append((component, next))
                        node = next
                    }
                } else {
                    let next = node.exact[component] ?? RuleNode()
                    node.exact[component] = next
                    node = next
                }
            }
            switch rule.scope {
            case .item: node.itemRule = Int16(index)
            case .contents: node.contentsRule = Int16(index)
            case .subtree:
                node.itemRule = Int16(index)
                node.contentsRule = Int16(index)
            }
        }
    }

    public func verdict(ruleIndex: Int16) -> SafetyVerdict {
        guard ruleIndex >= 0 else { return SafetyVerdict(level: .user, reason: nil) }
        let rule = rules[Int(ruleIndex)]
        return SafetyVerdict(level: rule.level, reason: rule.reason)
    }

    public func level(ruleIndex: Int16) -> SafetyLevel {
        ruleIndex >= 0 ? rules[Int(ruleIndex)].level : .user
    }

    /// Classifies an absolute path and returns the cursor for its children.
    public func start(at path: String) -> (rule: Int16, cursor: Cursor) {
        var cursor = Cursor(node: root, inherited: -1, insidePackage: false)
        var rule: Int16 = -1
        for component in path.split(separator: "/") {
            (rule, cursor) = child(of: cursor, name: String(component), kind: .directory, bsdFlags: 0)
        }
        return (rule, cursor)
    }

    /// The rule that applies to `name` inside the folder `cursor` describes, and the
    /// cursor for its own children.
    public func child(of cursor: Cursor, name: String, kind: NodeKind, bsdFlags: UInt32) -> (rule: Int16, cursor: Cursor) {
        let next = cursor.node?.child(name)
        var own = cursor.inherited
        var inherited = cursor.inherited
        var explicit = false
        if let next {
            if next.itemRule >= 0 { own = next.itemRule; explicit = true }
            if next.contentsRule >= 0 { inherited = next.contentsRule }
        }
        if !explicit, level(ruleIndex: own) == .user, kind != .directory,
           let dot = name.lastIndex(of: "."),
           let extRule = extensionRules[name[name.index(after: dot)...].lowercased()] {
            own = extRule
        }
        if cursor.insidePackage, level(ruleIndex: own) < .caution {
            own = packageRule
        }
        if bsdFlags & UInt32(SF_RESTRICTED) != 0 {
            own = restrictedRule
        } else if bsdFlags & (UInt32(SF_IMMUTABLE) | UInt32(UF_IMMUTABLE)) != 0 {
            own = immutableRule
        }
        let childCursor = Cursor(node: next, inherited: inherited,
                                 insidePackage: cursor.insidePackage || kind == .package)
        return (own, childCursor)
    }
}

extension SafetyClassifier {
    public static let builtInRules: [SafetyRule] = [
        // macOS itself (relevant when scanning outside the home folder).
        SafetyRule("/System", .subtree, .locked, "Part of macOS."),
        SafetyRule("/usr", .subtree, .locked, "Part of macOS."),
        SafetyRule("/usr/local", .subtree, .caution, "Command-line tools you or an installer added (Homebrew on Intel Macs)."),
        SafetyRule("/bin", .subtree, .locked, "Part of macOS."),
        SafetyRule("/sbin", .subtree, .locked, "Part of macOS."),
        SafetyRule("/private", .subtree, .caution, "System working files."),
        SafetyRule("/private/var/db", .subtree, .locked, "System databases macOS needs to run."),
        SafetyRule("/private/var/vm", .subtree, .locked, "Memory swap and sleep image, managed by macOS."),
        SafetyRule("/Library", .subtree, .caution, "Shared app and system support files."),
        SafetyRule("/Library/Apple", .subtree, .locked, "Part of macOS."),
        SafetyRule("/Library/Caches", .contents, .safe, "Caches are rebuilt automatically when needed."),
        SafetyRule("/Applications", .item, .locked, "The Applications folder itself."),
        SafetyRule("/opt/homebrew", .subtree, .caution, "Homebrew packages. Remove them with `brew uninstall` instead."),
        SafetyRule("/Users", .item, .locked, "Holds every account's home folder."),

        // The home folder and its standard folders: keep the folders, their contents are yours.
        SafetyRule("~", .item, .locked, "Your home folder."),
        SafetyRule("~/Desktop", .item, .locked, "A standard folder macOS expects. Its contents are yours to delete."),
        SafetyRule("~/Documents", .item, .locked, "A standard folder macOS expects. Its contents are yours to delete."),
        SafetyRule("~/Downloads", .item, .locked, "A standard folder macOS expects. Its contents are yours to delete."),
        SafetyRule("~/Movies", .item, .locked, "A standard folder macOS expects. Its contents are yours to delete."),
        SafetyRule("~/Music", .item, .locked, "A standard folder macOS expects. Its contents are yours to delete."),
        SafetyRule("~/Pictures", .item, .locked, "A standard folder macOS expects. Its contents are yours to delete."),
        SafetyRule("~/Public", .item, .locked, "A standard folder macOS expects."),
        SafetyRule("~/Applications", .item, .locked, "A standard folder macOS expects."),
        SafetyRule("~/.Trash", .item, .locked, "Your Trash. Empty it from the Finder."),
        SafetyRule("~/.Trash", .contents, .safe, "Already in the Trash."),
        SafetyRule("~/.*", .subtree, .caution, "Hidden settings for apps and command-line tools."),

        // Libraries that look like one file but are databases.
        SafetyRule("~/Pictures/*.photoslibrary", .item, .caution, "Your Photos library. Delete photos from within Photos instead."),
        SafetyRule("~/Music/Music", .subtree, .caution, "Your Music library. Remove songs from within Music instead."),
        SafetyRule("~/Movies/TV", .subtree, .caution, "Your TV library. Remove videos from within TV instead."),

        // ~/Library: app data by default.
        SafetyRule("~/Library", .item, .locked, "Your Library folder, which macOS and apps need."),
        SafetyRule("~/Library", .contents, .caution, "App settings and data. Deleting can reset or break apps."),
        SafetyRule("~/Library/Keychains", .subtree, .locked, "Your saved passwords and certificates."),
        SafetyRule("~/Library/Accounts", .subtree, .locked, "Your Internet accounts."),
        SafetyRule("~/Library/Daemon Containers", .subtree, .locked, "Data for macOS background services."),
        SafetyRule("~/Library/Biome", .subtree, .locked, "macOS usage data."),
        SafetyRule("~/Library/Sharing", .subtree, .locked, "macOS sharing data."),
        SafetyRule("~/Library/Mobile Documents", .subtree, .caution, "iCloud Drive. Deleting here deletes the file on all your devices."),
        SafetyRule("~/Library/CloudStorage", .subtree, .caution, "Cloud storage (Dropbox, Google Drive, OneDrive…). Deleting here deletes it from the cloud."),
        SafetyRule("~/Library/Mail", .subtree, .caution, "Your Mail messages. Delete mail from within Mail instead."),
        SafetyRule("~/Library/Messages", .subtree, .caution, "Your Messages history. Delete conversations from within Messages instead."),
        SafetyRule("~/Library/Caches", .contents, .safe, "Caches are rebuilt automatically when needed."),
        SafetyRule("~/Library/Logs", .contents, .safe, "Old log files."),
        SafetyRule("~/Library/Containers/*/Data/Library/Caches", .contents, .safe, "Caches are rebuilt automatically when needed."),
        SafetyRule("~/Library/Developer/Xcode/DerivedData", .contents, .safe, "Xcode build products, rebuilt on the next build."),
        SafetyRule("~/Library/Developer/Xcode/Archives", .contents, .safe, "Old app archives. Keep any you still need for crash symbolication."),
        SafetyRule("~/Library/Developer/Xcode/*DeviceSupport", .contents, .safe, "Debug symbols for devices, downloaded again when you connect one."),
        SafetyRule("~/Library/Developer/CoreSimulator/Caches", .contents, .safe, "Simulator caches."),
        SafetyRule("~/Library/Developer/CoreSimulator/Devices", .contents, .safe, "Simulator devices and their app data. Xcode recreates devices you still use."),
        SafetyRule("~/Library/Application Support/MobileSync/Backup", .contents, .user, "iPhone or iPad backups. Deleting one loses that backup."),
    ]

    public static let builtInExtensions: [(String, SafetyLevel, String)] = [
        ("dmg", .safe, "A disk image, usually an installer. Installed apps keep working without it."),
        ("pkg", .safe, "An installer package. Installed software keeps working without it."),
        ("xip", .safe, "A compressed installer archive."),
        ("ipa", .safe, "An iOS app package."),
    ]
}

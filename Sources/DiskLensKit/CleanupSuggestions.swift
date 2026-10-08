import Foundation

/// A group of items that are usually safe or worthwhile to delete.
public struct Suggestion: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String
    /// Largest first.
    public let items: [NodeID]
    public let bytes: Int64
    /// False for items that can't usefully go to the Trash (they're already there).
    public let canTrash: Bool
}

public enum CleanupSuggestions {
    public static func find(in tree: FileTree, home: String = NSHomeDirectory(), now: Date = Date()) -> [Suggestion] {
        let month: TimeInterval = 30 * 24 * 3600
        var found: [Suggestion] = []

        func node(_ relative: String) -> NodeID? {
            tree.node(atPath: relative.hasPrefix("~/") ? home + relative.dropFirst() : relative)
        }
        func children(_ relative: String) -> [NodeID] {
            node(relative).map { tree.visibleChildren($0) } ?? []
        }
        func add(_ id: String, _ title: String, _ symbol: String, _ detail: String,
                 _ items: [NodeID], canTrash: Bool = true) {
            let usable = items.filter { !tree.isRemoved($0) && tree.size($0) > 0 && tree.safety($0) != .locked }
                .sorted { tree.size($0) > tree.size($1) }
            let bytes = usable.reduce(Int64(0)) { $0 + tree.size($1) }
            guard bytes > 0 else { return }
            found.append(Suggestion(id: id, title: title, detail: detail, symbol: symbol,
                                    items: usable, bytes: bytes, canTrash: canTrash))
        }

        add("trash", "Trash", "trash",
            "Files already in the Trash still use space until you empty it. Empty the Trash from the Finder.",
            children("~/.Trash"), canTrash: false)

        var caches = children("~/Library/Caches")
        if let containers = node("~/Library/Containers") {
            for container in tree.children(containers) {
                if let cache = tree.node(atPath: tree.path(container) + "/Data/Library/Caches") {
                    caches += tree.visibleChildren(cache)
                }
            }
        }
        add("caches", "App Caches", "internaldrive",
            "Apps keep temporary copies of downloaded and computed data here and rebuild them when needed. Quit the apps first; expect them to be a little slower the next time they start.",
            caches)
        add("logs", "Logs", "doc.plaintext", "Old diagnostic logs from apps.", children("~/Library/Logs"))
        add("derivedData", "Xcode Build Data", "hammer",
            "Xcode's DerivedData: intermediate build products and indexes, recreated on the next build.",
            children("~/Library/Developer/Xcode/DerivedData"))

        var deviceSupport: [NodeID] = []
        if let xcode = node("~/Library/Developer/Xcode") {
            for child in tree.children(xcode) where tree.name(child).hasSuffix("DeviceSupport") {
                deviceSupport += tree.visibleChildren(child)
            }
        }
        add("deviceSupport", "Device Support Files", "iphone",
            "Debug symbols Xcode copied from devices you've connected. Xcode copies them again when you next debug on that OS version.",
            deviceSupport)

        var oldArchives: [NodeID] = []
        for day in children("~/Library/Developer/Xcode/Archives") {
            oldArchives += tree.visibleChildren(day).filter { tree.modified($0) < now.addingTimeInterval(-12 * month) }
        }
        add("archives", "Old Xcode Archives", "archivebox",
            "App archives over a year old. Keep any you still need for symbolicating crash reports from those releases.",
            oldArchives)
        add("simulators", "Simulator Devices", "ipad.and.iphone",
            "Simulator devices and their installed apps. Deleting a device here can confuse Xcode; for unused devices, run `xcrun simctl delete unavailable` in Terminal instead.",
            children("~/Library/Developer/CoreSimulator/Devices") + children("~/Library/Developer/CoreSimulator/Caches"))
        add("iosBackups", "iPhone & iPad Backups", "externaldrive.badge.timemachine",
            "Local device backups made by the Finder. Delete backups of devices you no longer have; a deleted backup can't be restored.",
            children("~/Library/Application Support/MobileSync/Backup"))

        // Installers and old downloads can be anywhere outside ~/Library.
        let library = node("~/Library")
        var installers: [NodeID] = []
        var oldLarge: [NodeID] = []
        let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "ipa"]
        tree.walk { id in
            if id == library || tree.isRemoved(id) { return false }
            let kind = tree.kind(id)
            if kind == .directory { return tree.size(id) >= 1_000_000 }
            let ext = (tree.name(id) as NSString).pathExtension.lowercased()
            if installerExtensions.contains(ext), tree.size(id) >= 1_000_000 {
                installers.append(id)
            } else if tree.size(id) >= 500_000_000, tree.lastUsedEstimate(id) < now.addingTimeInterval(-12 * month),
                      !tree.flags(id).contains(.insidePackage) {
                oldLarge.append(id)
            }
            return false
        }
        add("installers", "Installers & Disk Images", "shippingbox",
            "Installer packages and disk images. Apps you've installed from them keep working after you delete them.",
            installers)
        add("oldDownloads", "Old Downloads", "arrow.down.circle",
            "Items in Downloads over 50 MB that haven't been opened or changed in six months.",
            children("~/Downloads").filter {
                tree.size($0) >= 50_000_000 && tree.lastUsedEstimate($0) < now.addingTimeInterval(-6 * month)
            })
        add("oldLarge", "Large, Unused Files", "tortoise",
            "Files over 500 MB that haven't been opened or changed in a year.",
            oldLarge)
        return found
    }
}

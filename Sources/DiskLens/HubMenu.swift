import AppKit
import DiskLensKit

/// DiskLens's menu for ToolHUD's menu hub (see `MenuHub`). The menu bar item here is a
/// panel, which can't travel as a menu, so this is the panel as a menu: free space, then
/// the same buttons.
@MainActor
final class HubMenu: NSObject {
    static let shared = HubMenu()

    func start() {
        MenuHub.shared.start(menu: { self.build() }, icon: {
            let image = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: "DiskLens")
            image?.isTemplate = true
            return image
        })
    }

    private func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        menu.addItem(disabled: "Macintosh HD: \(Format.bytes(free)) available of \(Format.bytes(total))")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open DiskLens", action: #selector(openMain), target: self)
        menu.addItem(withTitle: "Scan Home Folder", action: #selector(scanHome), target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: "DiskLens Help", action: #selector(showHelp), target: self)
            .image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), target: self)
        menu.addItem(withTitle: "About DiskLens", action: #selector(showAbout), target: self)
        menu.addItem(withTitle: "Our other apps…", action: #selector(showOtherApps), target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DiskLens", action: #selector(quit), target: self)
        menu.addItem(.separator())
        menu.addItem(disabled: "\(AppInfo.name) \(AppInfo.displayVersion)")
        return menu
    }

    /// Opening the app again brings the main window back, as the panel's button does.
    @objc private func openMain() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }

    @objc private func scanHome() {
        openMain()
        AppDelegate.onURL?(URL(string: "disklens://scan-home")!)
    }

    @objc private func showHelp() { HelpWindow.shared.show() }
    @objc private func showSettings() { SettingsWindow.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        addItem(item)
        return item
    }

    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}

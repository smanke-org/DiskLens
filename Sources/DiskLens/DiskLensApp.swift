import DiskLensKit
import SwiftUI

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var presence = PresenceSettings.shared

    init() {
        // Before anything saves a setting: an empty domain means a brand-new install.
        AppDelegate.newInstall = SettingsSync.domainIsEmpty()
        SettingsWindow.shared.makeContent = { AnyView(SettingsView()) }
        let model = self.model
        // An automatic update must not restart DiskLens in the middle of its work.
        AutoUpdater.shared.appBusyReason = {
            if model.isScanning { return "a scan is running" }
            if !model.basket.isEmpty { return "items are waiting in the Trash list" }
            return nil
        }
        SettingsSync.shared.onApply = {
            model.reloadSyncedSettings()
            PresenceSettings.shared.reload()
        }
        AppDelegate.onURL = { url in
            switch url.host {
            case "scan-home":
                let home = NSHomeDirectory()
                if model.selectedTarget == home { model.scan() } else { model.select(home) }
            default:
                break
            }
        }
    }

    var body: some Scene {
        Window("DiskLens", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                // Right below About: the developer's site, which lists every app.
                Button("Our other apps…") { if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) } }
                Button("Check for Updates…") { AutoUpdater.shared.installNow() }
            }
            CommandGroup(replacing: .help) {
                Button("DiskLens Help") { HelpWindow.shared.show() }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.shared.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Folder or Drive…") { model.addTarget() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Treemap") { model.style = .treemap }.keyboardShortcut("1", modifiers: .command)
                Button("Sunburst") { model.style = .sunburst }.keyboardShortcut("2", modifiers: .command)
                Divider()
                Button("Zoom Out") { model.zoomOut() }.keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
            }
        }

        MenuBarExtra(isInserted: $presence.showInMenuBar) {
            MenuBarPanel()
        } label: {
            Image(systemName: "chart.pie")
                .accessibilityLabel("DiskLens")
        }
        .menuBarExtraStyle(.window)
    }
}

/// `AppPresence` values as observable state, for the menu bar scene and Settings.
@Observable
@MainActor
final class PresenceSettings {
    static let shared = PresenceSettings()

    var showInDock = AppPresence.showInDock {
        didSet {
            AppPresence.showInDock = showInDock
            AppPresence.applyDock(keepInFront: NSApp.keyWindow)
        }
    }

    var showInMenuBar = AppPresence.showInMenuBar {
        didSet { AppPresence.showInMenuBar = showInMenuBar }
    }

    /// Follows choices that arrived from another Mac.
    func reload() {
        if showInDock != AppPresence.showInDock { showInDock = AppPresence.showInDock }
        if showInMenuBar != AppPresence.showInMenuBar { showInMenuBar = AppPresence.showInMenuBar }
    }
}

/// The menu bar item's panel: free space at a glance and a way back to the window.
struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @State private var free: Int64 = 0
    @State private var total: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Macintosh HD").font(.headline)
            ProgressView(value: Double(total - free), total: Double(max(total, 1)))
            Text("\(Format.bytes(free)) available of \(Format.bytes(total))").foregroundStyle(.secondary)
            Divider()
            Button("Open DiskLens") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("DiskLens Help") { HelpWindow.shared.show() }
            Button("Settings…") { SettingsWindow.shared.show() }
            Button("About DiskLens") { NSApp.activate(ignoringOtherApps: true); NSApp.orderFrontStandardAboutPanel(nil) }
            Button("Our other apps…") { if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) } }
            Button("Quit DiskLens") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 260)
        .task {
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ])
            free = values?.volumeAvailableCapacityForImportantUsage ?? 0
            total = Int64(values?.volumeTotalCapacity ?? 0)
        }
    }
}

/// The Dock icon's menu, and what happens when the app is opened again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by DiskLensApp.init, which runs before anything is stored.
    static var newInstall = false
    /// Runs a `disklens://` URL; set by DiskLensApp.init, which owns the model.
    static var onURL: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.start()
        if !AppPresence.showInDock { AppPresence.applyDock() }
        #if DEBUG
        // A test run shares the installed app's settings, so it checks Help and stops
        // before sync or updates start.
        if let snapshot = ProcessInfo.processInfo.environment["DISKLENS_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: nil)
            return
        }
        #endif
        if Self.newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()
        AutoUpdater.shared.start()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(showSettings))
    }

    /// Reopening brings the main window back (SwiftUI does that when this returns true).
    /// With both icons hidden it also opens Settings, the only other way back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AppPresence.showInDock && !AppPresence.showInMenuBar { showSettings() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `disklens://open` and `disklens://scan-home` (from ToolHUD, Shortcuts or a script)
    /// bring DiskLens forward; the second also scans your home folder.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "disklens" {
            NSApp.activate(ignoringOtherApps: true)
            Self.onURL?(url)
        }
    }

    @objc func showSettings() {
        SettingsWindow.shared.show()
    }
}

import DiskLensKit
import SwiftUI

/// `disklens <command>` (the app binary under a short name) runs the command against the
/// running app and exits, without starting a second copy. See Agent/AgentCLI.swift.
@main
enum Launcher {
    @MainActor
    static func main() {
        if let code = AgentCLI.runIfRequested() { exit(code) }
        DiskLensApp.main()
    }
}

struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var presence = PresenceSettings.shared
    @State private var hub = MenuHub.shared

    init() {
        // Before anything saves a setting: an empty domain means a brand-new install.
        AppDelegate.newInstall = SettingsSync.domainIsEmpty()
        SettingsWindow.shared.makeContent = { AnyView(SettingsView()) }
        let model = self.model
        // `disklens` and the MCP server run their commands on this model.
        AgentCommands.model = model
        // An automatic update must not restart DiskLens in the middle of its work.
        AutoUpdater.shared.appBusyReason = {
            if model.isScanning { return "a scan is running" }
            if !model.basket.isEmpty { return "items are waiting in the Trash list" }
            return nil
        }
        SettingsSync.shared.onApply = {
            model.reloadSyncedSettings()
            PresenceSettings.shared.reload()
            MenuHub.shared.reload()
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
        // A Debug test copy of the agent CLI (APP_STORE) opens no window unless asked
        // (`disklens window open`), so it never scans the home folder on its own.
        .defaultLaunchBehavior(AgentSocket.isTestRun ? .suppressed : .automatic)
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

        // ToolHUD can take the item into its own menu while it runs; that never changes the
        // setting, so the icon comes back when ToolHUD quits.
        MenuBarExtra(isInserted: Binding(get: { presence.showInMenuBar && !hub.isHosted && !AgentSocket.isTestRun },
                                         set: { if !hub.isHosted { presence.showInMenuBar = $0 } })) {
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
            Button("About DiskLens") { NSApp.activate(ignoringOtherApps: true); AppInfo.showAbout() }
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

/// Quits DiskLens without asking: for quitting itself (installing an update, ending a test).
@MainActor
enum QuitConfirmation {
    /// "Ask before quitting" in Settings › General; on by default, synced.
    static let key = "confirmQuit"
    private(set) static var confirmed = false

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
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
        #if DEBUG
        // A test run of the agent CLI (APP_STORE): its own saved scans and settings, and the
        // agent socket. Nothing else starts: no sync, updater, ToolHUD menu or menu bar item.
        if AgentSocket.isTestRun {
            NSApp.setActivationPolicy(.accessory)
            AgentSocket.listen { await AgentRouter.handle($0) }
            return
        }
        #endif
        AppAppearance.start()
        if !AppPresence.showInDock { AppPresence.applyDock() }
        #if DEBUG
        // A test run shares the installed app's settings, so it checks Help and stops
        // before sync or updates start.
        if let snapshot = ProcessInfo.processInfo.environment["DISKLENS_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: nil)
            return
        }
        if let how = ProcessInfo.processInfo.environment["DISKLENS_DEBUG_QUIT_TEST"] {
            DebugQuitTest.run(how)
            return
        }
        // The update prompt, What's New and Settings drawn to PNGs; also starts nothing else.
        if let folder = ProcessInfo.processInfo.environment["DISKLENS_DEBUG_UPDATE_NOTES"] {
            DebugUpdateNotes.run(folder: folder)
            return
        }
        #endif
        #if !DEBUG
        // `disklens` and the MCP server talk to the app through this. A Debug build listens
        // only as a test copy (above): on this path it would take the installed app's socket.
        AgentSocket.listen { await AgentRouter.handle($0) }
        #endif
        if Self.newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()
        AutoUpdater.shared.start()
        HubMenu.shared.start()
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

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when DiskLens quits itself to install an update.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard QuitConfirmation.isOn, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }

        // With the Dock icon off, DiskLens needs to be a regular app for the alert to come
        // to the front; the old policy goes back a runloop turn later, once the alert is
        // gone (AppKit ignores it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit \(AppInfo.name)?"
        alert.informativeText = "A scan in progress stops, and items waiting in the Trash list are forgotten."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: QuitConfirmation.key) }
        return .terminateNow
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

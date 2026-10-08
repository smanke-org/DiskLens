import DiskLensKit
import SwiftUI

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var presence = PresenceSettings.shared

    init() {
        SettingsWindow.shared.makeContent = { AnyView(SettingsView()) }
    }

    var body: some Scene {
        Window("DiskLens", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateController.checkForUpdates() }
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
            Button("Settings…") { SettingsWindow.shared.show() }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AppPresence.showInDock { AppPresence.applyDock() }
        if UserDefaults.standard.object(forKey: "checkForUpdatesAutomatically") as? Bool ?? true {
            UpdateController.checkForUpdates(silent: true)
        }
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

    @objc func showSettings() {
        SettingsWindow.shared.show()
    }
}

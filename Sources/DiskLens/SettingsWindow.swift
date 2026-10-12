import AppKit
import DiskLensKit
import SwiftUI

/// Settings in an AppKit window, so the Dock menu and the menu bar panel can open it
/// (SwiftUI's Settings scene can't be opened from AppKit).
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()

    var makeContent: (() -> AnyView)?
    private var window: NSWindow?

    func show() {
        if window == nil, let makeContent {
            let hosting = NSHostingController(rootView: makeContent())
            // Without this a grouped Form has no natural height and opens as a sliver.
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "DiskLens Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @State private var presence = PresenceSettings.shared
    @State private var fullDiskAccess = FullDiskAccess.isGranted
    @State private var cacheCleared = false

    var body: some View {
        Form {
            Section("Where DiskLens appears") {
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                if !presence.showInDock && !presence.showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "DiskLens", settingsName: "Settings"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Access") {
                LabeledContent("Full Disk Access") {
                    if fullDiskAccess {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
                    }
                }
                Text("Without it, macOS hides some folders (Mail, Messages, Safari and others) from every app, so their size isn't counted. DiskLens only reads file sizes and dates; it never opens your files except to compare duplicates.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Saved scans") {
                Text("DiskLens keeps the last scan of each location so it opens instantly, then rescans only folders that changed.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(cacheCleared ? "Saved Scans Cleared" : "Clear Saved Scans") {
                    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("com.smanke.DiskLens/Scans")
                    try? FileManager.default.removeItem(at: caches)
                    cacheCleared = true
                }
                .disabled(cacheCleared)
            }
            SyncUpdateSections()
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = FullDiskAccess.isGranted
        }
    }
}

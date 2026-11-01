import AppKit
import DiskLensKit
import SwiftUI

/// Settings in an AppKit window, so the Dock menu and the menu bar panel can open it
/// (SwiftUI's Settings scene can't be opened from AppKit).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    /// The width the form is laid out for, and the narrowest the window can be dragged to.
    static let width: CGFloat = 460
    static let minimumSize = NSSize(width: width, height: 280)

    /// The content size the user last dragged the window to (per Mac, not synced), or nil
    /// while they haven't: then it opens at the form's own height.
    static var chosenSize: NSSize? {
        get { UserDefaults.standard.string(forKey: "settings.contentSize").map(NSSizeFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromSize), forKey: "settings.contentSize") }
    }

    var makeContent: (() -> AnyView)?
    private var window: NSWindow?

    func show() {
        if window == nil, let makeContent {
            // The round Help button in the corner, as macOS does.
            let content = AnyView(VStack(spacing: 0) {
                makeContent()
                HStack {
                    Spacer()
                    HelpButton(topic: "getting-started").fixedSize()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            })
            // The Form's natural height (measured at the form's width), capped to the
            // screen, with the Form scrolling inside. Letting SwiftUI size the window to the
            // Form's full height crashed once the Form grew taller than the screen: AppKit
            // clamped the window, SwiftUI asked to grow again, and AppKit aborted the
            // update-constraints loop. It fills whatever size the user drags the window to.
            let natural = NSHostingView(rootView: content.frame(width: Self.width)).fittingSize.height
            let hosting = NSHostingController(rootView: content.frame(minWidth: Self.width, maxWidth: .infinity,
                                                                      maxHeight: .infinity))
            hosting.sizingOptions = []
            // Inside a plain container, so SwiftUI doesn't manage the window's size limits
            // (as the window's own content controller it cleared the minimum size whenever a
            // sheet came and went).
            let container = NSViewController()
            container.view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
            container.addChild(hosting)
            hosting.view.frame = container.view.bounds
            hosting.view.autoresizingMask = [.width, .height]
            container.view.addSubview(hosting.view)
            let window = NSWindow(contentViewController: container)
            window.title = "DiskLens Settings"
            // Resizable as well as scrolling: drag it bigger to see more at once.
            window.styleMask = [.titled, .closable, .resizable]
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            var size = NSSize(width: Self.width, height: min(max(natural, Self.minimumSize.height), available))
            if let chosen = Self.chosenSize {
                size = NSSize(width: max(chosen.width, Self.minimumSize.width),
                              height: min(max(chosen.height, Self.minimumSize.height), available))
            }
            window.setContentSize(size)
            window.contentMinSize = Self.minimumSize
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // After an update whose notes weren't seen yet.
        if let window { WhatsNew.shared.present(on: window) }
    }

    /// This version's release notes, when asked for from Settings.
    func showWhatsNew() {
        if let window { WhatsNew.shared.present(on: window, asked: true) }
    }

    /// A size the user dragged to is kept, and used next time.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        Self.chosenSize = window.contentRect(forFrameRect: window.frame).size
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    #endif
}

struct SettingsView: View {
    @State private var presence = PresenceSettings.shared
    @State private var hub = MenuHub.shared
    @State private var fullDiskAccess = FullDiskAccess.isGranted
    @State private var cacheCleared = false
    @AppStorage(QuitConfirmation.key) private var confirmQuit = true

    var body: some View {
        Form {
            Section {
                AppearancePicker()
                Toggle("Ask before quitting", isOn: $confirmQuit)
                    .help("Quitting DiskLens asks first, so a stray ⌘Q doesn't stop a scan or lose the Trash list.")
            } header: {
                Text("General")
            } footer: {
                Text(AppAppearance.footer(appName: "DiskLens"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Where DiskLens appears") {
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                Toggle("Put in ToolHUD’s menu while ToolHUD is running", isOn: $hub.foldIntoToolHUD)
                    .help("ToolHUD shows DiskLens’s menu bar panel as a submenu of its own, and DiskLens’s icon leaves the menu bar until ToolHUD quits.")
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = FullDiskAccess.isGranted
        }
    }
}

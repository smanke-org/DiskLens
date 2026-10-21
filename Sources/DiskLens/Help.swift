import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. `Help.resolve` swaps `{…}` tokens for the user's own settings, such
/// as their shortcuts, so the text matches what they've set up.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// DiskLens has no shortcuts the user sets, so nothing needs swapping.
    static func resolve(_ text: String) -> String { text }
    static var debugTokens: String { "" }
    static let testTabs = ["Settings"]
    static func topic(forSettingsTab tab: String) -> String { "getting-started" }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("DiskLens shows what's using your disk space and helps you clear it safely. Pick a disk or folder in the sidebar to scan it; each scan is remembered, and the next rescan only looks at folders that changed."),
            .keys([
                ("⌘O", "Add a folder or drive to scan"),
                ("⌘R", "Rescan what changed (hold the button's arrow for a full rescan)"),
                ("⌘1 / ⌘2", "Treemap or sunburst"),
                ("⌘[ or ⌘↑", "Zoom out to the enclosing folder"),
            ]),
            .heading("Full Disk Access"),
            .text("Without Full Disk Access, macOS hides some folders (Mail, Messages, Safari and other apps' data), and their space shows as unreadable. Turn it on in Settings › Access for a complete picture. DiskLens only reads sizes; it never uploads anything."),
            .tip("The menu bar icon shows how much space is free on your startup disk at a glance."),
            .tip("While ToolHUD is running, DiskLens's free space and actions move into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings."),
        ]),

        HelpTopic(id: "views", title: "Treemap and Sunburst", symbol: "square.grid.3x3.fill", blocks: [
            .text("The treemap draws every folder and file as a rectangle sized by how much space it takes. The sunburst draws the same thing as rings, with the folder you're in at the center. Switch with ⌘1 and ⌘2."),
            .keys([
                ("Click", "Select an item; its details show on the right"),
                ("Double-click", "Zoom into a folder"),
                ("⌘[ or ⌘↑", "Zoom back out"),
                ("Right-click", "Zoom In, Show in Finder, Open, Add to Trash List, Copy Path"),
            ]),
            .heading("Colors"),
            .text("Color items by file type, or by how safe they are to delete:"),
            .keys([
                ("Safe to delete", "Rebuilt or downloaded again automatically: caches, build products, installers"),
                ("Your files", "Documents, photos and the like: deleting is your call"),
                ("Use caution", "App or system data where deleting can reset or break something"),
                ("Protected", "Required or protected by macOS; never offered for deletion"),
            ]),
        ]),

        HelpTopic(id: "lists", title: "Finding Space", symbol: "list.bullet.rectangle", blocks: [
            .keys([
                ("Browse", "The folder you're in, largest first"),
                ("Largest Files", "The biggest files anywhere in the scan; filter by size, age and type"),
                ("Least Used", "Big files you haven't opened in a long time"),
                ("Cleanup Suggestions", "Caches, installers, old files and other likely leftovers, grouped"),
                ("Duplicates", "Files over 1 MB with identical contents"),
            ]),
            .text("In a list, double-click a folder to open it, or another item to show it. Delete adds the selection to the Trash list. In Duplicates, one button keeps the first copy and adds the rest to the Trash list."),
            .tip("A duplicate marked as sharing storage is a clone of another file: deleting it frees little or no space."),
        ]),

        HelpTopic(id: "trash", title: "The Trash List", symbol: "trash", blocks: [
            .text("Nothing is deleted straight away. Items you choose go on the Trash list (in the panel on the right), so you can review them together. When you're ready, \"Move to Trash…\" moves them to the Finder Trash, and you can still put them back from there."),
            .keys([
                ("Delete", "Add the selected list items to the Trash list"),
                ("Add to Trash List", "In any right-click menu"),
                ("× beside an item", "Take it off the Trash list"),
                ("Clear", "Empty the Trash list without deleting anything"),
            ]),
            .text("The space is freed when you empty the Trash in Finder. Protected items can't be added."),
        ]),

        HelpTopic(id: "settings", title: "Settings", symbol: "gearshape", blocks: [
            .text("Settings chooses the appearance, whether DiskLens shows in the Dock and the menu bar, Full Disk Access, syncing settings with your other Macs, and how updates are handled. With both the Dock and menu bar icons off, open DiskLens again from Finder or Spotlight to reach Settings."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .keys([
                ("disklens://open", "Open DiskLens"),
                ("disklens://scan-home", "Scan your home folder"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's DiskLens buttons use them."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("Some folders show as unreadable"),
            .text("macOS hides them without Full Disk Access. Turn it on in Settings › Access, then rescan."),
            .heading("The free space didn't change after moving items to the Trash"),
            .text("Empty the Trash in Finder. Space used by clones or snapshots may also take a while for macOS to release."),
            .heading("Numbers look out of date"),
            .text("Press ⌘R to rescan what changed, or hold the rescan arrow for a full rescan."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DiskLensHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}

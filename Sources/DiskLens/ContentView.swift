import DiskLensKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var window: NSWindow?
    @State private var showInspector = true
    @State private var fullDiskAccess = FullDiskAccess.isGranted
    @AppStorage("visualizationFraction") private var vizFraction = 0.55

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            // A fixed-width side panel rather than .inspector: the inspector's split view
            // re-measured its minimum size in a loop until AppKit aborted the app.
            HStack(spacing: 0) {
                detail
                if showInspector, let tree = model.tree {
                    Divider()
                    InspectorView(model: model, tree: tree)
                        .frame(width: 300)
                }
            }
        }
        .searchable(text: $model.filter.search, placement: .toolbar, prompt: "Filter by name")
        .toolbar { toolbar }
        .navigationTitle(model.currentTarget.title)
        .navigationSubtitle(subtitle)
        .background(WindowReader(window: $window))
        .environment(\.window, window)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess = FullDiskAccess.isGranted
            if case .ready = model.phase { model.rescanChanges() }
        }
        .onAppear { model.select(model.selectedTarget) }
    }

    private var subtitle: String {
        guard let tree = model.tree else { return "" }
        return "\(Format.bytes(tree.size(FileTree.root))) in \(Format.count(tree.fileCount(FileTree.root))) files"
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if !fullDiskAccess, let tree = model.tree, !tree.unreadableFolders.isEmpty {
                FullDiskAccessBanner(unreadable: tree.unreadableFolders.count)
            }
            switch (model.phase, model.tree) {
            case (_, let tree?):
                Splitter(fraction: $vizFraction) {
                    VisualizationPane(model: model, tree: tree)
                } bottom: {
                    VStack(spacing: 0) {
                        FilterBar(model: model)
                        Divider()
                        LensPane(model: model, tree: tree)
                    }
                }
            case (.scanning, nil):
                ScanProgressView(model: model)
            case (.loading, nil):
                ProgressView("Opening the last scan…").frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                ContentUnavailableView {
                    Label("Not scanned yet", systemImage: "internaldrive")
                } description: {
                    Text("Scan \(model.currentTarget.title) to see what's using space.")
                } actions: {
                    Button("Scan") { model.scan() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { model.zoomOut() }
                .disabled(model.tree == nil || model.focus == FileTree.root)
                .keyboardShortcut("[", modifiers: .command)
                .help("Zoom out to the enclosing folder")
        }
        ToolbarItemGroup {
            if model.isScanning {
                if model.tree != nil {
                    ProgressView().controlSize(.small)
                        .help("Updating: \(Format.count(model.progress.files)) files checked")
                }
                Button("Stop", systemImage: "stop.circle") { model.cancelScan() }
                    .help("Stop scanning")
            } else {
                Menu {
                    Button("Update Changes") { model.rescanChanges() }
                    Button("Full Rescan") { model.scan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                } primaryAction: {
                    model.rescanChanges()
                }
                .help("Rescan folders that changed (hold the arrow for a full rescan)")
                .keyboardShortcut("r", modifiers: .command)
            }
            Picker("View", selection: $model.style) {
                ForEach(VisualizationStyle.allCases) { style in
                    Label(style.title, systemImage: style.symbol)
                        .accessibilityLabel(style.title)
                        .tag(style)
                }
            }
            .pickerStyle(.segmented)
            .help("Treemap or sunburst")
            Menu {
                Picker("Colors", selection: $model.colors) {
                    ForEach(ColorScheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Colors", systemImage: model.colors == .type ? "paintpalette" : "checkmark.shield")
            }
            .help("Color items by file type or by how safe they are to delete")
            Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
                .help("Show or hide details and the Trash list")
        }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var updates = UpdateAvailability.shared

    var body: some View {
        List(selection: Binding<Lens?>(get: { model.lens }, set: { if let lens = $0 { model.lens = lens } })) {
            Section("Locations") {
                ForEach(model.targets) { target in
                    Button {
                        model.select(target.id)
                    } label: {
                        HStack {
                            Label(target.title, systemImage: target.symbol)
                                .fontWeight(target.id == model.selectedTarget ? .semibold : .regular)
                            Spacer()
                            if target.id == model.selectedTarget {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scan \(target.title)")
                    .accessibilityAddTraits(target.id == model.selectedTarget ? .isSelected : [])
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)])
                        }
                        if !target.isHome {
                            Button("Remove from List") { model.removeTarget(target) }
                        }
                    }
                    .help(target.path)
                }
                Button("Add Folder or Drive…", systemImage: "plus") { model.addTarget() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Section("Show") {
                ForEach(Lens.allCases) { lens in
                    Label(lens.title, systemImage: lens.symbol)
                        .badge(badge(for: lens))
                        .tag(lens)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let version = updates.pending {
                    Button("Update to \(version)…", systemImage: "arrow.down.circle") {
                        UpdateController.checkForUpdates()
                    }
                    .buttonStyle(.borderless)
                }
                VolumeSummary(path: model.currentTarget.path, version: model.treeVersion)
            }
            .padding(12)
        }
    }

    private func badge(for lens: Lens) -> Text? {
        switch lens {
        case .suggestions:
            let total = model.suggestions.totalBytes
            return total > 0 ? Text(Format.bytes(total)) : nil
        case .duplicates:
            let total = model.duplicates.reclaimable
            return total > 0 ? Text(Format.bytes(total)) : nil
        default:
            return nil
        }
    }
}

/// Free space on the volume being scanned.
struct VolumeSummary: View {
    let path: String
    let version: Int
    @State private var info: (name: String, free: Int64, total: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info {
                Text(info.name).font(.caption.weight(.semibold))
                ProgressView(value: Double(info.total - info.free), total: Double(max(info.total, 1)))
                Text("\(Format.bytes(info.free)) available of \(Format.bytes(info.total))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(path)#\(version)") {
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                                          .volumeAvailableCapacityForImportantUsageKey])
            if let values, let total = values.volumeTotalCapacity {
                info = (values.volumeName ?? "Disk", values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(total))
            }
        }
    }
}

struct FilterBar: View {
    @Bindable var model: AppModel

    private static let sizes: [(String, Int64)] = [("Any size", 0), ("Over 1 MB", 1_000_000), ("Over 10 MB", 10_000_000),
                                                   ("Over 100 MB", 100_000_000), ("Over 1 GB", 1_000_000_000)]
    private static let ages: [(String, Int)] = [("Any time", 0), ("Unused 3 months", 3), ("Unused 6 months", 6),
                                                ("Unused 1 year", 12), ("Unused 2 years", 24)]

    var body: some View {
        HStack(spacing: 10) {
            Label(model.lens.title, systemImage: model.lens.symbol).font(.headline)
            if model.lens != .suggestions && model.lens != .duplicates {
                Text("in \(model.displayName(model.focus))").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.lens != .suggestions && model.lens != .duplicates {
                filters
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var filters: some View {
            Menu {
                ForEach(FileCategory.allCases) { category in
                    Toggle(isOn: Binding(
                        get: { model.filter.categories.contains(category) },
                        set: { if $0 { model.filter.categories.insert(category) } else { model.filter.categories.remove(category) } }
                    )) {
                        Label(category.title, systemImage: category.symbol)
                    }
                }
                Divider()
                Button("All Types") { model.filter.categories = [] }
            } label: {
                Text(model.filter.categories.isEmpty ? "All types"
                     : model.filter.categories.count == 1 ? model.filter.categories.first!.title
                     : "\(model.filter.categories.count) types")
            }
            .fixedSize()
            Picker("Size", selection: $model.filter.minimumSize) {
                ForEach(Self.sizes, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden().fixedSize()
            Picker("Age", selection: Binding(
                get: { model.filter.unusedSince.map { months(before: $0) } ?? 0 },
                set: { model.filter.unusedSince = $0 == 0 ? nil : Calendar.current.date(byAdding: .month, value: -$0, to: Date()) }
            )) {
                ForEach(Self.ages, id: \.1) { Text($0.0).tag($0.1) }
            }
            .labelsHidden().fixedSize()
            Toggle("Hide protected", isOn: $model.filter.hideProtected)
                .toggleStyle(.checkbox)
            if model.filter.isActive {
                Button("Clear") { model.filter = FileFilter() }.buttonStyle(.borderless)
            }
    }

    private func months(before date: Date) -> Int {
        let months = Calendar.current.dateComponents([.month], from: date, to: Date()).month ?? 0
        return Self.ages.map(\.1).min { abs($0 - months) < abs($1 - months) } ?? 0
    }
}

/// Breadcrumbs, the treemap or sunburst, and a line describing what's under the pointer.
struct VisualizationPane: View {
    let model: AppModel
    let tree: FileTree

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tree.lineage(model.focus), id: \.self) { id in
                        if id != FileTree.root { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button(model.displayName(id)) {
                            model.focus = id
                        }
                        .buttonStyle(.borderless)
                        .fontWeight(id == model.focus ? .semibold : .regular)
                    }
                    Text(Format.bytes(tree.size(model.focus))).foregroundStyle(.secondary).padding(.leading, 6)
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 28)
            Group {
                switch model.style {
                case .treemap: TreemapView(model: model, tree: tree)
                case .sunburst: SunburstView(model: model, tree: tree).padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            HoverLine(model: model, tree: tree)
        }
    }
}

private struct HoverLine: View {
    let model: AppModel
    let tree: FileTree

    var body: some View {
        HStack(spacing: 8) {
            if let id = model.hovered ?? model.selection {
                Image(systemName: tree.kind(id) == .directory ? "folder" : tree.category(id).symbol)
                Text(tree.path(id)).lineLimit(1).truncationMode(.head)
                Spacer()
                Text(Format.bytes(tree.size(id))).monospacedDigit()
                SafetyBadge(level: tree.safety(id), compact: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("Click to select, double-click to zoom in, right-click for actions.")
                            .foregroundStyle(.secondary).fixedSize()
                        Spacer()
                        legend
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        legend
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    @ViewBuilder private var legend: some View {
        switch model.colors {
        case .type:
            ForEach([FileCategory.video, .audio, .image, .document, .archive, .app], id: \.self) { category in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.color(category)).frame(width: 9, height: 9)
                    Text(category.title).font(.caption).fixedSize()
                }
            }
        case .safety:
            ForEach(SafetyLevel.allCases, id: \.self) { level in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.color(level)).frame(width: 9, height: 9)
                    Text(level.title).font(.caption).fixedSize()
                }
            }
        }
    }
}

struct ScanProgressView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Scanning \(model.currentTarget.title)…").font(.title3)
            Text("\(Format.count(model.progress.files)) files in \(Format.count(model.progress.folders)) folders · \(Format.bytes(model.progress.bytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Stop") { model.cancelScan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FullDiskAccessBanner: View {
    let unreadable: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.count(unreadable)) folders couldn't be read").font(.headline)
                Text("macOS protects some folders (Mail, Messages, Safari and others). Give DiskLens Full Disk Access to include them, then rescan.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
        }
        .padding(10)
        .background(.orange.opacity(0.1))
    }
}

enum FullDiskAccess {
    /// Reading the TCC database needs Full Disk Access, so whether it opens is the test.
    static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

/// Two panes stacked vertically with a draggable divider. (VSplitView inside a
/// NavigationSplitView with an inspector loops on layout and crashes AppKit.)
struct Splitter<Top: View, Bottom: View>: View {
    @Binding var fraction: Double
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let topHeight = max(160, min(height - 160, height * fraction))
            VStack(spacing: 0) {
                top.frame(height: topHeight)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("splitter"))
                        .onChanged { value in
                            if dragStart == nil { dragStart = fraction }
                            guard height > 0, let start = dragStart else { return }
                            fraction = max(0.15, min(0.85, start + value.translation.height / height))
                        }
                        .onEnded { _ in dragStart = nil })
                bottom.frame(maxHeight: .infinity)
            }
            .coordinateSpace(name: "splitter")
        }
    }
}

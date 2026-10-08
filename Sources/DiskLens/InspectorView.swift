import DiskLensKit
import SwiftUI

/// Details of the selected item, and the Trash list.
struct InspectorView: View {
    let model: AppModel
    let tree: FileTree
    @Environment(\.window) private var window

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if let id = model.selection, !tree.isRemoved(id) {
                    ItemDetails(model: model, tree: tree, id: id)
                        .padding()
                } else {
                    Text("Select an item to see its details.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            Divider()
            BasketView(model: model, tree: tree)
        }
    }
}

private struct ItemDetails: View {
    let model: AppModel
    let tree: FileTree
    let id: NodeID
    @State private var privateSize: Int64?

    var body: some View {
        let verdict = tree.safetyVerdict(id)
        let isContainer = tree.kind(id).isContainer
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: tree.path(id)))
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(tree.name(id)).font(.headline).textSelection(.enabled)
                    Text(Format.bytes(tree.size(id))).font(.title2.weight(.semibold))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SafetyBadge(level: verdict.level)
                    .font(.headline)
                if let reason = verdict.reason {
                    Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Your own file. Delete it if you don't need it.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.color(verdict.level).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Kind", isContainer && tree.kind(id) == .directory ? "Folder" : tree.category(id).title)
                if isContainer { row("Contains", "\(Format.count(tree.fileCount(id))) files") }
                if tree.logicalSize(id) != tree.size(id) {
                    row("Listed size", Format.bytes(tree.logicalSize(id)))
                }
                if let privateSize, privateSize < tree.size(id) {
                    row("Frees", "\(Format.bytes(privateSize)) (shares storage with APFS clones)")
                }
                row("Modified", Format.date(tree.modified(id)))
                if let used = model.lastUsed(id) {
                    row("Last opened", Format.date(used))
                } else if !isContainer {
                    row("Last read", Format.date(tree.accessed(id)))
                }
                if tree.flags(id).contains(.dataless) { row("iCloud", "Not downloaded; uses no space on this Mac") }
                if tree.flags(id).contains(.hardLinkDuplicate) { row("Hard link", "Another name for a file counted elsewhere") }
                if tree.flags(id).contains(.unreadable) { row("Access", "Couldn't be read. Give DiskLens Full Disk Access.") }
                if tree.flags(id).contains(.mountPoint) { row("Volume", "Another disk is mounted here; not included") }
            }
            .font(.callout)

            Text(tree.path(id))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button("Show in Finder") { model.revealInFinder(id) }
                if isContainer {
                    Button("Zoom In") { model.zoom(into: id) }
                }
            }
            if model.basket.contains(id) {
                Button("Remove from Trash List", systemImage: "trash.slash") { model.removeFromBasket(id) }
            } else {
                Button("Add to Trash List", systemImage: "trash") { model.addToBasket([id]) }
                    .disabled(!model.canDelete(id))
                    .help(verdict.level == .locked ? "macOS needs this; DiskLens won't delete it." : "")
            }
        }
        .task(id: id) {
            privateSize = nil
            await model.loadLastUsed(for: [id])
            guard tree.kind(id) == .file else { return }
            let path = tree.path(id)
            privateSize = await Task.detached { DuplicateFinder.cloneInfo(path: path)?.privateSize }.value
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BasketView: View {
    let model: AppModel
    let tree: FileTree
    @Environment(\.window) private var window

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Trash List", systemImage: "trash").font(.headline)
                Spacer()
                if !model.basket.isEmpty {
                    Button("Clear") { model.basket.removeAll() }.buttonStyle(.borderless)
                }
            }
            if model.basket.isEmpty {
                Text("Add items here to review them, then move them to the Trash together.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                List {
                    ForEach(model.basket, id: \.self) { id in
                        HStack {
                            Image(systemName: Palette.symbol(tree.safety(id))).foregroundStyle(Palette.color(tree.safety(id)))
                            Text(tree.name(id)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.bytes(tree.size(id))).monospacedDigit().foregroundStyle(.secondary)
                            Button { model.removeFromBasket(id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.reveal(id) }
                    }
                }
                .listStyle(.plain)
                .frame(minHeight: 60, maxHeight: 200)
                Button {
                    model.confirmAndTrashBasket(in: window)
                } label: {
                    Text("Move \(model.basket.count) to Trash (\(Format.bytes(model.basketBytes)))…")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            if model.trashedThisSession > 0 {
                Text("Moved \(Format.bytes(model.trashedThisSession)) to the Trash. Empty the Trash to free the space.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }
}

/// The hosting window, for presenting sheets from SwiftUI.
private struct WindowKey: EnvironmentKey {
    static let defaultValue: NSWindow? = nil
}

extension EnvironmentValues {
    var window: NSWindow? {
        get { self[WindowKey.self] }
        set { self[WindowKey.self] = newValue }
    }
}

/// Finds the NSWindow a view lives in.
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window !== window { DispatchQueue.main.async { window = nsView.window } }
    }
}

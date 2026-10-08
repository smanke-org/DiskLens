import DiskLensKit
import SwiftUI

/// The list under the visualization, which depends on the lens chosen in the sidebar.
struct LensPane: View {
    let model: AppModel
    let tree: FileTree

    var body: some View {
        switch model.lens {
        case .browse:
            let ids = tree.visibleChildren(model.focus).filter { !model.filter.isActive || tree.matches($0, model.filter) }
            FileListView(model: model, ids: ids)
        case .largest:
            LargestFilesView(model: model, tree: tree)
        case .leastUsed:
            LeastUsedView(model: model, tree: tree)
        case .suggestions:
            SuggestionsView(model: model, tree: tree)
        case .duplicates:
            DuplicatesView(model: model, tree: tree)
        }
    }
}

private struct QueryKey: Equatable {
    var focus: NodeID
    var version: Int
    var filter: FileFilter
}

struct LargestFilesView: View {
    let model: AppModel
    let tree: FileTree
    @State private var ids: [NodeID] = []

    var body: some View {
        FileListView(model: model, ids: ids, showLocation: true)
            .task(id: QueryKey(focus: model.focus, version: model.treeVersion, filter: model.filter)) {
                guard let tree = model.tree else { return }
                let focus = model.focus, filter = model.filter
                ids = await Task.detached { tree.largestFiles(under: focus, limit: 500, filter: filter) }.value
            }
    }
}

/// Large files ordered by when they were last used. Spotlight's last-opened date is
/// looked up for the largest few thousand files, then the oldest come first.
struct LeastUsedView: View {
    let model: AppModel
    let tree: FileTree
    @State private var ids: [NodeID] = []
    @State private var loading = false
    @AppStorage("leastUsedMinimumMB") private var minimumMB = 10

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files over")
                Picker("Files over", selection: $minimumMB) {
                    ForEach([1, 10, 100, 500, 1000], id: \.self) { Text($0 >= 1000 ? "\($0 / 1000) GB" : "\($0) MB").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Text("not used recently, oldest first.").foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            FileListView(model: model, ids: ids, showLocation: true,
                         initialSort: [KeyPathComparator(\.lastUsed, order: .forward)])
                .id(ids.count)
        }
        .task(id: QueryKey(focus: model.focus, version: model.treeVersion, filter: model.filter)) { await load() }
        .onChange(of: minimumMB) { Task { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let tree = model.tree else { return }
        let focus = model.focus
        var filter = model.filter
        let cutoff = filter.unusedSince
        filter.unusedSince = nil
        filter.minimumSize = max(filter.minimumSize, Int64(minimumMB) * 1_000_000)
        let candidates = await Task.detached { tree.largestFiles(under: focus, limit: 3000, filter: filter) }.value
        await model.loadLastUsed(for: candidates)
        var ranked = candidates.map { ($0, model.bestLastUsed($0)) }
        if let cutoff { ranked = ranked.filter { $0.1 <= cutoff } }
        ids = ranked.sorted { $0.1 < $1.1 }.prefix(1000).map(\.0)
    }
}

struct SuggestionsView: View {
    let model: AppModel
    let tree: FileTree
    @State private var expanded: Set<String> = []

    var body: some View {
        let suggestions = model.suggestions
        List {
            if suggestions.isLoading && suggestions.items.isEmpty {
                ProgressView("Looking for things to clean up…")
            } else if suggestions.items.isEmpty {
                ContentUnavailableView("Nothing to suggest", systemImage: "sparkles",
                                       description: Text("No caches, installers or old files worth cleaning up were found here."))
            }
            ForEach(suggestions.items) { suggestion in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(suggestion.id) },
                    set: { if $0 { expanded.insert(suggestion.id) } else { expanded.remove(suggestion.id) } }
                )) {
                    ForEach(suggestion.items.prefix(200), id: \.self) { id in
                        HStack {
                            Image(systemName: tree.category(id).symbol).foregroundStyle(Palette.color(tree.category(id)))
                            Text(tree.name(id)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.bytes(tree.size(id))).monospacedDigit().foregroundStyle(.secondary)
                            if suggestion.canTrash {
                                basketToggle(id)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.reveal(id) }
                        .contextMenu { ItemMenu(model: model, id: id) }
                    }
                    if suggestion.items.count > 200 {
                        Text("…and \(suggestion.items.count - 200) more").foregroundStyle(.secondary)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: suggestion.symbol).font(.title2).frame(width: 30).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(suggestion.title).font(.headline)
                                Text(Format.bytes(suggestion.bytes)).font(.headline).foregroundStyle(.secondary)
                            }
                            Text(suggestion.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if suggestion.canTrash {
                            Button("Add All") { model.addToBasket(suggestion.items) }
                                .help("Add every item in this group to the Trash list")
                        } else if suggestion.id == "trash" {
                            Button("Open Trash") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func basketToggle(_ id: NodeID) -> some View {
        let inBasket = model.basket.contains(id)
        return Button {
            if inBasket { model.removeFromBasket(id) } else { model.addToBasket([id]) }
        } label: {
            Image(systemName: inBasket ? "trash.fill" : "trash")
                .foregroundStyle(inBasket ? .red : .secondary)
        }
        .buttonStyle(.borderless)
        .help(inBasket ? "Remove from the Trash list" : "Add to the Trash list")
    }
}

struct DuplicatesView: View {
    let model: AppModel
    let tree: FileTree

    var body: some View {
        let duplicates = model.duplicates
        VStack(spacing: 0) {
            HStack {
                if duplicates.isRunning {
                    ProgressView(value: Double(duplicates.progress.filesChecked),
                                 total: Double(max(1, duplicates.progress.filesToCheck)))
                        .frame(maxWidth: 220)
                    Text("Comparing \(Format.count(duplicates.progress.filesChecked)) of \(Format.count(duplicates.progress.filesToCheck)) files…")
                        .foregroundStyle(.secondary)
                    Button("Stop") { duplicates.cancel() }
                } else {
                    Button(duplicates.groups.isEmpty ? "Find Duplicates in “\(model.displayName(model.focus))”" : "Search Again") {
                        duplicates.start(tree, under: model.focus)
                    }
                    .buttonStyle(.borderedProminent)
                    if case .done = duplicates.state {
                        Text(duplicates.groups.isEmpty ? "No duplicates over 1 MB found."
                             : "\(duplicates.groups.count == 1 ? "1 set" : "\(duplicates.groups.count) sets") of identical files; \(Format.bytes(duplicates.reclaimable)) could be freed.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Compares the contents of files over 1 MB.").foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(10)
            Divider()
            List {
                ForEach(duplicates.groups) { group in
                    Section {
                        ForEach(group.items, id: \.self) { id in
                            DuplicateRow(model: model, tree: tree, group: group, id: id)
                        }
                    } header: {
                        HStack {
                            Text("\(group.items.count) copies of \(Format.bytes(group.size))")
                            Spacer()
                            Button("Keep First, Add Others") {
                                model.addToBasket(Array(group.items.dropFirst()))
                            }
                            .buttonStyle(.borderless)
                            .help("Keeps the first copy listed and adds the rest to the Trash list")
                        }
                    }
                }
            }
        }
    }
}

private struct DuplicateRow: View {
    let model: AppModel
    let tree: FileTree
    let group: DuplicateGroup
    let id: NodeID

    var body: some View {
        let inBasket = model.basket.contains(id)
        HStack {
            Image(systemName: tree.category(id).symbol).foregroundStyle(Palette.color(tree.category(id)))
            VStack(alignment: .leading) {
                Text(tree.name(id))
                Text(tree.path(id)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if group.isClone(id) {
                Text("APFS clone")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("Shares its storage with another copy, so deleting it frees little or no space.")
            }
            SafetyBadge(level: tree.safety(id), compact: true)
            Button {
                if inBasket { model.removeFromBasket(id) } else { model.addToBasket([id]) }
            } label: {
                Image(systemName: inBasket ? "trash.fill" : "trash").foregroundStyle(inBasket ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canDelete(id))
            // Never let every copy go.
            .disabled(!inBasket && group.items.filter { $0 != id }.allSatisfy { model.basket.contains($0) })
        }
        .contentShape(Rectangle())
        .onTapGesture { model.reveal(id) }
        .contextMenu { ItemMenu(model: model, id: id) }
    }
}

import DiskLensKit
import SwiftUI

/// One table row, with its sort keys copied out of the tree.
struct FileRow: Identifiable {
    let id: NodeID
    let name: String
    let size: Int64
    let category: FileCategory
    let modified: Date
    var lastUsed: Date
    var lastUsedIsEstimate: Bool
    let safety: SafetyLevel
    let isContainer: Bool
    let location: String

    @MainActor
    init(_ id: NodeID, tree: FileTree, model: AppModel, showLocation: Bool) {
        self.id = id
        name = tree.name(id)
        size = tree.size(id)
        category = tree.category(id)
        modified = tree.modified(id)
        if let spotlight = model.lastUsed(id) {
            lastUsed = max(spotlight, modified)
            lastUsedIsEstimate = false
        } else {
            lastUsed = tree.lastUsedEstimate(id)
            lastUsedIsEstimate = true
        }
        safety = tree.safety(id)
        isContainer = tree.kind(id) == .directory
        location = showLocation ? tree.parent(id).map { Self.shortPath(tree.path($0)) } ?? "" : ""
    }

    var safetyRank: Int { Int(safety.rawValue) }
    var kindTitle: String { isContainer ? "Folder" : category.title }

    private static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// A sortable table of items, used by Browse, Largest Files and Least Used.
struct FileListView: View {
    let model: AppModel
    let ids: [NodeID]
    var showLocation = false
    var initialSort: [KeyPathComparator<FileRow>] = [KeyPathComparator(\.size, order: .reverse)]

    @State private var sortOrder: [KeyPathComparator<FileRow>] = []
    @State private var selection: Set<NodeID> = []

    var body: some View {
        if let tree = model.tree {
            let rows = sortedRows(tree)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.isContainer ? "folder.fill" : row.category.symbol)
                            .foregroundStyle(Palette.color(row.category))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.name).lineLimit(1).truncationMode(.middle)
                            if showLocation {
                                Text(row.location).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                        if model.basket.contains(row.id) {
                            Image(systemName: "trash").foregroundStyle(.red).help("In the Trash list")
                        }
                    }
                }
                .width(min: 180, ideal: 320)
                TableColumn("Size", value: \.size) { row in
                    SizeCell(size: row.size, total: tree.size(model.focus))
                }
                .width(min: 120, ideal: 150)
                TableColumn("Last Used", value: \.lastUsed) { row in
                    Text(Format.relative(row.lastUsed))
                        .foregroundStyle(row.lastUsedIsEstimate ? .secondary : .primary)
                        .help(row.lastUsedIsEstimate
                              ? "Spotlight has no record of this being opened; estimated from when it was last read or changed."
                              : "Last opened, according to Spotlight.")
                }
                .width(min: 90, ideal: 110)
                TableColumn("Modified", value: \.modified) { row in
                    Text(Format.date(row.modified))
                }
                .width(min: 80, ideal: 100)
                TableColumn("Kind", value: \.kindTitle) { row in
                    Text(row.kindTitle).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 110)
                TableColumn("Safety", value: \.safetyRank) { row in
                    SafetyBadge(level: row.safety, compact: true)
                }
                .width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: NodeID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    ItemMenu(model: model, id: id)
                } else if !ids.isEmpty {
                    Button("Add \(ids.count) Items to Trash List") { model.addToBasket(Array(ids)) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(ids.map { tree.url($0) })
                    }
                }
            } primaryAction: { ids in
                guard let id = ids.first else { return }
                if tree.kind(id).isContainer, !showLocation { model.zoom(into: id) } else { model.reveal(id) }
            }
            .onChange(of: selection) { _, newValue in
                if newValue.count == 1 { model.selection = newValue.first }
            }
            .onChange(of: model.selection) { _, newValue in
                if let newValue, !selection.contains(newValue), ids.contains(newValue) { selection = [newValue] }
            }
            .onAppear { if sortOrder.isEmpty { sortOrder = initialSort } }
            .task(id: ids) {
                await model.loadLastUsed(for: Array(ids.prefix(3000)))
            }
            .onKeyPress(.delete) {
                model.addToBasket(Array(selection))
                return .handled
            }
        }
    }

    private func sortedRows(_ tree: FileTree) -> [FileRow] {
        ids.map { FileRow($0, tree: tree, model: model, showLocation: showLocation) }.sorted(using: sortOrder)
    }
}

/// A size with a bar showing its share of the focused folder.
struct SizeCell: View {
    let size: Int64
    let total: Int64

    var body: some View {
        HStack(spacing: 6) {
            Text(Format.bytes(size)).monospacedDigit().frame(minWidth: 60, alignment: .trailing)
            GeometryReader { geometry in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor)
                            .frame(width: geometry.size.width * CGFloat(total > 0 ? min(1, Double(size) / Double(total)) : 0))
                    }
            }
            .frame(height: 5)
        }
    }
}

struct SafetyBadge: View {
    let level: SafetyLevel
    var compact = false

    var body: some View {
        Label(compact ? shortTitle : level.title, systemImage: Palette.symbol(level))
            .foregroundStyle(Palette.color(level))
            .font(compact ? .callout : .body)
            .labelStyle(.titleAndIcon)
    }

    private var shortTitle: String {
        switch level {
        case .safe: "Safe"
        case .user: "Yours"
        case .caution: "Caution"
        case .locked: "Protected"
        }
    }
}

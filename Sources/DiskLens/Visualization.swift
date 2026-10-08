import DiskLensKit
import SwiftUI

enum Palette {
    static func color(_ category: FileCategory) -> Color {
        switch category {
        case .video: Color(red: 0.55, green: 0.36, blue: 0.85)
        case .audio: Color(red: 0.87, green: 0.36, blue: 0.62)
        case .image: Color(red: 0.20, green: 0.66, blue: 0.56)
        case .document: Color(red: 0.25, green: 0.52, blue: 0.88)
        case .archive: Color(red: 0.93, green: 0.58, blue: 0.20)
        case .diskImage: Color(red: 0.62, green: 0.45, blue: 0.32)
        case .app: Color(red: 0.18, green: 0.72, blue: 0.85)
        case .code: Color(red: 0.50, green: 0.62, blue: 0.30)
        case .folder: Color(red: 0.50, green: 0.53, blue: 0.58)
        case .other: Color(red: 0.58, green: 0.60, blue: 0.66)
        }
    }

    static func color(_ level: SafetyLevel) -> Color {
        switch level {
        case .safe: Color(red: 0.24, green: 0.70, blue: 0.38)
        case .user: Color(red: 0.36, green: 0.55, blue: 0.85)
        case .caution: Color(red: 0.95, green: 0.62, blue: 0.18)
        case .locked: Color(red: 0.86, green: 0.30, blue: 0.30)
        }
    }

    static func symbol(_ level: SafetyLevel) -> String {
        switch level {
        case .safe: "checkmark.shield"
        case .user: "person.crop.circle"
        case .caution: "exclamationmark.triangle"
        case .locked: "lock.fill"
        }
    }

    @MainActor
    static func fill(_ id: NodeID, tree: FileTree, model: AppModel) -> Color {
        switch model.colors {
        case .type: color(tree.category(id))
        case .safety: color(tree.safety(id))
        }
    }

    static let containerFill = Color(white: 0.22)
    static let headerText = Color.white.opacity(0.9)
}

/// What to draw: the layout is recomputed when any of these change.
private struct LayoutKey: Equatable {
    var size: CGSize
    var focus: NodeID
    var treeVersion: Int
}

struct TreemapView: View {
    let model: AppModel
    let tree: FileTree
    @State private var cells: [TreemapCell] = []
    @State private var rects: [NodeID: CGRect] = [:]
    @State private var cellsKey: LayoutKey?

    var body: some View {
        GeometryReader { geometry in
            let key = LayoutKey(size: geometry.size, focus: model.focus, treeVersion: model.treeVersion)
            // Hover and selection draw in their own layer so moving the mouse doesn't
            // redraw tens of thousands of cells.
            Canvas { context, _ in draw(in: &context) }
            .overlay {
                Canvas { context, _ in drawHighlights(in: &context) }.allowsHitTesting(false)
            }
            .task(id: key) {
                // Read the tree from the model when the task runs: a captured copy can be
                // the one from before a trash or rescan.
                guard let tree = model.tree else { return }
                let focus = key.focus
                let bounds = CGRect(origin: .zero, size: key.size)
                // Let a window resize settle before relaying out.
                if cellsKey != nil { try? await Task.sleep(for: .milliseconds(40)) }
                guard !Task.isCancelled else { return }
                let (laidOut, byID) = await Task.detached(priority: .userInitiated) {
                    let cells = TreemapLayout.cells(tree: tree, root: focus, bounds: bounds)
                    return (cells, Dictionary(cells.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a }))
                }.value
                guard !Task.isCancelled else { return }
                cells = laidOut
                rects = byID
                cellsKey = key
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): model.hovered = TreemapLayout.hit(cells, at: point)?.id
                case .ended: model.hovered = nil
                }
            }
            .onTapGesture(count: 2) { point in
                if let cell = TreemapLayout.hit(cells, at: point) { model.zoom(into: openable(cell.id)) }
            }
            .onTapGesture { point in
                model.selection = TreemapLayout.hit(cells, at: point)?.id
            }
            .contextMenu {
                if let id = model.hovered { ItemMenu(model: model, id: id) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Treemap of \(model.displayName(model.focus))")
            .accessibilityChildren {
                // The focused folder's largest items, so the chart can be explored without a pointer.
                ForEach(tree.visibleChildren(model.focus).prefix(40), id: \.self) { id in
                    Text("\(tree.name(id)), \(Format.bytes(tree.size(id))), \(tree.safety(id).title)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.selection = id }
                        .accessibilityAction(named: "Zoom In") { model.zoom(into: id) }
                }
            }
        }
    }

    /// Double-clicking a file zooms into its folder.
    private func openable(_ id: NodeID) -> NodeID {
        tree.kind(id).isContainer ? id : (tree.parent(id) ?? id)
    }

    private func draw(in context: inout GraphicsContext) {
        guard cellsKey?.treeVersion == model.treeVersion else { return }
        let filter = model.filter
        let basket = Set(model.basket)
        for cell in cells {
            let rect = cell.rect
            if cell.isOpenContainer {
                context.fill(Path(rect), with: .color(Palette.containerFill.opacity(0.55 + 0.08 * Double(min(cell.depth, 5)))))
                if rect.height > 40 && rect.width > 60 {
                    let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: TreemapLayout.headerHeight)
                    let name = model.displayName(cell.id)
                    let label = "\(name)  \(Format.bytes(tree.size(cell.id)))"
                    context.draw(Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.headerText),
                                 in: header.insetBy(dx: 4, dy: 1))
                }
                continue
            }
            var color = Palette.fill(cell.id, tree: tree, model: model)
            if filter.isActive && !tree.matches(cell.id, filter) { color = Color(white: 0.35).opacity(0.5) }
            let inset = rect.width > 3 && rect.height > 3 ? rect.insetBy(dx: 0.5, dy: 0.5) : rect
            if inset.width > 14 && inset.height > 14 {
                context.fill(Path(inset), with: .linearGradient(
                    Gradient(colors: [color.mix(with: .white, by: 0.25), color, color.mix(with: .black, by: 0.25)]),
                    startPoint: inset.origin, endPoint: CGPoint(x: inset.maxX, y: inset.maxY)))
            } else {
                context.fill(Path(inset), with: .color(color))
            }
            if basket.contains(cell.id) {
                context.fill(Path(inset), with: .color(.red.opacity(0.45)))
            }
            if rect.width > 50 && rect.height > 16 {
                context.draw(Text(tree.name(cell.id)).font(.system(size: 10)).foregroundStyle(.white),
                             in: inset.insetBy(dx: 3, dy: 2))
            }
        }
    }

    private func drawHighlights(in context: inout GraphicsContext) {
        guard cellsKey?.treeVersion == model.treeVersion else { return }
        if let id = model.hovered, let hoveredRect = rects[id] {
            context.stroke(Path(hoveredRect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
        if let id = model.selection, let selectedRect = rects[id] {
            context.stroke(Path(selectedRect.insetBy(dx: 1, dy: 1)), with: .color(.black), lineWidth: 3)
            context.stroke(Path(selectedRect.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 1.5)
        }
    }
}

struct SunburstView: View {
    let model: AppModel
    let tree: FileTree
    @State private var cells: [SunburstCell] = []
    @State private var tints: [NodeID: FileCategory] = [:]
    @State private var cellsKey: LayoutKey?
    private let maxDepth = 5

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let ringWidth = side / 2 / CGFloat(maxDepth + 1)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let key = LayoutKey(size: .zero, focus: model.focus, treeVersion: model.treeVersion)
            ZStack {
                Canvas { context, _ in
                    draw(in: &context, center: center, ringWidth: ringWidth)
                }
                Canvas { context, _ in
                    drawHighlights(in: &context, center: center, ringWidth: ringWidth)
                }
                .allowsHitTesting(false)
                VStack(spacing: 2) {
                    Text(model.displayName(model.focus)).font(.headline).lineLimit(1)
                    Text(Format.bytes(tree.size(model.focus))).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(width: ringWidth * 1.7)
                .allowsHitTesting(false)
            }
            .task(id: key) {
                guard let tree = model.tree else { return }
                let focus = key.focus, depth = maxDepth
                let (laidOut, folderTints) = await Task.detached(priority: .userInitiated) {
                    let cells = SunburstLayout.cells(tree: tree, root: focus, maxDepth: depth)
                    var tints: [NodeID: FileCategory] = [:]
                    for cell in cells where tree.kind(cell.id) == .directory {
                        tints[cell.id] = Self.dominantCategory(cell.id, tree: tree)
                    }
                    return (cells, tints)
                }.value
                guard !Task.isCancelled else { return }
                cells = laidOut
                tints = folderTints
                cellsKey = key
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): model.hovered = hit(point, center: center, ringWidth: ringWidth)
                case .ended: model.hovered = nil
                }
            }
            .onTapGesture(count: 2) { point in
                guard let id = hit(point, center: center, ringWidth: ringWidth) else { return }
                if id == model.focus { model.zoomOut() } else { model.zoom(into: id) }
            }
            .onTapGesture { point in
                model.selection = hit(point, center: center, ringWidth: ringWidth)
            }
            .contextMenu {
                if let id = model.hovered { ItemMenu(model: model, id: id) }
            }
            .accessibilityElement()
            .accessibilityLabel("Sunburst chart of \(model.displayName(model.focus))")
        }
    }

    private func hit(_ point: CGPoint, center: CGPoint, ringWidth: CGFloat) -> NodeID? {
        SunburstLayout.hit(cells, at: CGPoint(x: point.x - center.x, y: point.y - center.y), ringWidth: ringWidth)?.id
    }

    private func draw(in context: inout GraphicsContext, center: CGPoint, ringWidth: CGFloat) {
        guard cellsKey?.treeVersion == model.treeVersion else { return }
        let filter = model.filter
        let basket = Set(model.basket)
        context.fill(Path(ellipseIn: CGRect(x: center.x - ringWidth, y: center.y - ringWidth,
                                            width: ringWidth * 2, height: ringWidth * 2)),
                     with: .color(Color.secondary.opacity(0.12)))
        for cell in cells where cell.depth > 0 {
            let path = arc(cell, center: center, ringWidth: ringWidth)

            var color = Palette.fill(cell.id, tree: tree, model: model)
            if model.colors == .type, tree.kind(cell.id) == .directory {
                // Folders take a tint of what they mostly hold: their largest child's color.
                color = Palette.color(.folder).mix(with: Palette.color(tints[cell.id] ?? .folder), by: 0.45)
            }
            if filter.isActive && !tree.kind(cell.id).isContainer && !tree.matches(cell.id, filter) {
                color = Color(white: 0.35).opacity(0.5)
            }
            context.fill(path, with: .color(color))
            if basket.contains(cell.id) { context.fill(path, with: .color(.red.opacity(0.45))) }
            context.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
        }
    }

    private func drawHighlights(in context: inout GraphicsContext, center: CGPoint, ringWidth: CGFloat) {
        guard cellsKey?.treeVersion == model.treeVersion else { return }
        for cell in cells where cell.depth > 0 && (cell.id == model.hovered || cell.id == model.selection) {
            let path = arc(cell, center: center, ringWidth: ringWidth)
            if cell.id == model.selection {
                context.stroke(path, with: .color(.black), lineWidth: 3.5)
                context.stroke(path, with: .color(.white), lineWidth: 2)
            } else {
                context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            }
        }
    }

    private func arc(_ cell: SunburstCell, center: CGPoint, ringWidth: CGFloat) -> Path {
        let inner = ringWidth * CGFloat(cell.depth)
        let outer = inner + ringWidth - 1
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(cell.startAngle - .pi / 2),
                    endAngle: .radians(cell.endAngle - .pi / 2), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(cell.endAngle - .pi / 2),
                    endAngle: .radians(cell.startAngle - .pi / 2), clockwise: true)
        path.closeSubpath()
        return path
    }

    /// What a folder mostly holds: the type of the file at the end of its largest-child chain.
    nonisolated private static func dominantCategory(_ id: NodeID, tree: FileTree) -> FileCategory {
        var node = id
        for _ in 0..<6 {
            guard tree.kind(node) == .directory, let largest = tree.visibleChildren(node).first else { break }
            node = largest
        }
        return tree.category(node)
    }
}

/// The shared right-click menu for an item.
struct ItemMenu: View {
    let model: AppModel
    let id: NodeID

    var body: some View {
        if let tree = model.tree {
            Text(tree.name(id))
            if tree.kind(id).isContainer {
                Button("Zoom In") { model.zoom(into: id) }
            }
            Button("Show in Finder") { model.revealInFinder(id) }
            Button("Open") { model.open(id) }
            Divider()
            if model.basket.contains(id) {
                Button("Remove from Trash List") { model.removeFromBasket(id) }
            } else {
                Button("Add to Trash List") { model.addToBasket([id]) }
                    .disabled(!model.canDelete(id))
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tree.path(id), forType: .string)
            }
        }
    }
}

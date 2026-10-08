import CoreGraphics
import Foundation

public struct TreemapCell: Sendable {
    public let id: NodeID
    public let rect: CGRect
    public let depth: Int
    /// A folder drawn with its contents inside it (otherwise drawn as a solid block).
    public let isOpenContainer: Bool
}

/// Squarified treemap (Bruls, Huizing & van Wijk): each item is a rectangle whose
/// area is proportional to its size on disk, kept as close to square as possible.
public enum TreemapLayout {
    public static let headerHeight: CGFloat = 15

    public static func cells(tree: FileTree, root: NodeID, bounds: CGRect,
                             maxCells: Int = 60_000) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        cells.reserveCapacity(min(maxCells, 4096))
        layout(tree, root, bounds, depth: 0, into: &cells, maxCells: maxCells)
        return cells
    }

    private static func layout(_ tree: FileTree, _ id: NodeID, _ rect: CGRect, depth: Int,
                               into cells: inout [TreemapCell], maxCells: Int) {
        let canOpen = tree.kind(id).isContainer && rect.width > 8 && rect.height > 8 && cells.count < maxCells
        let index = cells.count
        cells.append(TreemapCell(id: id, rect: rect, depth: depth, isOpenContainer: false))
        guard canOpen else { return }

        let showsHeader = rect.height > 40 && rect.width > 60
        let inner = CGRect(x: rect.minX + 1, y: rect.minY + (showsHeader ? headerHeight : 1),
                           width: rect.width - 2, height: rect.height - (showsHeader ? headerHeight + 1 : 2))
        guard inner.width > 2, inner.height > 2 else { return }
        let children = tree.visibleChildren(id).filter { tree.size($0) > 0 }
        guard !children.isEmpty else { return }
        cells[index] = TreemapCell(id: id, rect: rect, depth: depth, isOpenContainer: true)

        let total = Double(tree.size(id))
        let scale = Double(inner.width * inner.height) / max(total, 1)
        var areas: [Double] = []
        for child in children {
            let area = Double(tree.size(child)) * scale
            // Sorted largest first, so everything after this is too small to see.
            if area < 3 { break }
            areas.append(area)
        }
        let rects = squarify(areas, in: inner)
        for (child, childRect) in zip(children, rects) {
            guard cells.count < maxCells else { return }
            layout(tree, child, childRect, depth: depth + 1, into: &cells, maxCells: maxCells)
        }
    }

    /// Lays out `areas` (sorted descending, in square points) inside `rect`.
    public static func squarify(_ areas: [Double], in rect: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var remaining = rect
        var start = 0
        while start < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else { break }
            var end = start + 1
            var rowSum = areas[start]
            var best = worstRatio(areas[start...start], sum: rowSum, side: side)
            while end < areas.count {
                let candidateSum = rowSum + areas[end]
                let candidate = worstRatio(areas[start...end], sum: candidateSum, side: side)
                if candidate > best { break }
                best = candidate
                rowSum = candidateSum
                end += 1
            }
            // Lay the row along the short side.
            let thickness = CGFloat(rowSum / side)
            var offset: CGFloat = 0
            if remaining.width >= remaining.height {
                for i in start..<end {
                    let length = CGFloat(areas[i]) / thickness
                    result.append(CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length))
                    offset += length
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                for i in start..<end {
                    let length = CGFloat(areas[i]) / thickness
                    result.append(CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness))
                    offset += length
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            start = end
        }
        return result
    }

    private static func worstRatio(_ row: ArraySlice<Double>, sum: Double, side: Double) -> Double {
        guard let largest = row.first, let smallest = row.last, smallest > 0 else { return .infinity }
        let side2 = side * side, sum2 = sum * sum
        return max(side2 * largest / sum2, sum2 / (side2 * smallest))
    }

    /// The deepest cell under `point`.
    public static func hit(_ cells: [TreemapCell], at point: CGPoint) -> TreemapCell? {
        cells.last { $0.rect.contains(point) }
    }
}

public struct SunburstCell: Sendable {
    public let id: NodeID
    /// 0 is the center disc (the focused folder).
    public let depth: Int
    public let startAngle: Double
    public let endAngle: Double
}

/// Rings of folders around the focused one; each item's angle is proportional to its size.
public enum SunburstLayout {
    public static func cells(tree: FileTree, root: NodeID, maxDepth: Int = 5,
                             minAngle: Double = 0.006) -> [SunburstCell] {
        var cells = [SunburstCell(id: root, depth: 0, startAngle: 0, endAngle: 2 * .pi)]
        var frontier: [(NodeID, Double, Double)] = [(root, 0, 2 * .pi)]
        for depth in 1...maxDepth {
            var next: [(NodeID, Double, Double)] = []
            for (parent, start, end) in frontier where tree.kind(parent).isContainer {
                let total = Double(tree.size(parent))
                guard total > 0 else { continue }
                var angle = start
                for child in tree.visibleChildren(parent) {
                    let span = (end - start) * Double(tree.size(child)) / total
                    if span < minAngle { break }
                    cells.append(SunburstCell(id: child, depth: depth, startAngle: angle, endAngle: angle + span))
                    next.append((child, angle, angle + span))
                    angle += span
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return cells
    }

    /// The cell at `point`, relative to the chart's center, for a given ring thickness.
    public static func hit(_ cells: [SunburstCell], at point: CGPoint, ringWidth: CGFloat) -> SunburstCell? {
        let radius = hypot(point.x, point.y)
        let depth = Int(radius / ringWidth)
        guard depth >= 0 else { return nil }
        if depth == 0 { return cells.first }
        var angle = atan2(Double(point.y), Double(point.x)) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return cells.first { $0.depth == depth && angle >= $0.startAngle && angle < $0.endAngle }
    }
}

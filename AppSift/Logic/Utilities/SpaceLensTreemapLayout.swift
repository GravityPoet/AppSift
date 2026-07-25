import CoreGraphics
import Foundation

struct SpaceLensTreemapEntry: Equatable, Sendable {
    let id: String
    let weight: Double
}

struct SpaceLensTreemapTile: Equatable, Sendable {
    let id: String
    let rect: CGRect
}

enum SpaceLensTreemapLayout {
    static func tiles(
        for entries: [SpaceLensTreemapEntry],
        in bounds: CGRect
    ) -> [SpaceLensTreemapTile] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let sorted = entries
            .filter { $0.weight.isFinite && $0.weight > 0 }
            .sorted {
                if $0.weight != $1.weight {
                    return $0.weight > $1.weight
                }
                return $0.id < $1.id
            }
        let totalWeight = sorted.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return [] }

        let totalArea = Double(bounds.width * bounds.height)
        var remaining = sorted.map {
            AreaEntry(
                id: $0.id,
                area: $0.weight / totalWeight * totalArea
            )
        }
        var remainingBounds = bounds
        var row: [AreaEntry] = []
        var output: [SpaceLensTreemapTile] = []

        while let next = remaining.first {
            let side = Double(min(
                remainingBounds.width,
                remainingBounds.height
            ))
            guard side > 0 else { break }

            if row.isEmpty
                || worstAspectRatio(of: row + [next], along: side)
                    <= worstAspectRatio(of: row, along: side) {
                row.append(next)
                remaining.removeFirst()
            } else {
                remainingBounds = layout(
                    row,
                    in: remainingBounds,
                    output: &output
                )
                row.removeAll(keepingCapacity: true)
            }
        }

        if !row.isEmpty {
            _ = layout(row, in: remainingBounds, output: &output)
        }
        return output
    }

    private struct AreaEntry {
        let id: String
        let area: Double
    }

    private static func worstAspectRatio(
        of row: [AreaEntry],
        along side: Double
    ) -> Double {
        guard !row.isEmpty, side > 0 else {
            return .infinity
        }
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0,
              let smallest = row.map(\.area).min(),
              let largest = row.map(\.area).max(),
              smallest > 0 else {
            return .infinity
        }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(
            sideSquared * largest / sumSquared,
            sumSquared / (sideSquared * smallest)
        )
    }

    private static func layout(
        _ row: [AreaEntry],
        in bounds: CGRect,
        output: inout [SpaceLensTreemapTile]
    ) -> CGRect {
        let rowArea = CGFloat(row.reduce(0) { $0 + $1.area })
        guard rowArea > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        if bounds.width >= bounds.height {
            let columnWidth = min(bounds.width, rowArea / bounds.height)
            var y = bounds.minY
            for (index, entry) in row.enumerated() {
                let height = index == row.count - 1
                    ? max(0, bounds.maxY - y)
                    : min(
                        max(0, bounds.maxY - y),
                        CGFloat(entry.area) / max(columnWidth, 0.000_001)
                    )
                output.append(SpaceLensTreemapTile(
                    id: entry.id,
                    rect: CGRect(
                        x: bounds.minX,
                        y: y,
                        width: columnWidth,
                        height: height
                    )
                ))
                y += height
            }
            return CGRect(
                x: bounds.minX + columnWidth,
                y: bounds.minY,
                width: max(0, bounds.width - columnWidth),
                height: bounds.height
            )
        }

        let rowHeight = min(bounds.height, rowArea / bounds.width)
        var x = bounds.minX
        for (index, entry) in row.enumerated() {
            let width = index == row.count - 1
                ? max(0, bounds.maxX - x)
                : min(
                    max(0, bounds.maxX - x),
                    CGFloat(entry.area) / max(rowHeight, 0.000_001)
                )
            output.append(SpaceLensTreemapTile(
                id: entry.id,
                rect: CGRect(
                    x: x,
                    y: bounds.minY,
                    width: width,
                    height: rowHeight
                )
            ))
            x += width
        }
        return CGRect(
            x: bounds.minX,
            y: bounds.minY + rowHeight,
            width: bounds.width,
            height: max(0, bounds.height - rowHeight)
        )
    }
}

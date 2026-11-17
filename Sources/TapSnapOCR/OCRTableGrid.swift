import CoreGraphics
import Foundation

/// Row and column boundaries of a visibly ruled table, in top-left image coordinates.
public struct OCRTableGrid {
    public let rows: [Int]
    public let columns: [Int]

    public var rowCount: Int { rows.count - 1 }
    public var columnCount: Int { columns.count - 1 }

    public func rowIndex(for y: CGFloat) -> Int? { Self.index(of: y, in: rows) }
    public func columnIndex(for x: CGFloat) -> Int? { Self.index(of: x, in: columns) }

    public static func detect(in image: CGImage, minimumLineRatio: CGFloat = 0.4) -> OCRTableGrid? {
        guard image.width > 32, image.height > 32, let raster = TableRaster(image) else { return nil }
        let horizontal = raster.strokes(horizontal: true, minimumLineRatio: minimumLineRatio)
        let vertical = raster.strokes(horizontal: false, minimumLineRatio: minimumLineRatio)
        return crossingGrid(horizontal: horizontal, vertical: vertical)
    }

    public func table(in document: OCRDocument) -> OCRTableRegion? {
        let size = document.sourceSize
        guard size.width > 0, size.height > 0, let firstRow = rows.first, let lastRow = rows.last,
              let firstColumn = columns.first, let lastColumn = columns.last else { return nil }
        let bounds = CGRect(x: CGFloat(firstColumn), y: CGFloat(firstRow),
                            width: CGFloat(lastColumn - firstColumn), height: CGFloat(lastRow - firstRow))
        var cells = Array(repeating: Array(repeating: [OCRTextLine](), count: columnCount), count: rowCount)
        var ids = Set<UUID>()
        for line in document.originalLines {
            let normalized = line.normalizedBounds
            let box = CGRect(x: normalized.minX * size.width, y: (1 - normalized.maxY) * size.height,
                             width: normalized.width * size.width, height: normalized.height * size.height)
            guard !box.isEmpty, bounds.contains(CGPoint(x: box.midX, y: box.midY)),
                  let row = Self.bestOverlap(from: box.minY, to: box.maxY, in: rows),
                  let column = Self.bestOverlap(from: box.minX, to: box.maxX, in: columns) else { continue }
            cells[row][column].append(line)
            ids.insert(line.id)
        }
        guard !ids.isEmpty else { return nil }
        let values = cells.map { row in
            row.map { OCRTextBlock(lines: $0, normalizedBounds: .zero).paragraphText }
        }
        let normalizedBounds = CGRect(x: bounds.minX / size.width, y: 1 - bounds.maxY / size.height,
                                      width: bounds.width / size.width, height: bounds.height / size.height)
        return OCRTableRegion(rows: values, lineIDs: ids, normalizedBounds: normalizedBounds)
    }

    private static func index(of position: CGFloat, in lines: [Int]) -> Int? {
        lines.indices.dropLast().first {
            CGFloat(lines[$0]) <= position && position < CGFloat(lines[$0 + 1])
        }
    }

    private static func bestOverlap(from start: CGFloat, to end: CGFloat, in lines: [Int]) -> Int? {
        var longest: CGFloat = 0
        var result: Int?
        for index in lines.indices.dropLast() {
            let overlap = min(end, CGFloat(lines[index + 1])) - max(start, CGFloat(lines[index]))
            if overlap > longest {
                longest = overlap
                result = index
            }
        }
        return result
    }

    private static func crossingGrid(horizontal: [Stroke], vertical: [Stroke]) -> OCRTableGrid? {
        guard horizontal.count >= 2, vertical.count >= 2 else { return nil }
        var rowNeighbors = Array(repeating: [Int](), count: horizontal.count)
        var columnNeighbors = Array(repeating: [Int](), count: vertical.count)
        for (row, h) in horizontal.enumerated() {
            for (column, v) in vertical.enumerated() where h.covers(v.position) && v.covers(h.position) {
                rowNeighbors[row].append(column)
                columnNeighbors[column].append(row)
            }
        }

        // Find independent components of crossing lines before choosing the best supported grid.
        var seenRows = Set<Int>()
        var seenColumns = Set<Int>()
        var best: (grid: OCRTableGrid, intersections: Int)?
        for start in horizontal.indices where rowNeighbors[start].count >= 2 && !seenRows.contains(start) {
            var componentRows = [start]
            var componentColumns: [Int] = []
            seenRows.insert(start)
            var cursor = 0
            while cursor < componentRows.count {
                let row = componentRows[cursor]
                cursor += 1
                for column in rowNeighbors[row] where columnNeighbors[column].count >= 2 {
                    guard seenColumns.insert(column).inserted else { continue }
                    componentColumns.append(column)
                    for next in columnNeighbors[column] where rowNeighbors[next].count >= 2 {
                        if seenRows.insert(next).inserted { componentRows.append(next) }
                    }
                }
            }
            let rowLines = Array(Set(componentRows.map { horizontal[$0].position })).sorted()
            let columnLines = Array(Set(componentColumns.map { vertical[$0].position })).sorted()
            guard rowLines.count >= 2, columnLines.count >= 2, rowLines.count + columnLines.count >= 5 else { continue }
            let validColumns = Set(componentColumns)
            let crossings = componentRows.reduce(0) { count, row in
                count + rowNeighbors[row].count(where: validColumns.contains)
            }
            let possible = rowLines.count * columnLines.count
            guard crossings * 4 >= possible * 3, crossings > (best?.intersections ?? 0) else { continue }
            best = (OCRTableGrid(rows: rowLines, columns: columnLines), crossings)
        }
        return best?.grid
    }
}

private struct Stroke {
    var position: Int
    var start: Int
    var end: Int

    func covers(_ value: Int) -> Bool { start - 3 <= value && value <= end + 3 }
}

private struct TableRaster {
    let width: Int
    let height: Int
    let gray: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drew else { return nil }
        gray = pixels
    }

    func strokes(horizontal: Bool, minimumLineRatio: CGFloat) -> [Stroke] {
        let positions = horizontal ? height : width
        let length = horizontal ? width : height
        // A line does not need to span the full screenshot when the table occupies a smaller area.
        let required = min(72, max(24, Int(CGFloat(length) * minimumLineRatio)))
        let across = horizontal ? width : 1
        let along = horizontal ? 1 : width
        var result: [Stroke] = []

        for position in 0..<positions {
            let previous = position >= 3 ? position - 3 : position + 3
            let next = position + 3 < positions ? position + 3 : position - 3
            let origin = position * across
            let before = previous * across
            let after = next * across
            var start = 0
            var end = -4

            func appendStroke() {
                guard end - start + 1 >= required else { return }
                // Merge adjacent scans through a single thick rule, keeping distinct spans at the same position.
                let duplicate = result.indices.reversed().prefix { position - result[$0].position <= 3 }.first {
                    min(end, result[$0].end) - max(start, result[$0].start) >= required / 2
                }
                if let duplicate {
                    result[duplicate].start = min(start, result[duplicate].start)
                    result[duplicate].end = max(end, result[duplicate].end)
                } else {
                    result.append(Stroke(position: position, start: start, end: end))
                }
            }

            for distance in 0..<length {
                let offset = distance * along
                let value = Int(gray[origin + offset])
                let first = value - Int(gray[before + offset])
                let second = value - Int(gray[after + offset])
                // Compare across the rule instead of binarizing the whole crop. Faint rules and either polarity survive.
                let isRule = (first <= -8 && second <= -8) || (first >= 8 && second >= 8)
                guard isRule else { continue }
                if distance - end > 3 {
                    appendStroke()
                    start = distance
                }
                end = distance
            }
            appendStroke()
        }
        return result
    }
}

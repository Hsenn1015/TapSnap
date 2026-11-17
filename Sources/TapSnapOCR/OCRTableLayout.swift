import CoreGraphics
import Foundation

public struct OCRTableRegion: Sendable {
    public let rows: [[String]]
    public let lineIDs: Set<UUID>
    /// Vision coordinates, normalized to the original image with origin at its bottom left.
    public let normalizedBounds: CGRect
    let hasTextSpanningColumns: Bool

    public init(rows: [[String]], lineIDs: Set<UUID>, normalizedBounds: CGRect, hasTextSpanningColumns: Bool = false) {
        self.rows = rows
        self.lineIDs = lineIDs
        self.normalizedBounds = normalizedBounds
        self.hasTextSpanningColumns = hasTextSpanningColumns
    }
}

/// Reconstructs borderless tables where OCR emitted each cell as a separate observation.
public enum OCRTableLayout {
    private struct Cell {
        let line: OCRTextLine
        let rect: CGRect

        var isCompact: Bool {
            rect.width <= rect.height * 10 && line.text.count <= 42
                && line.text.split(whereSeparator: \.isWhitespace).count <= 6
        }

        var isNumeric: Bool {
            line.text.contains(where: \.isNumber) && line.text.allSatisfy {
                $0.isNumber || $0.isWhitespace || ".,:/-−–+%‰$¥￥€£()年月日".contains($0)
            }
        }
    }

    private struct Row {
        var cells: [Cell]
        var midY: CGFloat { cells[0].rect.midY }
    }

    private struct Match {
        let index: Int
        let cells: [Cell?]
        var populated: Int { cells.compactMap { $0 }.count }
    }

    public static func tables(in document: OCRDocument) -> [OCRTableRegion] {
        guard document.sourceSize.width > 0, document.sourceSize.height > 0 else { return [] }
        let scale = CGAffineTransform(scaleX: document.sourceSize.width, y: document.sourceSize.height)
        let cells = document.originalLines.compactMap { line -> Cell? in
            let rect = line.normalizedBounds.applying(scale)
            guard !rect.isEmpty, rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
                  !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Cell(line: line, rect: rect)
        }
        let rows = physicalRows(cells)
        var tables: [OCRTableRegion] = []
        var index = 0
        while index + 2 < rows.count {
            let matches = table(at: index, in: rows)
            guard let last = matches.last else {
                index += 1
                continue
            }
            let lines = matches.flatMap { $0.cells.compactMap { $0?.line } }
            tables.append(OCRTableRegion(
                rows: matches.map { $0.cells.map { $0?.line.text ?? "" } },
                lineIDs: Set(lines.map(\.id)),
                normalizedBounds: lines.reduce(.null) { $0.union($1.normalizedBounds) }
            ))
            index = last.index + 1
        }
        return tables
    }

    private static func physicalRows(_ cells: [Cell]) -> [Row] {
        let sorted = cells.sorted {
            if $0.rect.midY != $1.rect.midY { return $0.rect.midY > $1.rect.midY }
            return $0.rect.minX < $1.rect.minX
        }
        var rows: [Row] = []
        for cell in sorted {
            if let anchor = rows.last?.cells.first,
               abs(anchor.rect.midY - cell.rect.midY) <= min(anchor.rect.height, cell.rect.height) * 0.45 {
                rows[rows.count - 1].cells.append(cell)
            } else {
                rows.append(Row(cells: [cell]))
            }
        }
        return rows.map { Row(cells: $0.cells.sorted { $0.rect.minX < $1.rect.minX }) }
    }

    private static func table(at start: Int, in rows: [Row]) -> [Match] {
        guard rows[start].cells.count >= 2 else { return [] }
        let nearby = rows[start..<min(start + 5, rows.count)]
        let heights = nearby.flatMap { $0.cells.map(\.rect.height) }.sorted()
        let height = heights[heights.count / 2]
        // A seed supplies observed column edges, not positions guessed from an assumed uniform column width.
        let seeds = nearby.prefix(3).map(\.cells).sorted { $0.count > $1.count }
        for seed in seeds where seed.count >= 2 {
            let columns = seed.map(\.rect)
            guard zip(columns, columns.dropFirst()).allSatisfy({
                $1.minX - $0.maxX >= height * 0.55
            }) else { continue }

            let initial = matches(in: rows, range: nearby.indices, columns: columns, height: height)
            guard isTable(initial, columnCount: columns.count) else { continue }
            let steps = zip(initial, initial.dropFirst()).map { rows[$0.index].midY - rows[$1.index].midY }.sorted()
            let pitch = steps[steps.count / 2]
            let result = matches(in: rows, range: start..<rows.count, columns: columns, height: height, pitch: pitch)
            if isTable(Array(result.prefix(5)), columnCount: columns.count) { return result }
        }
        return []
    }

    private static func matches(in rows: [Row], range: Range<Int>, columns: [CGRect], height: CGFloat,
                                pitch: CGFloat? = nil) -> [Match] {
        var result: [Match] = []
        for index in range {
            if index > range.lowerBound {
                let gap = rows[index - 1].midY - rows[index].midY
                let minimum = max(height * 0.65, (pitch ?? 0) * 0.58)
                let maximum = min(height * 4.25, (pitch ?? .infinity) * 1.5)
                guard gap >= minimum, gap <= maximum else { break }
            }
            guard let cells = alignedCells(rows[index], columns: columns, height: height) else { break }
            let match = Match(index: index, cells: cells)
            if match.populated == 1, result.last?.populated == 1 { break }
            result.append(match)
        }
        // A sparse observation between full rows can represent an empty cell. A trailing isolated
        // observation can instead be a caption or paragraph.
        if result.last?.populated == 1 { result.removeLast() }
        return result
    }

    private static func alignedCells(_ row: Row, columns: [CGRect], height: CGFloat) -> [Cell?]? {
        guard row.cells.count <= columns.count else { return nil }
        let tolerance = height * 0.65
        var result = [Cell?](repeating: nil, count: columns.count)
        var next = 0
        for cell in row.cells {
            var column: Int?
            var bestDistance = tolerance
            for index in next..<columns.count {
                let previousEdge = index > 0 ? columns[index - 1].maxX : -.infinity
                let nextEdge = index + 1 < columns.count ? columns[index + 1].minX : .infinity
                guard cell.rect.minX >= previousEdge - tolerance, cell.rect.maxX <= nextEdge + tolerance else {
                    continue
                }
                let anchor = columns[index]
                let distance = min(abs(cell.rect.minX - anchor.minX), abs(cell.rect.maxX - anchor.maxX),
                                   abs(cell.rect.midX - anchor.midX))
                if distance <= bestDistance {
                    column = index
                    bestDistance = distance
                }
            }
            guard let column else { return nil }
            result[column] = cell
            next = column + 1
        }
        return result
    }

    private static func isTable(_ matches: [Match], columnCount: Int) -> Bool {
        guard matches.count >= 3, matches.filter({ $0.populated == columnCount }).count >= 2 else { return false }
        let cells = matches.flatMap { $0.cells.compactMap { $0 } }
        guard cells.filter(\.isCompact).count * 3 >= cells.count * 2 else { return false }
        if columnCount >= 3 { return true }

        // Two aligned streams can be book columns or name/value labels. Require a header signal.
        let heading = matches[0].cells.compactMap { $0 }
        guard heading.count == 2, heading.allSatisfy({ !$0.isNumeric }) else { return false }
        let body = matches.dropFirst()
        if (0..<columnCount).contains(where: { column in
            body.filter { $0.cells[column]?.isNumeric == true }.count >= 2
        }) { return true }
        let heights = body.flatMap { $0.cells.compactMap { $0?.rect.height } }.sorted()
        return heading.allSatisfy { $0.rect.height >= heights[heights.count / 2] * 1.2 }
    }
}

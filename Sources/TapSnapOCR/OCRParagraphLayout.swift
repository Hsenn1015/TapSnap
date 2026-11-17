import CoreGraphics
import Foundation

/// Groups physical OCR lines for reading. The original line observations stay available for export.
enum OCRParagraphLayout {
    private struct Line {
        let observation: OCRTextLine
        let rect: CGRect
        let index: Int

        var text: String { observation.text }
        var isStructured: Bool {
            text.range(of: #"^(?:[\s\t]{2,}|(?:[$%#>]\s)|(?:\d{1,2}:\d{2}(?::\d{2})?$)|(?:[{}\[\]]$)|(?:[A-Za-z_]\w*\s*=(?!=))|(?:(?:let|var|func|import|class|return|const|def)\s+\S+.*[()=;{}]))"#,
                       options: .regularExpression) != nil
                || text.contains("\t") || text.contains(" | ")
        }
        var isListStart: Bool {
            text.range(of: #"^\s*(?:[•●▪‣◦·]|[-*+]\s+|(?:\d+|[A-Za-z])[.)](?=\s|$|\p{Han})|[\d一二三四五六七八九十]+、|[（(]\d+[）)])"#,
                       options: .regularExpression) != nil
        }
        var endsSentence: Bool {
            guard let last = text.trimmingCharacters(in: CharacterSet(charactersIn: "”’\"'）)】」』")).last else { return false }
            return "。！？.!?".contains(last)
        }
    }

    static func layout(_ observations: [OCRTextLine], sourceSize: CGSize, groupParagraphs: Bool = true)
        -> (originalLines: [OCRTextLine], blocks: [OCRTextBlock]) {
        let physicalRows = rows(makeLines(observations, sourceSize: sourceSize))
        let physicalLines = physicalRows.flatMap { $0 }
        let paragraphs = groupParagraphs ? read(physicalRows) : physicalLines.map { [$0] }
        let blocks = paragraphs.map { paragraph in
            let observations = paragraph.map(\.observation)
            let bounds = observations.reduce(CGRect.null) { $0.union($1.normalizedBounds) }
            return OCRTextBlock(lines: observations, normalizedBounds: bounds)
        }
        return (physicalLines.map(\.observation), blocks)
    }

    private static func makeLines(_ observations: [OCRTextLine], sourceSize: CGSize) -> [Line] {
        let scale = CGAffineTransform(scaleX: max(1, sourceSize.width), y: max(1, sourceSize.height))
        return observations.enumerated().map {
            Line(observation: $0.element, rect: $0.element.normalizedBounds.applying(scale), index: $0.offset)
        }
    }

    private static func rows(_ lines: [Line]) -> [[Line]] {
        let sorted = lines.sorted {
            if $0.rect.midY != $1.rect.midY { return $0.rect.midY > $1.rect.midY }
            return $0.index < $1.index
        }
        var result: [[Line]] = []
        for line in sorted {
            if let anchor = result.last?.first,
               abs(anchor.rect.midY - line.rect.midY) <= min(anchor.rect.height, line.rect.height) * 0.45 {
                result[result.count - 1].append(line)
            } else {
                result.append([line])
            }
        }
        return result.map { row in
            row.sorted {
                if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
                return $0.index < $1.index
            }
        }
    }

    private static func read(_ rows: [[Line]], depth: Int = 0) -> [[Line]] {
        guard !rows.isEmpty else { return [] }
        if depth < 3, let gutter = columnGutter(in: rows) {
            // Full-width text and columns form separate reading bands.
            var band: [[Line]] = []
            var spansGutter = false
            var output: [[Line]] = []
            func flush() {
                guard !band.isEmpty else { return }
                if !spansGutter, let columns = split(band, at: gutter) {
                    output += read(columns.left, depth: depth + 1)
                    output += read(columns.right, depth: depth + 1)
                } else {
                    output += singleFlow(band)
                }
                band.removeAll(keepingCapacity: true)
            }
            for row in rows {
                let crossesGutter = row.contains { $0.rect.minX < gutter && $0.rect.maxX > gutter }
                if crossesGutter != spansGutter {
                    flush()
                    spansGutter = crossesGutter
                }
                band.append(row)
            }
            flush()
            return output
        }
        return singleFlow(rows)
    }

    private static func columnGutter(in rows: [[Line]]) -> CGFloat? {
        guard rows.count >= 2 else { return nil }
        let height = median(rows.flatMap { $0.map { $0.rect.height } }) ?? 1
        var gapEdges: [CGFloat: Int] = [:]
        for (index, row) in rows.enumerated() {
            // Adjacent rows also contribute, so columns with staggered baselines can be found.
            let neighbors = index + 1 < rows.count ? row + rows[index + 1] : row
            let sorted = neighbors.sorted { $0.rect.minX < $1.rect.minX }
            var edge = sorted.first?.rect.maxX ?? 0
            for line in sorted.dropFirst() {
                let gap = line.rect.minX - edge
                if gap >= 1.6 * height {
                    gapEdges[edge + height * 0.3, default: 0] += 1
                    gapEdges[line.rect.minX - height * 0.3, default: 0] -= 1
                }
                edge = max(edge, line.rect.maxX)
            }
        }

        // Count shared empty space, even when line lengths give the gaps different midpoints.
        let edges = gapEdges.keys.sorted()
        var votes = 0
        var candidates: [(gutter: CGFloat, votes: Int, width: CGFloat)] = []
        for (left, right) in zip(edges, edges.dropFirst()) {
            votes += gapEdges[left, default: 0]
            if votes >= 2 {
                candidates.append(((left + right) / 2, votes, right - left))
            }
        }
        candidates.sort {
            if $0.votes != $1.votes { return $0.votes > $1.votes }
            return $0.width > $1.width
        }
        for (gutter, _, _) in candidates.prefix(10) {
            var band: [[Line]] = []
            for row in rows {
                if row.contains(where: { $0.rect.minX < gutter && $0.rect.maxX > gutter }) {
                    if split(band, at: gutter) != nil { return gutter }
                    band.removeAll(keepingCapacity: true)
                } else {
                    band.append(row)
                }
            }
            if split(band, at: gutter) != nil { return gutter }
        }
        return nil
    }

    private static func split(_ rows: [[Line]], at gutter: CGFloat) -> (left: [[Line]], right: [[Line]])? {
        let left = rows.map { $0.filter { $0.rect.maxX <= gutter } }.filter { !$0.isEmpty }
        let right = rows.map { $0.filter { $0.rect.minX >= gutter } }.filter { !$0.isEmpty }
        guard left.count >= 2, right.count >= 2 else { return nil }
        let paired = rows.filter { row in
            row.contains { $0.rect.maxX <= gutter } && row.contains { $0.rect.minX >= gutter }
        }
        // Keep repeated short/numeric cell rows in visual order rather than reading down each column.
        let compactRows = paired.filter { row in
            row.allSatisfy { $0.rect.width <= $0.rect.height * 6 || $0.text.filter(\.isNumber).count * 2 > $0.text.count }
        }
        if paired.count >= 2 && compactRows.count * 2 >= paired.count { return nil }
        let leftBounds = left.flatMap { $0 }.reduce(CGRect.null) { $0.union($1.rect) }
        let rightBounds = right.flatMap { $0 }.reduce(CGRect.null) { $0.union($1.rect) }
        let verticalOverlap = min(leftBounds.maxY, rightBounds.maxY) - max(leftBounds.minY, rightBounds.minY)
        let height = median(rows.flatMap { $0.map { $0.rect.height } }) ?? 1
        guard verticalOverlap > height, leftBounds.width > height * 3, rightBounds.width > height * 3 else { return nil }
        return (left, right)
    }

    private static func singleFlow(_ rows: [[Line]]) -> [[Line]] {
        let lines = rows.filter { $0.count == 1 }.compactMap(\.first)
        let typicalHeight = median(lines.map { $0.rect.height }) ?? 1
        let steps = zip(lines, lines.dropFirst()).compactMap { previous, next -> CGFloat? in
            let step = previous.rect.midY - next.rect.midY
            let height = max(previous.rect.height, next.rect.height)
            guard step >= height * 0.55, step <= height * 2.1,
                  abs(previous.rect.minX - next.rect.minX) < typicalHeight * 0.8 else { return nil }
            return step
        }
        // The shorter recurring pitch represents wrapped lines. The larger gaps can be paragraph breaks.
        let localStep = steps.count >= 2 ? quantile(steps, fraction: 0.25) : nil
        let columnRight = quantile(lines.map { $0.rect.maxX }, fraction: 0.8)
        var output: [[Line]] = []
        var paragraph: [Line] = []
        func flush() {
            if !paragraph.isEmpty {
                output.append(paragraph)
                paragraph.removeAll(keepingCapacity: true)
            }
        }
        for row in rows {
            guard row.count == 1, let line = row.first else {
                flush()
                output += row.map { [$0] }
                continue
            }
            if let previous = paragraph.last,
               !canContinue(previous, with: line, paragraph: paragraph, localStep: localStep, columnRight: columnRight) {
                flush()
            }
            paragraph.append(line)
        }
        flush()
        return output
    }

    private static func canContinue(_ previous: Line, with next: Line, paragraph: [Line],
                                    localStep: CGFloat?, columnRight: CGFloat?) -> Bool {
        guard !previous.isStructured, !next.isStructured, !next.isListStart else { return false }
        let a = previous.rect, b = next.rect
        let height = max(a.height, b.height)
        guard height > 0, min(a.height, b.height) >= height * 0.73 else { return false }
        let step = a.midY - b.midY
        let limit = localStep.map { min(height * 2.15, max(height * 1.42, $0 * 1.28)) } ?? height * 1.8
        guard step >= min(a.height, b.height) * 0.52, step <= limit else { return false }
        let overlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        guard min(a.width, b.width) > 0, overlap >= min(a.width, b.width) * 0.45 else { return false }

        let leftDelta = b.minX - a.minX
        let firstIsList = paragraph.first?.isListStart == true
        // First-line and hanging indents are valid. A new inward indent after body lines starts a new paragraph.
        let aligned = abs(leftDelta) <= height * 0.8
        let leavesFirstIndent = paragraph.count == 1 && leftDelta > -height * 2.6 && leftDelta < 0
        let hangingIndent = firstIsList && paragraph.count == 1 && leftDelta > 0 && leftDelta <= height * 3
        guard aligned || leavesFirstIndent || hangingIndent else { return false }

        let referenceRight = max(columnRight ?? a.maxX, a.maxX, b.maxX)
        let referenceWidth = referenceRight - min(a.minX, b.minX)
        let shortPrevious = referenceWidth > height * 4 && a.width < referenceWidth * 0.7
        if shortPrevious && previous.endsSentence { return false }
        if shortPrevious && paragraph.count == 1 && !firstIsList && previous.text.count <= 8 && b.width > a.width * 1.7 {
            return false // A short label or chat sender followed by a wider body.
        }
        return true
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? { quantile(values, fraction: 0.5) }

    private static func quantile(_ values: [CGFloat], fraction: CGFloat) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[Int((CGFloat(sorted.count - 1) * fraction).rounded())]
    }
}

import CoreGraphics
import Foundation

public enum OCRMarkdown {
    /// Reconstructs Markdown from the visible characters and layout in an OCR result.
    public static func source(from document: OCRDocument, tables: [OCRTableRegion]? = nil) -> String {
        let scale = CGAffineTransform(scaleX: max(1, document.sourceSize.width),
                                      y: max(1, document.sourceSize.height))
        let lines = document.originalLines.map {
            SourceLine(text: $0.text, bounds: $0.normalizedBounds.applying(scale))
        }
        let rows = physicalRows(lines)
        // A literal Markdown table already has a delimiter row. Keep its exact column syntax.
        let hasLiteralTable = rows.contains { matches($0.text, #"^\s*\|?\s*:?-+:?(?:\s*\|\s*:?-+:?)+\s*\|?\s*$"#) }
        let detectedTables = hasLiteralTable ? [] : tables ?? OCRTableLayout.tables(in: document)
        if !detectedTables.isEmpty {
            return sourcePreservingTables(document, tables: detectedTables, scale: scale,
                                          literal: rows.contains { hasSourceSyntax($0.text) })
        }
        if rows.contains(where: { hasSourceSyntax($0.text) }) {
            return literalSource(rows)
        }
        return renderedSource(document, scale: scale)
    }

    private struct SourceLine {
        var text: String
        var bounds: CGRect

        var characterWidth: CGFloat? {
            guard text.count >= 4, text.utf8.count == text.count, bounds.width > 0 else { return nil }
            return bounds.width / CGFloat(text.count)
        }
    }

    private static func physicalRows(_ lines: [SourceLine]) -> [SourceLine] {
        var rows: [SourceLine] = []
        for line in lines {
            if let last = rows.last {
                let height = min(last.bounds.height, line.bounds.height)
                let gap = line.bounds.minX - last.bounds.maxX
                let characterWidth = last.characterWidth ?? line.characterWidth ?? height * 0.55
                if height > 0, abs(last.bounds.midY - line.bounds.midY) <= 0.4 * height,
                   gap >= -height * 0.15, gap <= characterWidth * 6 {
                    let count = max(0, Int((gap / characterWidth).rounded()))
                    rows[rows.count - 1] = SourceLine(text: last.text + String(repeating: " ", count: count) + line.text,
                                                      bounds: last.bounds.union(line.bounds))
                    continue
                }
            }
            rows.append(line)
        }
        return rows
    }

    private static func hasSourceSyntax(_ text: String) -> Bool {
        let block = #"^\s*(?:#{1,6}(?:\s|$)|`{3,}[^`]*$|~{3,}|>\s|(?:[-*_]\s*){3,}$|\|?\s*:?-+:?(?:\s*\|\s*:?-+:?)+\s*\|?$)"#
        let inline = #"(?:!?\[[^\]]+\]\([^)]+\)|\*\*[^*]+\*\*|__[^_]+__|~~[^~]+~~|(?<!\w)\*[^*\s][^*]*\*(?!\w)|(?<!\w)_[^_\s][^_]*_(?!\w)|`[^`]+`)"#
        return matches(text, block) || matches(text, inline)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func sourcePreservingTables(_ document: OCRDocument, tables: [OCRTableRegion],
                                               scale: CGAffineTransform, literal: Bool) -> String {
        var byLine: [UUID: Int] = [:]
        for (index, table) in tables.enumerated() where table.rows.count >= 2 && table.rows.contains(where: { $0.count >= 2 }) {
            for id in table.lineIDs where byLine[id] == nil { byLine[id] = index }
        }
        var emitted: Set<Int> = []
        var sections: [String] = []
        var prose: [OCRTextBlock] = []
        func flushProse() {
            guard !prose.isEmpty else { return }
            if literal {
                let lines = prose.flatMap(\.lines).map {
                    SourceLine(text: $0.text, bounds: $0.normalizedBounds.applying(scale))
                }
                sections.append(literalSource(physicalRows(lines)))
            } else {
                let chunk = OCRDocument(blocks: prose, languages: document.languages, sourceSize: document.sourceSize)
                sections.append(renderedSource(chunk, scale: scale))
            }
            prose.removeAll(keepingCapacity: true)
        }

        let chunks = literal ? [document.originalLines] : document.blocks.map(\.lines)
        for lines in chunks {
            var remainder: [OCRTextLine] = []
            func keepRemainder() {
                guard !remainder.isEmpty else { return }
                let bounds = remainder.reduce(CGRect.null) { $0.union($1.normalizedBounds) }
                prose.append(OCRTextBlock(lines: remainder, normalizedBounds: bounds))
                remainder.removeAll(keepingCapacity: true)
            }
            for line in lines {
                if let table = byLine[line.id] {
                    if emitted.insert(table).inserted {
                        keepRemainder()
                        flushProse()
                        sections.append(markdownTable(tables[table].rows))
                    }
                } else {
                    remainder.append(line)
                }
            }
            keepRemainder()
        }
        flushProse()
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func markdownTable(_ rows: [[String]]) -> String {
        guard let first = rows.first, let columnCount = rows.map(\.count).max(), columnCount >= 2 else { return "" }
        func pipeRow(_ values: [String]) -> String {
            "| " + (0..<columnCount).map { values.indices.contains($0) ? values[$0] : "" }.joined(separator: " | ") + " |"
        }
        func escapedRow(_ values: [String]) -> String {
            pipeRow(values.map { value in
                value.components(separatedBy: .newlines).joined(separator: " ").map { character in
                    "\\|`*_~[]<>".contains(character) ? "\\\(character)" : String(character)
                }.joined()
            })
        }
        return ([escapedRow(first), pipeRow(Array(repeating: "---", count: columnCount))]
                + rows.dropFirst().map(escapedRow)).joined(separator: "\n")
    }

    private static func literalSource(_ rows: [SourceLine]) -> String {
        guard let leadingMargin = rows.filter({ !$0.bounds.isEmpty }).map({ $0.bounds.minX }).min() else {
            return rows.map(\.text).joined(separator: "\n")
        }
        let height = median(rows.map { $0.bounds.height }.filter { $0 > 0 }) ?? 1
        let characterWidth = median(rows.compactMap(\.characterWidth)) ?? height * 0.55
        let pitches = zip(rows, rows.dropFirst()).map { $0.bounds.midY - $1.bounds.midY }
            .filter { $0 >= height * 0.65 && $0 <= height * 1.8 }
        let pitch = median(pitches) ?? height * 1.35

        // OCR trims leading spaces and does not emit blanks. Restore only the visible grid spacing.
        var output: [String] = []
        for (index, row) in rows.enumerated() {
            if index > 0, !row.bounds.isEmpty, !rows[index - 1].bounds.isEmpty {
                let gap = rows[index - 1].bounds.midY - row.bounds.midY
                if gap >= pitch * 1.65 {
                    let blankCount = min(12, Int((gap / pitch).rounded()) - 1)
                    output.append(contentsOf: repeatElement("", count: blankCount))
                }
            }
            var text = row.text
            if !row.bounds.isEmpty, row.text.first?.isWhitespace != true {
                let offset = (row.bounds.minX - leadingMargin) / characterWidth
                if offset >= 0.85 {
                    let spaces = min(48, Int(offset.rounded()))
                    text = String(repeating: " ", count: spaces) + row.text
                }
            }
            output.append(text)
        }
        return output.joined(separator: "\n")
    }

    private struct ListIndent {
        let x: CGFloat
        let spaces: Int
        let markerWidth: Int
    }

    private static func renderedSource(_ document: OCRDocument, scale: CGAffineTransform) -> String {
        let bodyHeights = document.blocks.filter { $0.lines.count > 1 }.flatMap(\.lines)
            .map { $0.normalizedBounds.applying(scale).height }.filter { $0 > 0 }
        let allHeights = document.blocks.flatMap(\.lines)
            .map { $0.normalizedBounds.applying(scale).height }.filter { $0 > 0 }
        let bodyHeight = median(bodyHeights) ?? median(allHeights) ?? 0
        let parts = document.blocks.flatMap { renderedParts($0, scale: scale, bodyHeight: bodyHeight) }
        var output = ""
        var list: [ListIndent] = []
        for (block, detachedTitle) in parts {
            let text = block.paragraphText
            guard !text.isEmpty else { continue }
            let bounds = block.normalizedBounds.applying(scale)
            if let item = listItem(in: text) {
                let separator = list.isEmpty ? "\n\n" : "\n"
                let tolerance = max(4, bodyHeight * 0.45)
                let x = bounds.minX
                while let indent = list.last, x < indent.x - tolerance { list.removeLast() }
                var spaces = list.last?.spaces ?? 0
                if let indent = list.last, x > indent.x + tolerance { spaces += indent.markerWidth }
                else if !list.isEmpty { list.removeLast() }
                list.append(ListIndent(x: x, spaces: spaces, markerWidth: item.marker.count))
                if !output.isEmpty { output += separator }
                output += String(repeating: " ", count: spaces) + item.marker + item.content
                continue
            }

            list.removeAll(keepingCapacity: true)
            if !output.isEmpty { output += "\n\n" }
            let isLargeStandaloneLine = bodyHeight > 0 && block.lines.count == 1 && bounds.height >= bodyHeight * 1.32
            if detachedTitle || (isLargeStandaloneLine && looksLikeTitle(text)) {
                output += bounds.height >= bodyHeight * 1.65 ? "# " : "## "
            }
            output += text
        }
        return output
    }

    private static func renderedParts(_ block: OCRTextBlock, scale: CGAffineTransform, bodyHeight: CGFloat)
        -> [(OCRTextBlock, detachedTitle: Bool)] {
        let lines = block.lines
        guard lines.count > 1, bodyHeight > 0 else { return [(block, false)] }
        let bounds = lines.map { $0.normalizedBounds.applying(scale) }
        let first = bounds[0]
        let splitIndex: Int
        let isTitle: Bool
        if listItem(in: lines[0].text) != nil {
            // A wrapped list item starts at the hanging indent. A distant line at the marker edge starts a new block.
            guard let index = lines.indices.dropFirst().first(where: { index in
                bounds[index].minX <= first.minX + bodyHeight * 0.35
                    && bounds[index - 1].midY - bounds[index].midY >= bodyHeight * 1.7
            }) else { return [(block, false)] }
            splitIndex = index
            isTitle = false
        } else {
            let next = bounds[1]
            guard looksLikeTitle(lines[0].text), first.height >= bodyHeight * 1.24,
                  first.height >= next.height * 1.2, first.midY - next.midY >= first.height * 1.6,
                  abs(first.minX - next.minX) <= bodyHeight * 0.65 else { return [(block, false)] }
            splitIndex = 1
            isTitle = true
        }

        func makeBlock(_ lines: ArraySlice<OCRTextLine>) -> OCRTextBlock {
            OCRTextBlock(lines: Array(lines), normalizedBounds: lines.reduce(.null) { $0.union($1.normalizedBounds) })
        }
        return [(makeBlock(lines[..<splitIndex]), isTitle), (makeBlock(lines[splitIndex...]), false)]
    }

    private static func looksLikeTitle(_ text: String) -> Bool {
        text.count >= 3 && text.count <= 76 && text.last.map { !"。！？.!?".contains($0) } == true
    }

    private static func listItem(in text: String) -> (marker: String, content: Substring)? {
        let marker = #"^(?:[-+*]\s+|[•●▪‣◦]\s*|\d{1,9}[.)](?:[ \t]+|(?=\p{Han})))"#
        guard let match = text.range(of: marker, options: .regularExpression), match.upperBound < text.endIndex else {
            return nil
        }
        let matched = text[match].trimmingCharacters(in: .whitespaces)
        let markdownMarker = matched.first?.isNumber == true ? matched + " " : "- "
        return (markdownMarker, text[match.upperBound...])
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }
}

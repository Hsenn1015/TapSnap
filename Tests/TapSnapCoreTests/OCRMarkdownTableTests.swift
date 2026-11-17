import CoreGraphics
import TapSnapOCR
import XCTest
@testable import TapSnapApp

final class OCRMarkdownTableTests: XCTestCase {
    func testStructuredCellsReplaceSourceLinesAndRenderEmptyCells() {
        let title = line("Inventory", x: 0.1, y: 0.85)
        let tableLines = [line("Name", x: 0.1, y: 0.60), line("Count", x: 0.5, y: 0.60),
                          line("A | B", x: 0.1, y: 0.50), line("Beta", x: 0.1, y: 0.40),
                          line("8", x: 0.5, y: 0.40)]
        let footer = line("End of report.", x: 0.1, y: 0.15)
        let document = document(lines: [title] + tableLines + [footer])
        let region = OCRTableRegion(rows: [["Name", "Count"], ["A | B", ""], ["Beta", "8"]],
                                    lineIDs: Set(tableLines.map(\.id)), normalizedBounds: .zero)

        let source = OCRMarkdown.source(from: document, tables: [region])

        XCTAssertEqual(source, "Inventory\n\n| Name | Count |\n| --- | --- |\n| A \\| B |  |\n| Beta | 8 |\n\nEnd of report.")
        let preview = OCRMarkdownHTML.body(source)
        XCTAssertTrue(preview.contains("A | B</td><td></td>"))
        XCTAssertTrue(preview.contains("</table></div><p>End of report.</p>"))
    }

    func testVisibleMarkdownDelimiterTakesPrecedenceOverInferredCells() {
        let lines = [line("| Name | Count |", x: 0.1, y: 0.60),
                     line("| :--- | ---: |", x: 0.1, y: 0.56),
                     line("| Beta | 8 |", x: 0.1, y: 0.52)]
        let region = OCRTableRegion(rows: [["Wrong", "Column"], ["unrelated", "text"]],
                                    lineIDs: Set(lines.map(\.id)), normalizedBounds: .zero)

        let source = OCRMarkdown.source(from: document(lines: lines), tables: [region])

        XCTAssertEqual(source, lines.map(\.text).joined(separator: "\n"))
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat) -> OCRTextLine {
        OCRTextLine(text: text, normalizedBounds: CGRect(x: x, y: y, width: 0.18, height: 0.03), confidence: 1)
    }

    private func document(lines: [OCRTextLine]) -> OCRDocument {
        let blocks = lines.map { OCRTextBlock(lines: [$0], normalizedBounds: $0.normalizedBounds) }
        return OCRDocument(blocks: blocks, languages: ["en-US"], sourceSize: CGSize(width: 700, height: 400))
    }
}

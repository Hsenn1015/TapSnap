import CoreGraphics
import TapSnapOCR
import Testing

struct OCRMarkdownTests {
    private let size = CGSize(width: 800, height: 600)

    @Test func preservesLiteralMarkdownAndRestoresCodeSpacing() {
        let rows = [
            line("# Release notes", x: 20, y: 20),
            line("- **Ready** and [docs](https://example.com)", x: 20, y: 40),
            line("- `inline`", x: 36, y: 60),
            line("```swift", x: 20, y: 100),
            line("if ready {", x: 20, y: 120),
            line("run()", x: 52, y: 160),
            line("}", x: 20, y: 180),
            line("```", x: 20, y: 200),
            line("| Feature | State |", x: 20, y: 240),
            line("| --- | :---: |", x: 20, y: 260),
            line("| OCR | Ready |", x: 20, y: 280)
        ]
        let reversed = rows.reversed().map { block([$0]) }
        let document = OCRDocument(blocks: reversed, languages: ["en-US"], sourceSize: size, originalLines: rows)

        #expect(OCRMarkdown.source(from: document) == """
        # Release notes
        - **Ready** and [docs](https://example.com)
          - `inline`

        ```swift
        if ready {

            run()
        }
        ```

        | Feature | State |
        | --- | :---: |
        | OCR | Ready |
        """)
    }

    @Test func recombinesNearbyOCRFragmentsOnTheSameSourceRow() {
        let rows = [
            line("##", x: 20, y: 20),
            line("Checklist", x: 44, y: 20),
            line("- [x]", x: 20, y: 40),
            line("Keep original words", x: 68, y: 40)
        ]
        let document = OCRDocument(blocks: rows.map { block([$0]) }, languages: ["en-US"], sourceSize: size, originalLines: rows)

        #expect(OCRMarkdown.source(from: document) == "## Checklist\n- [x] Keep original words")
    }

    @Test func usesRenderedHeadingAndConsecutiveNumberedList() {
        let blocks = [
            block([line("Project notes", x: 40, y: 20, height: 26)]),
            block([line("A longer sentence wraps here", x: 40, y: 62), line("and continues below.", x: 40, y: 82)]),
            block([line("1. First item", x: 40, y: 120)]),
            block([line("• Nested item", x: 62, y: 140)]),
            block([line("2.下一项", x: 40, y: 160)]),
            block([line("Return to plain text.", x: 40, y: 200)])
        ]
        let document = OCRDocument(blocks: blocks, languages: ["en-US", "zh-Hans"], sourceSize: size)

        #expect(OCRMarkdown.source(from: document) == """
        # Project notes

        A longer sentence wraps here and continues below.

        1. First item
           - Nested item
        2. 下一项

        Return to plain text.
        """)
    }

    @Test func leavesUncertainStylesAndDecimalNumbersAsText() {
        let blocks = [
            block([line("A normal first line", x: 20, y: 20)]),
            block([line("1.23 remains a decimal", x: 20, y: 60)]),
            block([line("This is a larger complete sentence.", x: 20, y: 100, height: 24)])
        ]
        let document = OCRDocument(blocks: blocks, languages: ["en-US"], sourceSize: size)

        #expect(OCRMarkdown.source(from: document) == "A normal first line\n\n1.23 remains a decimal\n\nThis is a larger complete sentence.")
    }

    @Test func restoresVisibleTitleAndListBoundariesInsideMergedOCRBlocks() {
        let blocks = [
            block([line("Project notes", x: 34, y: 26, height: 30),
                   line("A longer sentence wraps here", x: 32, y: 80, height: 24),
                   line("and continues below.", x: 30, y: 108, height: 20)]),
            block([line("1. First item", x: 30, y: 149, height: 24)]),
            block([line("• Nested item", x: 56, y: 178, height: 20)]),
            block([line("2. Next item", x: 30, y: 205, height: 24),
                   line("Return to plain text.", x: 32, y: 248, height: 22)])
        ]
        let document = OCRDocument(blocks: blocks, languages: ["en-US"], sourceSize: size)

        #expect(OCRMarkdown.source(from: document) == """
        ## Project notes

        A longer sentence wraps here and continues below.

        1. First item
           - Nested item
        2. Next item

        Return to plain text.
        """)
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat, height: CGFloat = 14) -> OCRTextLine {
        OCRTextLine(text: text, normalizedBounds: CGRect(
            x: x / size.width, y: 1 - (y + height) / size.height,
            width: CGFloat(text.count * 8) / size.width, height: height / size.height
        ), confidence: 1)
    }

    private func block(_ lines: [OCRTextLine]) -> OCRTextBlock {
        OCRTextBlock(lines: lines, normalizedBounds: lines.reduce(.null) { $0.union($1.normalizedBounds) })
    }
}

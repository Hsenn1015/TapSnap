import CoreGraphics
import TapSnapOCR
import XCTest

final class OCRParagraphTextTests: XCTestCase {
    func testChineseAndJapaneseJoinWithoutSpaces() {
        let block = textBlock("这是一段中文，", "同じ段落の", "折り返し。", "TapSnap 支持中英文。")
        XCTAssertEqual(block.paragraphText, "这是一段中文，同じ段落の折り返し。TapSnap 支持中英文。")
        XCTAssertEqual(block.fullText, "这是一段中文，\n同じ段落の\n折り返し。\nTapSnap 支持中英文。")
    }

    func testLatinWrapRestoresWordSpacingAndKeepsPunctuationTight() {
        let block = textBlock("Keep the original", "words", ", then read (", "or copy).")
        XCTAssertEqual(block.paragraphText, "Keep the original words, then read (or copy).")
    }

    func testUncertainHyphenAndLinkBreaksRemainVisible() {
        XCTAssertEqual(textBlock("cross-", "platform API").paragraphText, "cross-\nplatform API")
        XCTAssertEqual(textBlock("demo@", "example.com").paragraphText, "demo@\nexample.com")
        XCTAssertEqual(textBlock("See https://example.com/", "path").paragraphText, "See https://example.com/\npath")
        XCTAssertEqual(textBlock("See https://example.com", "for details.").paragraphText, "See https://example.com for details.")
    }

    func testParagraphExportAndOriginalLinesUseTheirRespectiveOrder() {
        let columnA = textBlock("First column", "continues.")
        let columnB = textBlock("Second column", "continues too.")
        let physical = [columnA.lines[0], columnB.lines[0], columnA.lines[1], columnB.lines[1]]
        let document = OCRDocument(blocks: [columnA, columnB], languages: ["en-US"], sourceSize: .zero,
                                   originalLines: physical)
        XCTAssertEqual(document.paragraphText, "First column continues.\n\nSecond column continues too.")
        XCTAssertEqual(document.originalLinesText, "First column\nSecond column\ncontinues.\ncontinues too.")
        XCTAssertEqual(document.plainText, "First column\ncontinues.\n\nSecond column\ncontinues too.")
    }

    private func textBlock(_ texts: String...) -> OCRTextBlock {
        OCRTextBlock(lines: texts.map { OCRTextLine(text: $0, normalizedBounds: .zero, confidence: 1) },
                     normalizedBounds: .zero)
    }
}

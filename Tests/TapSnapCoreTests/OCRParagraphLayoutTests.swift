import CoreGraphics
@testable import TapSnapOCR
import Testing

struct OCRParagraphLayoutTests {
    private let size = CGSize(width: 1_000, height: 800)

    @Test func joinsWrappedBodyAndKeepsIndentedParagraphsSeparate() {
        let lines = [
            line("本周进度", x: 30, y: 20, width: 118, height: 28),
            line("这是同一段文字，窗口较窄导致自然", x: 30, y: 63, width: 270),
            line("换行，复制后应连续阅读。", x: 30, y: 86, width: 187),
            line("新段落首行缩进，正文可能继续", x: 64, y: 109, width: 242),
            line("跨行排列。", x: 30, y: 132, width: 74),
        ]

        let layout = OCRParagraphLayout.layout(lines, sourceSize: size)

        #expect(layout.blocks.map(\.paragraphText) == [
            "本周进度", "这是同一段文字，窗口较窄导致自然换行，复制后应连续阅读。", "新段落首行缩进，正文可能继续跨行排列。",
        ])
        #expect(layout.originalLines.map(\.text) == lines.map(\.text))
    }

    @Test func keepsSeparateListItemsAndPreservesCodeAndTimeRows() {
        let lines = [
            line("1. A long item whose content continues on", x: 30, y: 20, width: 295),
            line("the following line.", x: 52, y: 44, width: 125),
            line("2. The next item", x: 30, y: 68, width: 118),
            line("10:23", x: 30, y: 92, width: 45),
            line("let value = 1", x: 30, y: 116, width: 108),
            line("return value + transform(value)", x: 30, y: 140, width: 233),
        ]

        let layout = OCRParagraphLayout.layout(lines, sourceSize: size)

        #expect(layout.blocks.map(\.lines.count) == [2, 1, 1, 1, 1])
        #expect(layout.blocks.first?.paragraphText == "1. A long item whose content continues on the following line.")
    }

    @Test func estimatesLinePitchFromShorterGaps() {
        let observations = [
            line("Reading notes", x: 30, y: 22, width: 220, height: 36),
            line("The first paragraph has wrapped across two", x: 25, y: 85, width: 473, height: 28),
            line("lines so the wording should read continuously.", x: 25, y: 115, width: 495, height: 30),
            line("This is a separate paragraph that keeps its", x: 25, y: 172, width: 459, height: 28),
            line("own space below the previous thought.", x: 26, y: 205, width: 420, height: 26),
        ]

        let layout = OCRParagraphLayout.layout(observations, sourceSize: size)

        #expect(layout.blocks.map(\.lines.count) == [1, 2, 2])
    }

    @Test func distinguishesAChineseListFromAnAddressWrap() {
        let lines = [
            line("The gateway responds from", x: 30, y: 20, width: 232),
            line("192.0.2.26 during deployment.", x: 30, y: 44, width: 251),
            line("1.第一条独立事项", x: 30, y: 68, width: 144),
            line("2.第二条独立事项", x: 30, y: 92, width: 144),
        ]

        let layout = OCRParagraphLayout.layout(lines, sourceSize: size)

        #expect(layout.blocks.map(\.lines.count) == [2, 1, 1])
    }

    @Test func readsColumnsInOrderWithoutBreakingTheFullWidthIntro() {
        let introFirst = line("A full-width introduction begins before the two columns", x: 30, y: 20, width: 654)
        let introSecond = line("and continues within this full-width block.", x: 30, y: 44, width: 488)
        let leftFirst = line("The first part belongs to the left column", x: 30, y: 96, width: 285)
        let leftSecond = line("and ends on this second line.", x: 30, y: 120, width: 205)
        let rightFirst = line("The second part follows in the right column", x: 482, y: 96, width: 300)
        let rightSecond = line("and has its own continuation.", x: 482, y: 120, width: 214)
        let observations = [rightSecond, leftSecond, introSecond, rightFirst, leftFirst, introFirst]

        let paragraphs = OCRParagraphLayout.layout(observations, sourceSize: size)
        let original = OCRParagraphLayout.layout(observations, sourceSize: size, groupParagraphs: false)
        let physicalOrder = [introFirst, introSecond, leftFirst, rightFirst, leftSecond, rightSecond].map(\.text)

        #expect(paragraphs.blocks.map { $0.lines.map(\.text) } == [
            [introFirst.text, introSecond.text], [leftFirst.text, leftSecond.text], [rightFirst.text, rightSecond.text],
        ])
        #expect(paragraphs.originalLines.map(\.text) == physicalOrder)
        #expect(original.blocks.map(\.paragraphText) == physicalOrder)
    }

    @Test func leavesCompactTableCellsInRowOrder() {
        let lines = [
            line("文件名称", x: 30, y: 20, width: 86),
            line("项目数量", x: 300, y: 20, width: 78),
            line("季度报告", x: 30, y: 44, width: 82),
            line("2030", x: 300, y: 44, width: 55),
            line("年度报告", x: 30, y: 68, width: 80),
            line("2400", x: 300, y: 68, width: 55),
        ]

        let layout = OCRParagraphLayout.layout(lines, sourceSize: size)

        #expect(layout.blocks.map(\.paragraphText) == lines.map(\.text))
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 18) -> OCRTextLine {
        OCRTextLine(text: text, normalizedBounds: CGRect(
            x: x / size.width, y: 1 - (y + height) / size.height,
            width: width / size.width, height: height / size.height
        ), confidence: 1)
    }
}

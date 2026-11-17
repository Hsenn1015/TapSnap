import CoreGraphics
import TapSnapOCR
import Testing

struct OCRTableLayoutTests {
    private let size = CGSize(width: 800, height: 500)

    @Test func restoresBorderlessColumnsAndEmptyCells() throws {
        let intro = line("Weekly report", x: 25, y: 20, width: 125)
        let footer = line("Notes and methodology", x: 25, y: 178, width: 150)
        let rows = [
            line("项目", x: 25, y: 52), line("状态", x: 205, y: 52), line("备注", x: 400, y: 52),
            line("TapSnap", x: 25, y: 81, width: 64), line("可用", x: 400, y: 81),
            line("录屏", x: 26, y: 109), line("完成", x: 204, y: 110), line("已验证", x: 401, y: 109, width: 50),
            line("截图", x: 25, y: 138), line("处理中", x: 206, y: 138, width: 50)
        ]

        let tables = OCRTableLayout.tables(in: document([intro] + rows.shuffled() + [footer]))
        #expect(tables.count == 1)
        let table = try #require(tables.first)
        #expect(table.rows == [
            ["项目", "状态", "备注"],
            ["TapSnap", "", "可用"],
            ["录屏", "完成", "已验证"],
            ["截图", "处理中", ""]
        ])
        #expect(table.lineIDs == Set(rows.map(\.id)))
        #expect(!table.normalizedBounds.intersects(intro.normalizedBounds))
        #expect(!table.normalizedBounds.intersects(footer.normalizedBounds))
    }

    @Test func recognizesConsistentlyRightAlignedNumbers() throws {
        let rows = [
            line("Month", x: 30, y: 20, width: 47), line("Total", x: 290, y: 20, width: 40),
            line("February", x: 30, y: 48, width: 65), line("12,000", x: 280, y: 48, width: 50),
            line("March", x: 30, y: 76, width: 50), line("458", x: 304, y: 76, width: 26)
        ]

        let table = try #require(OCRTableLayout.tables(in: document(rows)).first)
        #expect(table.rows == [["Month", "Total"], ["February", "12,000"], ["March", "458"]])
    }

    @Test func leavesTwoColumnProseAndUnheadedPairedLabelsAsText() {
        let prose = [
            line("The first column contains normal flowing text", x: 22, y: 20, width: 302),
            line("It is read in a separate flowing column of text", x: 421, y: 20, width: 316),
            line("and continues across the next few lines before", x: 22, y: 47, width: 299),
            line("with its own logical structure and different", x: 421, y: 47, width: 295),
            line("the reader moves to the other column.", x: 22, y: 75, width: 254),
            line("paragraph without a table relationship.", x: 421, y: 75, width: 263)
        ]
        let pairs = [
            line("姓名", x: 32, y: 22), line("李玟", x: 250, y: 22),
            line("部门", x: 32, y: 48), line("研发组", x: 250, y: 48, width: 51),
            line("办公地", x: 32, y: 74, width: 51), line("三号楼", x: 250, y: 74, width: 51)
        ]

        #expect(OCRTableLayout.tables(in: document(prose)).isEmpty)
        #expect(OCRTableLayout.tables(in: document(pairs)).isEmpty)
    }

    @Test func leavesDisconnectedRowsAsText() {
        let rows = [20, 33, 98].flatMap { y in
            [line("标题", x: 25, y: CGFloat(y)), line("状态", x: 170, y: CGFloat(y)),
             line("备注", x: 330, y: CGFloat(y))]
        }

        #expect(OCRTableLayout.tables(in: document(rows)).isEmpty)
    }

    private func document(_ lines: [OCRTextLine]) -> OCRDocument {
        OCRDocument(blocks: [], languages: ["zh-Hans", "en-US"], sourceSize: size, originalLines: lines)
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 38) -> OCRTextLine {
        let height: CGFloat = 18
        let bounds = CGRect(x: x / size.width, y: 1 - (y + height) / size.height,
                            width: width / size.width, height: height / size.height)
        return OCRTextLine(text: text, normalizedBounds: bounds, confidence: 1)
    }
}

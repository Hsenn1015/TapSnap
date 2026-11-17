import CoreGraphics
import TapSnapOCR
import XCTest

final class OCRTableGridTests: XCTestCase {
    private let size = CGSize(width: 640, height: 520)
    private let rows = [142, 180, 220, 261]
    private let columns = [181, 254, 322, 404]

    func testFindsFaintInsetGridInLightAndDarkScreenshots() throws {
        for (background, rule) in [(UInt8(245), UInt8(234)), (UInt8(28), UInt8(41))] {
            let grid = try XCTUnwrap(OCRTableGrid.detect(in: image(background: background, rule: rule)))
            XCTAssertEqual(grid.rows, rows)
            XCTAssertEqual(grid.columns, columns)
            XCTAssertEqual(grid.rowCount, 3)
            XCTAssertEqual(grid.columnCount, 3)
        }
    }

    func testKeepsEmptyCellsAndOnlyConsumesLinesInsideGrid() throws {
        let grid = try XCTUnwrap(OCRTableGrid.detect(in: image(background: 245, rule: 234)))
        let title = line("Daily inventory", at: (182, 102))
        let footer = line("Totals checked", at: (182, 301))
        let tableLines = [
            line("Item", at: (188, 150)), line("Count", at: (260, 150)), line("Unit", at: (328, 150)),
            line("Desk", at: (188, 190)), line("3", at: (260, 190)), line("each", at: (328, 190)),
            line("Lamp", at: (188, 226)), line("base", at: (188, 242)), line("pair", at: (328, 226)),
        ]
        let lines = [title] + tableLines + [footer]
        let document = OCRDocument(blocks: [], languages: ["en-US"], sourceSize: size, originalLines: lines)
        let table = try XCTUnwrap(grid.table(in: document))
        XCTAssertEqual(table.rows, [["Item", "Count", "Unit"], ["Desk", "3", "each"], ["Lamp base", "", "pair"]])
        XCTAssertEqual(table.lineIDs, Set(tableLines.map(\.id)))
        XCTAssertEqual(table.normalizedBounds.minX, CGFloat(columns[0]) / size.width, accuracy: 0.0001)
        XCTAssertEqual(table.normalizedBounds.maxY, 1 - CGFloat(rows[0]) / size.height, accuracy: 0.0001)
    }

    func testDoesNotJoinUnrelatedHorizontalAndVerticalSeparators() {
        XCTAssertNil(OCRTableGrid.detect(in: image(background: 245, rule: 115, includesTable: false)))
    }

    private func line(_ text: String, at point: (Int, Int)) -> OCRTextLine {
        OCRTextLine(text: text, normalizedBounds: CGRect(
            x: CGFloat(point.0) / size.width, y: 1 - CGFloat(point.1 + 12) / size.height,
            width: CGFloat(text.count * 6) / size.width, height: 12 / size.height
        ), confidence: 1)
    }

    private func image(background: UInt8, rule: UInt8, includesTable: Bool = true) -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        var bytes = [UInt8](repeating: background, count: width * height)
        if includesTable {
            for y in rows {
                for x in columns.first!...columns.last! where x != 290 { bytes[y * width + x] = rule }
            }
            for x in columns {
                for y in rows.first!...rows.last! where y != 202 { bytes[y * width + x] = rule }
            }
        }
        // Unrelated rules from window chrome and from another part of the document.
        for y in [70, 350] {
            for x in 90...570 { bytes[y * width + x] = rule }
        }
        for x in [520, 599] {
            for y in 126...310 { bytes[y * width + x] = rule }
        }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return context.makeImage()!
    }
}

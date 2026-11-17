import CoreGraphics
import TapSnapOCR
import XCTest

/// 表格网格检测的回归测试。
///
/// 判据是「连续暗像素够长才算表格线」—— 这里用人工画的表格图验证它能分出
/// 线和文字，也验证没有表格时会老实返回 nil。
final class TableGridTests: XCTestCase {
    private func makeImage(
        width: Int,
        height: Int,
        rows: [Int],
        columns: [Int],
        withTextLikeNoise: Bool = false
    ) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        func paint(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let i = (y * width + x) * 4
            bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 0; bytes[i + 3] = 255
        }
        // 2px 粗的横线 / 竖线。
        for y in rows {
            for x in 0..<width {
                paint(x, y); paint(x, y + 1)
            }
        }
        for x in columns {
            for y in 0..<height {
                paint(x, y); paint(x + 1, y)
            }
        }
        if withTextLikeNoise {
            // 每格中间撒一些短笔画，模拟文字（不应该被判成表格线）。
            for row in 0..<(rows.count - 1) {
                for column in 0..<(columns.count - 1) {
                    let baseY = rows[row] + 10
                    let baseX = columns[column] + 6
                    for step in 0..<6 {
                        paint(baseX + step * 2, baseY)
                        paint(baseX + step * 2, baseY + 6)
                    }
                }
            }
        }
        let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    func testDetectsTableGrid() {
        let image = makeImage(
            width: 240,
            height: 180,
            rows: [10, 60, 110, 160],
            columns: [10, 90, 170, 230],
            withTextLikeNoise: true
        )

        let grid = OCRTableGrid.detect(in: image)
        XCTAssertNotNil(grid)
        XCTAssertEqual(grid?.rows.count, 4)
        XCTAssertEqual(grid?.columns.count, 4)
        XCTAssertEqual(grid?.rowCount, 3)
        XCTAssertEqual(grid?.columnCount, 3)
    }

    func testNoGridReturnsNil() {
        let image = makeImage(width: 240, height: 180, rows: [], columns: [], withTextLikeNoise: false)
        XCTAssertNil(OCRTableGrid.detect(in: image))
    }

    func testCellIndexMapping() {
        let image = makeImage(width: 240, height: 180, rows: [10, 60, 110, 160], columns: [10, 90, 170, 230])
        guard let grid = OCRTableGrid.detect(in: image) else {
            XCTFail("应该检测到网格")
            return
        }
        XCTAssertEqual(grid.rowIndex(for: 30), 0)
        XCTAssertEqual(grid.rowIndex(for: 80), 1)
        XCTAssertEqual(grid.rowIndex(for: 140), 2)
        XCTAssertEqual(grid.columnIndex(for: 50), 0)
        XCTAssertEqual(grid.columnIndex(for: 200), 2)
        XCTAssertNil(grid.rowIndex(for: 5), "线外不该有单元格")
    }

    func testDarkThemeInvertedImageStillDetected() {
        // 深色主题：黑底亮线。同样应该能找出网格。
        var bytes = [UInt8](repeating: 0, count: 200 * 120 * 4)
        func paint(_ x: Int, _ y: Int) {
            guard x >= 0, x < 200, y >= 0, y < 120 else { return }
            let i = (y * 200 + x) * 4
            bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255; bytes[i + 3] = 255
        }
        for y in [10, 60, 110] { for x in 0..<200 { paint(x, y); paint(x, y + 1) } }
        for x in [10, 100, 190] { for y in 0..<120 { paint(x, y); paint(x + 1, y) } }
        let context = CGContext(
            data: &bytes,
            width: 200,
            height: 120,
            bitsPerComponent: 8,
            bytesPerRow: 200 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!

        let grid = OCRTableGrid.detect(in: image)
        XCTAssertEqual(grid?.rows.count, 3)
        XCTAssertEqual(grid?.columns.count, 3)
    }
}

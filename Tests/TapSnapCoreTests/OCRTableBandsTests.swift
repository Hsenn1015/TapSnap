import CoreGraphics
import Foundation
@testable import TapSnapOCR
import XCTest

final class OCRTableBandsTests: XCTestCase {
    private let width = 640
    private let height = 440

    func testStripedRowBoundariesKeepWrappedCellsAndUnshadedLastRow() throws {
        let fixture = sampleTable()
        let document = OCRDocument(blocks: [], languages: ["zh-Hans", "en-US"],
            sourceSize: CGSize(width: width, height: height), originalLines: fixture.lines.reversed())

        for dark in [false, true] {
            let tables = OCRTableBands.tables(in: document, image: image(dark: dark, striped: true))
            XCTAssertEqual(tables.count, 1)
            let table = try XCTUnwrap(tables.first)
            XCTAssertEqual(table.rows, fixture.cells)
            XCTAssertEqual(table.lineIDs, Set(fixture.lines.dropFirst().dropLast().map(\.id)))
        }
    }

    func testThinRulesAndPlainBackgroundAreNotStripeBoundaries() {
        let fixture = sampleTable()
        let document = OCRDocument(blocks: [], languages: ["zh-Hans", "en-US"],
            sourceSize: CGSize(width: width, height: height), originalLines: fixture.lines)
        XCTAssertTrue(OCRTableBands.tables(in: document, image: image(dark: false, striped: false)).isEmpty)
        XCTAssertTrue(OCRTableBands.tables(in: document, image: image(dark: false, striped: false, ruled: true)).isEmpty)
    }

    func testTightCropRetainsHeadingWithNoTopTransition() throws {
        let fixture = sampleTable()
        let top = 91
        let cropSize = CGSize(width: width, height: height - top)
        let crop = try XCTUnwrap(image(dark: false, striped: true).cropping(to: CGRect(origin: CGPoint(x: 0, y: top), size: cropSize)))
        let lines = fixture.lines.dropFirst().map { line in
            let bounds = line.normalizedBounds
            return OCRTextLine(text: line.text, normalizedBounds: CGRect(x: bounds.minX,
                y: bounds.minY * CGFloat(height) / cropSize.height, width: bounds.width,
                height: bounds.height * CGFloat(height) / cropSize.height), confidence: line.confidence)
        }
        let document = OCRDocument(blocks: [], languages: ["zh-Hans", "en-US"], sourceSize: cropSize, originalLines: lines)

        let table = try XCTUnwrap(OCRTableBands.tables(in: document, image: crop).first)
        XCTAssertEqual(table.rows, fixture.cells)
    }

    func testKeepsColumnSeedsWhenOCRSpansAcrossCellBoundary() throws {
        var lines = sampleTable().lines
        for (first, second) in [(7, 9), (4, 5)] {
            let left = lines[first], right = lines[second]
            lines[first] = OCRTextLine(text: left.text + " " + right.text,
                normalizedBounds: left.normalizedBounds.union(right.normalizedBounds), confidence: 1)
            lines.remove(at: second)
        }
        let document = OCRDocument(blocks: [], languages: ["zh-Hans", "en-US"],
            sourceSize: CGSize(width: width, height: height), originalLines: lines)

        let table = try XCTUnwrap(OCRTableBands.tables(in: document, image: image(dark: false, striped: true)).first)
        XCTAssertEqual(table.rows.count, 6)
        XCTAssertEqual(table.rows.first, ["场景", "接口", "取值位置"])
        XCTAssertTrue(table.hasTextSpanningColumns)
        XCTAssertEqual(table.lineIDs, Set(lines.dropFirst().dropLast().map(\.id)))
    }

    private func sampleTable() -> (lines: [OCRTextLine], cells: [[String]]) {
        let lines = [
            line("接口说明", x: 30, y: 32),
            line("场景", x: 32, y: 102), line("接口", x: 145, y: 102), line("取值位置", x: 435, y: 102),
            line("新建 API", x: 33, y: 137), line("POST /api/items/{id}", x: 149, y: 137, width: 155),
            line("request_format", x: 436, y: 137, width: 108),
            line("最近调试配", x: 33, y: 177), line("置", x: 33, y: 197),
            line("GET /api/items/{id}/debug-config", x: 149, y: 177, width: 265),
            line("仍为空", x: 436, y: 178),
            line("平台导", x: 33, y: 230), line("出", x: 33, y: 249),
            line("原始请求示例", x: 436, y: 230, width: 108),
            line("编排保存", x: 33, y: 281), line("POST /api/flows", x: 149, y: 281, width: 122),
            line("PUT /api/flows/{id}", x: 147, y: 302, width: 161),
            line("依插件契约", x: 436, y: 281, width: 96),
            line("编排候选", x: 33, y: 335), line("GET /api/hints", x: 149, y: 334, width: 112),
            line("详见后文", x: 436, y: 335),
            line("这些字段的含义不同。", x: 30, y: 398, width: 190),
        ]
        return (lines, [
            ["场景", "接口", "取值位置"],
            ["新建 API", "POST /api/items/{id}", "request_format"],
            ["最近调试配置", "GET /api/items/{id}/debug-config", "仍为空"],
            ["平台导出", "", "原始请求示例"],
            ["编排保存", "POST /api/flows PUT /api/flows/{id}", "依插件契约"],
            ["编排候选", "GET /api/hints", "详见后文"],
        ])
    }

    private func image(dark: Bool, striped: Bool, ruled: Bool = false) -> CGImage {
        let base: UInt8 = dark ? 23 : 255
        var pixels = [UInt8](repeating: base, count: width * height)
        for y in 92..<322 {
            let value: UInt8
            switch y {
            case 92..<126: value = dark ? 41 : 241
            case 166..<218, 269..<322: value = dark ? 29 : 249
            default: value = base
            }
            for x in 20..<610 {
                if striped { pixels[y * width + x] = value }
                if ruled && ([92, 126, 166, 218, 269, 321].contains(y) || [20, 130, 423, 609].contains(x)) {
                    pixels[y * width + x] = 30
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func line(_ text: String, x: Int, y: Int, width lineWidth: Int = 55) -> OCRTextLine {
        let rect = CGRect(x: CGFloat(x) / CGFloat(width), y: 1 - CGFloat(y + 15) / CGFloat(height),
            width: CGFloat(lineWidth) / CGFloat(width), height: 15 / CGFloat(height))
        return OCRTextLine(text: text, normalizedBounds: rect, confidence: 1)
    }
}

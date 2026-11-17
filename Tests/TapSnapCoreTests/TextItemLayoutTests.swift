import AppKit
import TapSnapCore
import XCTest
@testable import TapSnapApp

@MainActor
final class TextItemLayoutTests: XCTestCase {
    func testWrappedChineseAndEnglishMatchNativeTextViewHeight() throws {
        let item = TextItem(text: "这是框内的中文标注 mixed English words wrap here", bounds: CGRect(x: 10, y: 10, width: 140, height: 24))
        item.fitToText(maxWidth: 140)
        XCTAssertLessThanOrEqual(item.bounds.width, 140)
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 140, height: 300))
        editor.textContainerInset = TextItem.textInset
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = CGSize(width: 140 - 2 * TextItem.textInset.width, height: 100_000)
        editor.textStorage?.setAttributedString(NSAttributedString(string: item.text, attributes: item.textAttributes()))
        let manager = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        manager.ensureLayout(for: container)
        let expected = ceil(manager.usedRect(for: container).height) + TextItem.textInset.height * 2
        XCTAssertEqual(item.bounds.height, expected, accuracy: 1)
        XCTAssertGreaterThan(item.bounds.height, 35)
    }

    func testExplicitAndTrailingNewlinesHaveRoomAndFontChangesRetainWidthCap() {
        let item = TextItem(text: "第一行\n第二行\n", bounds: CGRect(x: 7, y: 9, width: 80, height: 24))
        item.fitToText(maxWidth: 80)
        let firstHeight = item.bounds.height
        XCTAssertGreaterThan(firstHeight, 45)
        XCTAssertEqual(item.bounds.origin, CGPoint(x: 7, y: 9))
        item.style.fontSize = 26
        item.fitToText()
        XCTAssertEqual(item.textContainerWidth, 80)
        XCTAssertLessThanOrEqual(item.bounds.width, 80)
        XCTAssertGreaterThan(item.bounds.height, firstHeight)
    }

    func testFinalImageRendersBothLinesAtTopLeftAndRespectsBoxWidth() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 220, height: 160, bitsPerComponent: 8,
            bytesPerRow: 220 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 220, height: 160))
        let document = EditDocument(baseImage: try XCTUnwrap(context.makeImage()), scale: 1)
        var style = EditItemStyle()
        style.color = RGBAColor(rgb: 0)
        style.fontSize = 24
        let item = TextItem(text: "FIRST\n第二行", bounds: CGRect(x: 10, y: 10, width: 140, height: 24), style: style)
        item.fitToText(maxWidth: 140)
        document.append(item)
        let rendered = try document.render()
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 220, height: 160, bitsPerComponent: 8,
            bytesPerRow: 220 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(rendered, in: CGRect(x: 0, y: 0, width: 220, height: 160))
        let bytes = pixels.data!.assumingMemoryBound(to: UInt8.self)
        func ink(_ rect: CGRect) -> Int {
            var count = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    if bytes[(y * 220 + x) * 4] < 120 { count += 1 }
                }
            }
            return count
        }
        XCTAssertGreaterThan(ink(CGRect(x: 10, y: 10, width: 140, height: 32)), 60)
        XCTAssertGreaterThan(ink(CGRect(x: 10, y: 42, width: 140, height: 32)), 60)
        XCTAssertEqual(ink(CGRect(x: 150, y: 0, width: 70, height: 160)), 0)
        XCTAssertEqual(ink(CGRect(x: 0, y: 100, width: 220, height: 60)), 0)
    }
}

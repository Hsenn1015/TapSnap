import AppKit
import TapSnapOCR
import XCTest
@testable import TapSnapApp

@MainActor
final class OCRResultPanelTests: XCTestCase {
    func testDragAreaReceivesFirstClickOnlyInTheTitleBar() throws {
        _ = NSApplication.shared
        let controller = OCRResultPanel(theme: { .light })
        let line = OCRTextLine(text: "这是一段可选中和复制的文字。", normalizedBounds: .zero, confidence: 1)
        let block = OCRTextBlock(lines: [line], normalizedBounds: .zero)
        let document = OCRDocument(blocks: [block], languages: ["zh-Hans"], sourceSize: .zero)
        let frame = CGRect(x: 80, y: 80, width: 740, height: 486)
        let panel = controller.makeWindow(document: document, image: image(), frame: frame) { _ in }
        defer { panel.close() }

        XCTAssertTrue(panel.isMovable)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.canBecomeKey)
        let host = try XCTUnwrap(panel.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
        let drag = try XCTUnwrap(findDragView(in: host))
        let region = host.convert(drag.bounds, from: drag)
        let titlePoint = CGPoint(x: region.midX, y: region.midY)
        let headerActionPoint = CGPoint(x: region.maxX + 30, y: region.midY)
        let readerPoint = CGPoint(x: region.midX, y: host.bounds.midY)
        let parent = try XCTUnwrap(host.superview)
        let windowPoint = host.convert(titlePoint, to: nil)

        XCTAssertTrue(drag.acceptsFirstMouse(for: nil))
        XCTAssertGreaterThan(region.width, 150)
        XCTAssertTrue(host.hitTest(parent.convert(titlePoint, from: host)) === drag)
        XCTAssertTrue(parent.hitTest(windowPoint) === drag)
        XCTAssertFalse(host.hitTest(parent.convert(headerActionPoint, from: host)) === drag)
        XCTAssertFalse(host.hitTest(parent.convert(readerPoint, from: host)) === drag)
    }

    func testResizablePanelExpandsItsContentAndKeepsTheTitleBarAtTheTop() throws {
        _ = NSApplication.shared
        let controller = OCRResultPanel(theme: { .light })
        let document = OCRDocument(blocks: [], languages: ["zh-Hans"], sourceSize: .zero)
        let frame = CGRect(x: 80, y: 80, width: 740, height: 486)
        let panel = controller.makeWindow(document: document, image: image(), frame: frame) { _ in }
        defer { panel.close() }
        let host = try XCTUnwrap(panel.contentView)

        XCTAssertTrue(panel.styleMask.contains([.titled, .resizable, .fullSizeContentView]))
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotEqual(panel.standardWindowButton(button)?.isHidden, false)
        }
        XCTAssertEqual(panel.contentMinSize, CGSize(width: 660, height: 310))
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(host.bounds.size, frame.size)

        let largerFrame = CGRect(x: 80, y: 80, width: 860, height: 600)
        panel.setFrame(largerFrame, display: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, largerFrame.size)
        let drag = try XCTUnwrap(findDragView(in: host))
        let titleInWindow = drag.convert(drag.bounds, to: nil)
        XCTAssertEqual(titleInWindow.maxY, largerFrame.height, accuracy: 1)
        XCTAssertGreaterThan(titleInWindow.width, 460)
    }

    func testPanelFitsNearTheEdgeOfASecondaryDisplay() {
        let visible = CGRect(x: -800, y: -320, width: 760, height: 450)
        let frame = OCRResultPanel.panelFrame(near: CGPoint(x: visible.maxX, y: visible.minY), in: visible)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.width, 736)
        XCTAssertEqual(frame.maxX, visible.maxX - 12)
        XCTAssertEqual(frame.minY, visible.minY + 12)
        XCTAssertEqual(frame.maxY, visible.maxY - 12)
    }

    func testSearchPreservesOCRGeometryAndCopyAll() {
        let first = OCRTextLine(text: "第一行 Alpha", normalizedBounds: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.03), confidence: 1)
        let second = OCRTextLine(text: "第二行 Beta", normalizedBounds: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.03), confidence: 1)
        let block = OCRTextBlock(lines: [first, second], normalizedBounds: first.normalizedBounds.union(second.normalizedBounds))
        let document = OCRDocument(blocks: [block], languages: ["zh-Hans"], sourceSize: CGSize(width: 200, height: 1200))
        let lines = OCRResultDisplayMode.originalLines.reviewRows(in: document, matching: "  BETA ")
        XCTAssertEqual(lines.map(\.id), [second.id])
        XCTAssertEqual(lines.first?.bounds, second.normalizedBounds)
        let paragraphs = OCRResultDisplayMode.paragraphs.reviewRows(in: document, matching: "Alpha")
        XCTAssertEqual(paragraphs.first?.bounds, block.normalizedBounds)
        XCTAssertEqual(OCRResultDisplayMode.originalLines.copyText(in: document), "\(first.text)\n\(second.text)")
    }

    func testLocatingAResultScrollsToTheCorrectPartOfTheOriginalImage() throws {
        _ = NSApplication.shared
        let view = OCRSourceViewport(image: image())
        view.frame = CGRect(x: 0, y: 0, width: 250, height: 180)
        view.layoutSubtreeIfNeeded()
        let bounds = CGRect(x: 0.1, y: 0.06, width: 0.3, height: 0.03)
        let w = view.contentView.bounds.width
        let canvas = CGRect(x: 0, y: 0, width: w, height: 6 * w)
        let mapped = try XCTUnwrap(OCRSourceViewport.region(bounds, in: canvas))
        XCTAssertEqual(mapped.minY, canvas.height * 0.91, accuracy: 0.001)
        XCTAssertEqual(mapped.minX, w * 0.1, accuracy: 0.001)
        XCTAssertFalse(view.documentVisibleRect.contains(mapped))
        let rowID = UUID()
        view.update(zoom: 1, location: OCRSourceLocation(rowID: rowID, bounds: bounds))
        XCTAssertTrue(view.documentVisibleRect.contains(mapped))
        view.contentView.scroll(to: .zero)
        view.update(zoom: 1, location: OCRSourceLocation(rowID: rowID, bounds: bounds))
        XCTAssertTrue(view.documentVisibleRect.contains(mapped))
    }

    private func image() -> CGImage {
        CGContext(data: nil, width: 200, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func findDragView(in view: NSView) -> WindowDragView? {
        if let drag = view as? WindowDragView { return drag }
        return view.subviews.lazy.compactMap { self.findDragView(in: $0) }.first
    }
}

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
        let frame = CGRect(x: 80, y: 80, width: 456, height: 486)
        let panel = controller.makeWindow(document: document, frame: frame) { _ in }
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
        let frame = CGRect(x: 80, y: 80, width: 456, height: 486)
        let panel = controller.makeWindow(document: document, frame: frame) { _ in }
        defer { panel.close() }
        let host = try XCTUnwrap(panel.contentView)

        XCTAssertTrue(panel.styleMask.contains([.titled, .resizable, .fullSizeContentView]))
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotEqual(panel.standardWindowButton(button)?.isHidden, false)
        }
        XCTAssertEqual(panel.contentMinSize, CGSize(width: 360, height: 250))
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(host.bounds.size, frame.size)

        let largerFrame = CGRect(x: 80, y: 80, width: 640, height: 600)
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
        XCTAssertEqual(frame.width, 456)
        XCTAssertEqual(frame.maxX, visible.maxX - 12)
        XCTAssertEqual(frame.minY, visible.minY + 12)
        XCTAssertEqual(frame.maxY, visible.maxY - 12)
    }

    private func findDragView(in view: NSView) -> WindowDragView? {
        if let drag = view as? WindowDragView { return drag }
        return view.subviews.lazy.compactMap { self.findDragView(in: $0) }.first
    }
}

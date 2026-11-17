import AppKit
import XCTest
import TapSnapScreen
@testable import TapSnapApp

@MainActor
final class SelectionFirstClickTests: XCTestCase {
    private func makeOverlay() -> (SelectionOverlayWindow, SelectionOverlayView) {
        _ = NSApplication.shared
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let screen = ScreenDescriptor(id: 1, frame: bounds, visibleFrame: bounds,
                                      scale: 1, isMain: true, localizedName: "Test")
        let window = SelectionOverlayWindow(screen: screen)
        window.isReleasedWhenClosed = false
        let view = SelectionOverlayView(frame: bounds)
        window.contentView = view
        window.makeFirstResponder(view)
        return (window, view)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 1, clickCount: 1, pressure: 1))
    }

    func testNonKeyOverlayAcceptsFirstPressAtHitView() throws {
        let (window, view) = makeOverlay()
        defer { window.contentView = nil; window.close() }
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.isVisible)
        let point = CGPoint(x: 80, y: 90)
        let hit = try XCTUnwrap(view.hitTest(point))
        XCTAssertTrue(hit === view)
        XCTAssertTrue(hit.acceptsFirstMouse(for: try mouse(.leftMouseDown, at: point, window: window)),
                      "未激活覆盖层的首击必须交给选区视图，不能只用于激活窗口")
        XCTAssertTrue(hit.needsPanelToBecomeKey, "点击的屏幕需要接收 Enter/Esc，而不是留给另一块屏幕")
    }

    func testFirstDragAndEnterAtHitViewConfirmSelection() throws {
        let (window, view) = makeOverlay()
        defer { window.contentView = nil; window.close() }
        let rect = CGRect(x: 80, y: 90, width: 160, height: 100)
        let hit = try XCTUnwrap(view.hitTest(rect.origin))
        let down = try mouse(.leftMouseDown, at: rect.origin, window: window)
        XCTAssertTrue(hit.acceptsFirstMouse(for: down))
        // 离屏窗口不运行系统激活路径；在真实命中对象上检查首轮交互与确认坐标。
        hit.mouseDown(with: down)
        hit.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: rect.maxX - 3, y: rect.maxY - 4), window: window))
        hit.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: rect.maxX, y: rect.maxY), window: window))
        let border = try XCTUnwrap(view.subviews.compactMap { $0 as? SelectionBorderView }.first)
        XCTAssertEqual(border.selectionRect, rect, "首轮按下、拖动、松开即应完成框选")
        var confirmed: CGRect?
        view.onFinish = { confirmed = $0 }
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: "\r", charactersIgnoringModifiers: "\r",
                                                 isARepeat: false, keyCode: 36))
        window.firstResponder?.keyDown(with: enter)
        XCTAssertEqual(confirmed, rect)
        XCTAssertFalse(window.isVisible, "测试不显示窗口或向系统发送输入")
    }

    func testFirstClickSnapsToSmallestDetectedRegion() throws {
        let (window, view) = makeOverlay()
        defer { window.contentView = nil; window.close() }
        let inner = CGRect(x: 80, y: 90, width: 160, height: 100)
        view.snapRegions = [view.bounds.insetBy(dx: 10, dy: 10), inner].map {
            SelectionSnapRegion(bounds: $0, confidence: 0.9)
        }
        let point = CGPoint(x: inner.midX, y: inner.midY)
        let hit = try XCTUnwrap(view.hitTest(point))
        let down = try mouse(.leftMouseDown, at: point, window: window)
        XCTAssertTrue(hit.acceptsFirstMouse(for: down))
        hit.mouseDown(with: down)
        hit.mouseUp(with: try mouse(.leftMouseUp, at: point, window: window))
        let border = try XCTUnwrap(view.subviews.compactMap { $0 as? SelectionBorderView }.first)
        XCTAssertEqual(border.selectionRect, inner)
    }

    func testHoverPreviewsFrontWindowAndClickKeepsThePreviewWhenDetectionArrives() throws {
        let (window, view) = makeOverlay()
        defer { view.stopBorderAnimation(); window.contentView = nil; window.close() }
        let front = CGRect(x: 100, y: 80, width: 200, height: 150)
        let back = CGRect(x: 25, y: 30, width: 300, height: 230)
        let point = CGPoint(x: 155, y: 130)
        view.windowRegions = [front, back]

        view.mouseMoved(with: try mouse(.mouseMoved, at: point, window: window))
        XCTAssertEqual(view.snapPreview, front)
        let border = try XCTUnwrap(view.subviews.compactMap { $0 as? SelectionBorderView }.first)
        XCTAssertNil(border.selectionRect, "悬停只预览，不能提前进入已选中状态")

        view.mouseDown(with: try mouse(.leftMouseDown, at: point, window: window))
        view.snapRegions = [SelectionSnapRegion(bounds: CGRect(x: 130, y: 110, width: 60, height: 40), confidence: 1)]
        view.mouseUp(with: try mouse(.leftMouseUp, at: point, window: window))
        XCTAssertEqual(border.selectionRect, front)
        XCTAssertNil(view.snapPreview)
    }

    func testSnapPrefersCredibleControlInsideFrontWindow() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let front = CGRect(x: 100, y: 80, width: 200, height: 150)
        let point = CGPoint(x: 155, y: 130)
        let crossing = SelectionSnapRegion(bounds: CGRect(x: 75, y: 110, width: 90, height: 35), confidence: 1)
        let tiny = SelectionSnapRegion(bounds: CGRect(x: 150, y: 125, width: 10, height: 10), confidence: 1)
        let weak = SelectionSnapRegion(bounds: CGRect(x: 140, y: 115, width: 30, height: 25), confidence: 0.7)
        let control = SelectionSnapRegion(bounds: CGRect(x: 120, y: 100, width: 100, height: 65), confidence: 0.95)
        let noise = [crossing, tiny]

        XCTAssertEqual(SelectionSnap.target(at: point, in: bounds, windows: [front, bounds], detected: noise), front)
        XCTAssertEqual(SelectionSnap.target(at: point, in: bounds, windows: [front, bounds],
                                           detected: noise + [weak, control]), control.bounds)
        XCTAssertNil(SelectionSnap.target(at: CGPoint(x: 60, y: 60), in: bounds, windows: [front], detected: []))
    }

    func testSemanticHoverRefinesThePreviewBeforeClick() async throws {
        let (window, view) = makeOverlay()
        defer { view.stopBorderAnimation(); window.contentView = nil; window.close() }
        let control = CGRect(x: 55, y: 60, width: 84, height: 30)
        let point = CGPoint(x: control.midX, y: control.midY)
        view.windowRegions = [view.bounds.insetBy(dx: 10, dy: 10)]
        view.accessibilitySnapLookup = { _ in control }

        view.mouseMoved(with: try mouse(.mouseMoved, at: point, window: window))
        for _ in 0..<50 where view.snapPreview != control {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(view.snapPreview, control)
        view.mouseDown(with: try mouse(.leftMouseDown, at: point, window: window))
        view.mouseUp(with: try mouse(.leftMouseUp, at: point, window: window))
        let border = try XCTUnwrap(view.subviews.compactMap { $0 as? SelectionBorderView }.first)
        XCTAssertEqual(border.selectionRect, control)
    }
}

import AppKit
import QuartzCore
import XCTest
import TapSnapConfig
@testable import TapSnapApp

@MainActor
final class AuroraSelectionBorderTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 240)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: bounds)
        return window
    }

    private func animationCount(in layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return (layer.animationKeys()?.count ?? 0)
            + (layer.sublayers ?? []).reduce(0) { $0 + animationCount(in: $1) }
    }

    private func animatedBorder(in window: NSWindow) throws -> SelectionBorderView {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("系统已启用减少动态效果，保持此设置，不验证动画开启")
        }
        let content = try XCTUnwrap(window.contentView)
        let border = SelectionBorderView(frame: content.bounds)
        content.addSubview(border)
        border.selectionRect = CGRect(x: 60, y: 75, width: 140, height: 90)
        XCTAssertGreaterThan(animationCount(in: border.layer), 0)
        XCTAssertFalse(window.isVisible, "生命周期测试不得显示窗口")
        return border
    }

    func testNoSelectionAndTinySelectionHideBorder() throws {
        let window = makeWindow()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let border = SelectionBorderView(frame: content.bounds)
        content.addSubview(border)
        XCTAssertEqual(border.layer?.isHidden, true)
        XCTAssertEqual(animationCount(in: border.layer), 0)
        border.selectionRect = CGRect(x: 60, y: 75, width: 140, height: 90)
        XCTAssertEqual(border.layer?.isHidden, false)
        border.selectionRect = CGRect(x: 60, y: 75, width: 0, height: 90)
        XCTAssertEqual(border.layer?.isHidden, true)
        XCTAssertEqual(animationCount(in: border.layer), 0)
        border.selectionRect = nil
        XCTAssertEqual(border.layer?.isHidden, true)
        XCTAssertEqual(animationCount(in: border.layer), 0)
        XCTAssertFalse(window.isVisible)
    }

    func testDetachingStopsAnimationsAndReattachingRestarts() throws {
        let window = makeWindow()
        defer { window.close() }
        let border = try animatedBorder(in: window)
        border.removeFromSuperview()
        XCTAssertNil(border.window)
        XCTAssertEqual(animationCount(in: border.layer), 0)
        window.contentView?.addSubview(border)
        XCTAssertGreaterThan(animationCount(in: border.layer), 0)
    }

    func testStopRemovesAnimationsAndLaterSelectionDoesNotRestartThem() throws {
        let window = makeWindow()
        defer { window.close() }
        let border = try animatedBorder(in: window)
        border.stopAnimating()
        XCTAssertEqual(animationCount(in: border.layer), 0)
        border.selectionRect = CGRect(x: 70, y: 80, width: 150, height: 100)
        border.isPaused = true
        border.isPaused = false
        border.removeFromSuperview()
        window.contentView?.addSubview(border)
        XCTAssertEqual(animationCount(in: border.layer), 0, "结束后更新几何或重新挂载不能重启动画")
    }

    func testPauseStopsAnimationsAndResumeRestarts() throws {
        let window = makeWindow()
        defer { window.close() }
        let border = try animatedBorder(in: window)
        border.isPaused = true
        XCTAssertEqual(animationCount(in: border.layer), 0)
        XCTAssertLessThan(try XCTUnwrap(border.layer).opacity, 1)
        border.isPaused = false
        XCTAssertGreaterThan(animationCount(in: border.layer), 0)
        XCTAssertEqual(border.layer?.opacity, 1)
    }

    func testCoolWhiteSweepMakesOneLapAndStopsOnStyleChangeOrPause() throws {
        let window = makeWindow()
        defer { window.close() }
        let border = try animatedBorder(in: window)
        border.style = .coolWhiteSweep
        let outline = SelectionBorderView.outlineRect(for: try XCTUnwrap(border.selectionRect), in: border.bounds)
        let layers = try XCTUnwrap(border.layer?.sublayers)
        let sweeps = layers.compactMap { $0 as? CAShapeLayer }.filter { $0.animation(forKey: "borderSweep") != nil }
        XCTAssertEqual(sweeps.count, 3)
        for sweep in sweeps {
            let dash = try XCTUnwrap(sweep.lineDashPattern)
            XCTAssertEqual(dash.reduce(0) { $0 + $1.doubleValue },
                           2 * (outline.width + outline.height - 8 + 2 * .pi), accuracy: 0.01)
        }
        XCTAssertEqual(animationCount(in: border.layer), sweeps.count)
        border.isPaused = true
        XCTAssertEqual(animationCount(in: border.layer), 0)
        border.isPaused = false
        XCTAssertEqual(animationCount(in: border.layer), sweeps.count)
        for style in SelectionBorderStyle.allCases where style != .aurora && style != .coolWhiteSweep {
            border.style = style
            XCTAssertEqual(animationCount(in: border.layer), 0, style.displayName)
        }
        border.style = .coolWhiteSweep
        XCTAssertEqual(animationCount(in: border.layer), sweeps.count)
        border.removeFromSuperview()
        XCTAssertEqual(animationCount(in: border.layer), 0)
    }
}

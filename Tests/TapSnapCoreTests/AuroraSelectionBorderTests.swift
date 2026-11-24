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

    func testAllSevenFamiliesAndMotionsAnimateCleanlyAndRespectPause() throws {
        let window = makeWindow()
        defer { window.close() }
        let border = try animatedBorder(in: window)

        for style in SelectionBorderStyle.allCases {
            for motion in style.availableMotions {
                let palette = style.availablePalettes.first ?? .glacier
                border.configuration = SelectionBorderConfiguration(style: style, motion: motion, palette: palette)
                XCTAssertEqual(animationCount(in: border.layer), 1, "\(style.displayName)-\(motion.displayName)")
            }
        }

        // 验证离屏渲染不会把任何像素画进选区内部（严格裁剪在外部）。
        let rect = CGRect(x: 32, y: 32, width: 120, height: 80)
        let bounds = rect.insetBy(dx: -24, dy: -24)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        for style in SelectionBorderStyle.allCases {
            let ctx = try XCTUnwrap(CGContext(
                data: nil, width: Int(bounds.width), height: Int(bounds.height),
                bitsPerComponent: 8, bytesPerRow: Int(bounds.width) * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            SelectionBorderArtwork.drawAnimatedBorder(
                SelectionBorderConfiguration(style: style),
                around: CGRect(x: 24, y: 24, width: rect.width, height: rect.height),
                in: CGRect(origin: .zero, size: bounds.size),
                phase: 0.28,
                context: ctx
            )
            let data = try XCTUnwrap(ctx.data)
            let centerOffset = (Int(bounds.height / 2) * Int(bounds.width) + Int(bounds.width / 2)) * 4
            let centerAlpha = data.load(fromByteOffset: centerOffset + 3, as: UInt8.self)
            XCTAssertEqual(centerAlpha, 0, "\(style.displayName) 不应染色选区中心像素")
        }

        border.isPaused = true
        XCTAssertEqual(animationCount(in: border.layer), 0)
        border.isPaused = false
        XCTAssertEqual(animationCount(in: border.layer), 1)
        border.removeFromSuperview()
        XCTAssertEqual(animationCount(in: border.layer), 0)
    }
}

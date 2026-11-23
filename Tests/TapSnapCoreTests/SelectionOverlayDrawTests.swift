import AppKit
import CoreGraphics
import XCTest
import TapSnapConfig
import TapSnapScreen
@testable import TapSnapApp

/// 选区覆盖层的绘制回归测试。
///
/// 这里曾经有一条会直接崩掉进程的路径：覆盖层用
/// `NSAttributedString.size()/draw(at:)` 画尺寸标签，CoreText 在构造字体属性字典时
/// 插入了 nil 字体。现在统一走 CoreText，这个测试保证「画一遍不会崩」。
@MainActor
final class SelectionOverlayDrawTests: XCTestCase {
    private func makeScreenImage(width: Int = 200, height: Int = 150) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = 90
            bytes[index + 1] = 160
            bytes[index + 2] = 220
            bytes[index + 3] = 255
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

    private func render(_ view: NSView, width: Int, height: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        // 不显示窗口，只让 AppKit 按真实子视图层级绘制，包括前景 CoreText 控件。
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func dragSelection(in view: SelectionOverlayView, rect: CGRect) throws {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, rect.origin),
                              (.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY)),
                              (.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY))] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                       timestamp: 0, windowNumber: 0, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }

    private func whitePixelCount(in rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.9, color.redComponent > 0.9,
                   color.greenComponent > 0.9, color.blueComponent > 0.9 { count += 1 }
            }
        }
        return count
    }

    func testDrawWithUserSelectionDoesNotCrash() throws {
        _ = NSApplication.shared

        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 240))
        view.screenImage = makeScreenImage(width: 300, height: 240)
        view.showsSizeLabel = true
        try dragSelection(in: view, rect: CGRect(x: 60, y: 75, width: 140, height: 90))

        let withLabel = render(view, width: 300, height: 240)
        view.showsSizeLabel = false
        view.needsDisplay = true
        let withoutLabel = render(view, width: 300, height: 240)

        // 尺寸文字在前景子视图中；只画父视图会漏掉 CoreText 回归路径。
        XCTAssertGreaterThan(whitePixelCount(in: withLabel), whitePixelCount(in: withoutLabel) + 5,
                             "必须实际绘制尺寸文字，不能只画背景而让测试假通过")
    }

    func testDrawWithoutSelectionDoesNotCrash() {
        _ = NSApplication.shared

        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        view.screenImage = makeScreenImage()

        _ = render(view, width: 200, height: 150)
    }

    func testScreenshotSelectionKeepsTheUndimmedCapturedPixelsWhileLiveSelectionStaysTransparent() throws {
        _ = NSApplication.shared
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        let image = makeScreenImage()
        view.screenImage = image
        view.showsSizeLabel = false
        // 跨屏选区在当前覆盖层中可以从负坐标开始。
        view.synchronizeSelection(CGRect(x: -40, y: 30, width: 200, height: 90), showToolbar: false)
        view.showsFrozenSelection = true
        let frozen = render(view, width: 200, height: 150)
        let expected = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 95, y: 75)?.usingColorSpace(.deviceRGB))
        let inside = try XCTUnwrap(frozen.colorAt(x: 95, y: 75)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(inside.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(inside.redComponent, expected.redComponent, accuracy: 0.02)
        XCTAssertEqual(inside.greenComponent, expected.greenComponent, accuracy: 0.02)
        XCTAssertEqual(inside.blueComponent, expected.blueComponent, accuracy: 0.02)
        let outside = try XCTUnwrap(frozen.colorAt(x: 190, y: 75)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(outside.blueComponent, inside.blueComponent - 0.1)

        view.showsFrozenSelection = false
        let live = render(view, width: 200, height: 150)
        XCTAssertEqual(try XCTUnwrap(live.colorAt(x: 95, y: 75)).alphaComponent, 0, accuracy: 0.01)
    }

    func testDrawWithMagnifierSettingsOffDoesNotCrash() throws {
        _ = NSApplication.shared

        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        view.screenImage = makeScreenImage()
        view.showsMagnifier = false
        view.showsSizeLabel = false
        try dragSelection(in: view, rect: CGRect(x: 20, y: 20, width: 50, height: 50))

        _ = render(view, width: 200, height: 150)
    }

    func testFreshCaptureCannotConfirmPreviousSelection() throws {
        _ = NSApplication.shared
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "\r", charactersIgnoringModifiers: "\r",
                                                 isARepeat: false, keyCode: 36))
        let previous = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 150))
        let rect = CGRect(x: 20, y: 20, width: 50, height: 50)
        try dragSelection(in: previous, rect: rect)
        var results: [CGRect?] = []
        previous.onFinish = { results.append($0) }
        previous.keyDown(with: enter)
        XCTAssertEqual(results, [rect])

        let fresh = SelectionOverlayView(frame: previous.frame)
        fresh.onFinish = { results.append($0) }
        fresh.keyDown(with: enter)
        XCTAssertEqual(results.count, 2)
        XCTAssertNil(results.last!)
    }

    func testHitTestingPassesThroughBorderAndControls() throws {
        _ = NSApplication.shared
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 240))
        try dragSelection(in: view, rect: CGRect(x: 60, y: 75, width: 140, height: 90))
        for y in stride(from: 5, to: 240, by: 10) {
            for x in stride(from: 5, to: 300, by: 10) {
                let point = CGPoint(x: x, y: y)
                XCTAssertTrue(view.hitTest(point) === view, "光晕及提示层不应截获鼠标：\(point)")
            }
        }
        XCTAssertNil(view.hitTest(CGPoint(x: -1, y: -1)))
    }

    func testMovingSelectionStillConfirmsOriginalPixelRegion() throws {
        _ = NSApplication.shared
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 240))
        let original = CGRect(x: 60, y: 75, width: 140, height: 90)
        try dragSelection(in: view, rect: original)
        let border = try XCTUnwrap(view.subviews.compactMap { $0 as? SelectionBorderView }.first)
        XCTAssertEqual(border.selectionRect, original)
        try dragSelection(in: view, rect: CGRect(x: original.midX, y: original.midY, width: 15, height: 10))
        let expected = original.offsetBy(dx: 15, dy: 10)
        XCTAssertEqual(border.selectionRect, expected, "装饰边距不能改变实际选区")
        var results: [CGRect?] = []
        view.onFinish = { results.append($0) }
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "\r", charactersIgnoringModifiers: "\r",
                                                 isARepeat: false, keyCode: 36))
        view.keyDown(with: enter)
        XCTAssertEqual(results, [expected], "确认回调必须返回用户选区，不能返回光晕外框")
    }

    func testOuterRightHandleChangesWidthOnlyByDraggedDistance() throws {
        _ = NSApplication.shared
        let view = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 240))
        let original = CGRect(x: 60, y: 75, width: 140, height: 90)
        try dragSelection(in: view, rect: original)
        let outline = SelectionBorderView.outlineRect(for: original, in: view.bounds)
        let handle = CGPoint(x: outline.maxX, y: outline.midY)
        XCTAssertTrue(view.hitTest(handle) === view)
        try dragSelection(in: view, rect: CGRect(origin: handle, size: CGSize(width: 20, height: 0)))
        var result: CGRect?
        view.onFinish = { result = $0 }
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "\r", charactersIgnoringModifiers: "\r",
                                                 isARepeat: false, keyCode: 36))
        view.keyDown(with: enter)
        XCTAssertEqual(result, CGRect(x: original.minX, y: original.minY,
                                      width: original.width + 20, height: original.height),
                       "拖动外框20点只能改变真实宽度20点，不能额外计入装饰边距")
    }

    func testDecorativeMarginDoesNotEnlargeConfirmedCrop() throws {
        _ = NSApplication.shared
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 240)
        let image = makeScreenImage(width: 300, height: 240)
        let selected = CGRect(x: 60, y: 75, width: 140, height: 90)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "\r", charactersIgnoringModifiers: "\r",
                                                 isARepeat: false, keyCode: 36))
        let screen = ScreenDescriptor(id: 1, frame: bounds, visibleFrame: bounds,
                                      scale: 1, isMain: true, localizedName: "Test")
        for style in SelectionBorderStyle.allCases {
            let view = SelectionOverlayView(frame: bounds)
            view.screenImage = image
            view.borderStyle = style
            try dragSelection(in: view, rect: selected)

            let outline = SelectionBorderView.outlineRect(for: selected, in: view.bounds)
            let handle = CGPoint(x: outline.maxX, y: outline.midY)
            XCTAssertTrue(view.hitTest(handle) === view, style.displayName)
            try dragSelection(in: view, rect: CGRect(origin: handle, size: CGSize(width: 20, height: 0)))
            var confirmed: CGRect?
            view.onFinish = { confirmed = $0 }
            view.keyDown(with: enter)
            let result = try XCTUnwrap(confirmed)
            XCTAssertEqual(result, CGRect(x: selected.minX, y: selected.minY, width: 160, height: 90), style.displayName)

            var session = ScreenshotSession(mode: .region)
            session.frames = [CapturedFrame(screen: screen, image: image)]
            session.targetScreen = screen
            session.selectionRect = CGRect(x: result.minX, y: bounds.height - result.maxY,
                                           width: result.width, height: result.height)
            let cropped = try XCTUnwrap(session.croppedImage())
            XCTAssertEqual(cropped.width, 160, style.displayName)
            XCTAssertEqual(cropped.height, 90, style.displayName)
        }
    }
}

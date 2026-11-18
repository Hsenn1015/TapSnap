import AppKit
import TapSnapConfig
import TapSnapImageIO
import TapSnapScreen
import XCTest
@testable import TapSnapApp

@MainActor
final class ScreenshotWorkflowTests: XCTestCase {
    private func bitmap(_ width: Int, _ height: Int, _ paint: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        paint(context)
        return try XCTUnwrap(context.makeImage())
    }

    private func frame(_ id: UInt32, _ x: Int, _ y: Int, scale: Int, red: Bool) throws -> CapturedFrame {
        let rect = CGRect(x: x, y: y, width: 8, height: 8)
        let screen = ScreenDescriptor(id: id, frame: rect, visibleFrame: rect, scale: CGFloat(scale),
                                      isMain: id == 1, localizedName: "屏幕 \(id)")
        let size = 8 * scale
        return try CapturedFrame(screen: screen, image: bitmap(size, size) { context in
            context.setFillColor(red ? NSColor.red.cgColor : NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        })
    }

    func test左右双向框选在混合分辨率屏幕的接缝处像素连续() throws {
        let left = try frame(1, -8, 0, scale: 1, red: true)
        let right = try frame(2, 0, 0, scale: 2, red: false)
        for origin in [left, right] {
            var session = ScreenshotSession(mode: .region)
            session.frames = [right, left]
            session.select(viewRect: CGRect(x: -2 - origin.screen.frame.minX, y: 1, width: 6, height: 3), on: origin.screen)
            let result = try XCTUnwrap(session.croppedImage())
            XCTAssertEqual(result.width, 12)
            XCTAssertEqual(result.height, 6)
            let image = NSBitmapImageRep(cgImage: result)
            for y in 0..<6 {
                XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x: 3, y: y)).redComponent, 0.99)
                XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x: 4, y: y)).blueComponent, 0.99)
            }
        }
    }

    func test上下错位屏幕按桌面方向拼接并保留透明空隙() throws {
        let top = try frame(1, 3, -8, scale: 1, red: true)
        let bottom = try frame(2, 0, 0, scale: 1, red: false)
        var session = ScreenshotSession(mode: .region)
        session.frames = [bottom, top]
        session.targetScreen = bottom.screen
        session.selectionRect = CGRect(x: 1, y: -3, width: 7, height: 5)
        let result = try XCTUnwrap(session.croppedImage())
        let image = NSBitmapImageRep(cgImage: result)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 0, y: 0)).alphaComponent, 0)
        XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x: 3, y: 2)).redComponent, 0.99)
        XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x: 3, y: 3)).blueComponent, 0.99)
    }

    func test时间水印使用截屏时刻且支持仅日期() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2020-10-04T12:36:45Z"))
        var options = EditToolOptions()
        options.watermarkKind = .timestamp
        options.captureDate = date
        let mark = try XCTUnwrap(EditItemFactory.make(kind: .watermark, from: .zero, to: .zero,
            style: EditItemStyle(), options: options) as? WatermarkItem)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertEqual(mark.displayText, formatter.string(from: date))
        options.watermarkIncludesTime = false
        options.apply(to: mark)
        XCTAssertEqual(mark.displayText, String(formatter.string(from: date).prefix(10)))
    }

    func test透明图片水印等比缩放并保留方向和透明度() throws {
        let blank = try bitmap(40, 40) { _ in }
        let logo = try bitmap(4, 2) { c in
            c.setFillColor(NSColor.red.cgColor)
            c.fill(CGRect(x: 0, y: 1, width: 2, height: 1))
        }
        var options = EditToolOptions()
        options.watermarkKind = .image
        options.watermarkImage = try ImageCodec.decode(ImageCodec.encode(logo, as: .png))
        let item = try XCTUnwrap(EditItemFactory.make(kind: .watermark, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 36, y: 36),
            style: EditItemStyle(opacity: 0.5), options: options))
        let result = try EditDocument(baseImage: blank, items: [item]).render()
        let pixels = NSBitmapImageRep(cgImage: try ImageCodec.decode(ImageCodec.encode(result, as: .png)))
        XCTAssertEqual(try XCTUnwrap(pixels.colorAt(x: 8, y: 14)).alphaComponent, 0.5, accuracy: 0.02)
        for (x, y) in [(8, 5), (30, 15), (8, 26), (8, 34)] {
            XCTAssertEqual(try XCTUnwrap(pixels.colorAt(x: x, y: y)).alphaComponent, 0, accuracy: 0.02)
        }
    }

    func test剪贴板分类保持原有时间顺序() throws {
        let image = try bitmap(2, 2) { _ in }
        let entries: [ClipboardHistory.Entry] = [.image(image), .text("二"), .image(image), .text("一")]
            .enumerated().map { .init(date: Date(timeIntervalSince1970: Double(100 - $0.offset)), content: $0.element) }
        XCTAssertEqual(entries.filter(ClipboardHistory.Filter.all.includes).map(\.id), entries.map(\.id))
        XCTAssertEqual(entries.filter(ClipboardHistory.Filter.images.includes).map(\.id), [entries[0].id, entries[2].id])
        XCTAssertEqual(entries.filter(ClipboardHistory.Filter.text.includes).map(\.id), [entries[1].id, entries[3].id])
    }

    func test最近普通截图保留编辑对象而隐私截图只恢复已复查的成图() throws {
        let image = try bitmap(8, 8) { _ in }
        let env = AppEnvironment(config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")))
        let doc = EditDocument(baseImage: image, scale: 1)
        env.rememberCapture(doc, privateCapture: false)
        doc.append(ArrowItem(start: .zero, end: CGPoint(x: 4, y: 4)))
        doc.cropRect = CGRect(x: 1, y: 2, width: 5, height: 3)
        XCTAssertEqual(env.recentScreenshot?.items.first?.id, doc.items.first?.id)
        XCTAssertEqual(env.recentScreenshot?.cropRect, doc.cropRect)
        env.protectOriginal(doc)
        XCTAssertNil(env.recentScreenshot)
        env.rememberReviewedImage(try doc.render(), from: doc)
        XCTAssertEqual(env.recentScreenshot?.items.count, 0)
        XCTAssertEqual(env.recentScreenshot?.baseImage.width, 5)
        XCTAssertEqual(env.recentScreenshot?.capturedAt, doc.capturedAt)
        let newer = EditDocument(baseImage: image)
        env.rememberCapture(newer, privateCapture: true)
        env.rememberReviewedImage(image, from: doc)
        XCTAssertNil(env.recentScreenshot)
    }

    func test手动保存可连续选择两个目录且取消后仍能自动保存() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ConfigStore(fileURL: root.appendingPathComponent("settings.json"))
        let automatic = root.appendingPathComponent("默认", isDirectory: true)
        config.update { $0.capture.saveDirectory = automatic.path; $0.capture.saveFormat = "png" }
        var destination: URL?
        let env = AppEnvironment(config: config) { format, directory in
            XCTAssertEqual(format, .png)
            XCTAssertEqual(directory.path, automatic.path)
            return destination
        }
        let source = try bitmap(18, 12) { _ in }
        let doc = EditDocument(baseImage: source)
        env.rememberCapture(doc, privateCapture: false)
        XCTAssertFalse(env.saveScreenshot(source, chooseLocation: true))
        XCTAssertTrue(env.recentScreenshot === doc)
        for name in ["甲", "乙"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(name)图.png")
            destination = url
            XCTAssertTrue(env.saveScreenshot(source, chooseLocation: true))
            let image = try ImageCodec.decode(Data(contentsOf: url))
            XCTAssertEqual(image.width, 18)
            XCTAssertEqual(image.height, 12)
        }
        XCTAssertEqual(config.settings.capture.saveDirectory, automatic.path)
        XCTAssertTrue(env.saveScreenshot(source))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: automatic.path).filter { $0.hasSuffix(".png") }.count, 1)
    }

    func test精确导出按宽高或长边等比缩放且可回读实际像素() throws {
        let original = try bitmap(24, 12) { _ in }
        for (axis, pixels) in [(ScreenshotRaster.Axis.width, 10), (.height, 5), (.longest, 10)] {
            let output = try ScreenshotRaster.resized(original, axis: axis, pixels: pixels)
            let data = try ImageCodec.encode(output, as: .png)
            let image = try ImageCodec.decode(data)
            XCTAssertEqual(image.width, 10)
            XCTAssertEqual(image.height, 5)
            XCTAssertGreaterThan(data.count, 0)
        }
        XCTAssertThrowsError(try ScreenshotRaster.resized(original, axis: .width, pixels: -1))
        XCTAssertThrowsError(try ScreenshotRaster.resized(original, axis: .width, pixels: 999_999))
    }

    func test拼接可交换顺序并在两种方向保留原图像素() throws {
        let red = try frame(1, 0, 0, scale: 1, red: true).image
        let blue = try frame(2, 0, 0, scale: 2, red: false).image
        for vertical in [true, false] {
            for swapped in [true, false] {
                let first = swapped ? blue : red, second = swapped ? red : blue
                let result = try ScreenshotRaster.combine(first, second, vertical: vertical)
                XCTAssertEqual(result.width, vertical ? 16 : 24)
                XCTAssertEqual(result.height, vertical ? 24 : 16)
                let image = NSBitmapImageRep(cgImage: result)
                let before = try XCTUnwrap(image.colorAt(x: 0, y: 0))
                let after = try XCTUnwrap(image.colorAt(x: vertical ? 0 : first.width, y: vertical ? first.height : 0))
                XCTAssertGreaterThan(swapped ? before.blueComponent : before.redComponent, 0.99)
                XCTAssertGreaterThan(swapped ? after.redComponent : after.blueComponent, 0.99)
            }
        }
    }

    func test固定比例裁剪保留拖动起点和画布边界() {
        let area = CGRect(x: 2, y: 8, width: 80, height: 30)
        for aspect in [EditController.CropAspect.square, .classic, .wide, .portrait] {
            let forward = aspect.fit(area, anchoredAt: area.origin)
            let reverse = aspect.fit(area, anchoredAt: CGPoint(x: area.maxX, y: area.maxY))
            XCTAssertEqual(forward.origin, area.origin)
            XCTAssertEqual(reverse.maxX, area.maxX, accuracy: 0.001)
            XCTAssertEqual(reverse.maxY, area.maxY, accuracy: 0.001)
            XCTAssertEqual(forward.size, reverse.size)
            XCTAssertTrue(area.contains(forward))
        }
    }

    func test实机双屏框选编辑复制和保存() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAPSNAP_TEST_DUAL_DISPLAY"] == "1",
                          "此用例会短暂显示测试色块和截图选区")
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "需要已有的屏幕录制权限")
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        guard let left = screens.first, let right = screens.dropFirst().first(where: {
            abs(left.frame.maxX - $0.frame.minX) < 1 &&
                min(left.frame.maxY, $0.frame.maxY) - max(left.frame.minY, $0.frame.minY) > 160
        }) else { throw XCTSkip("需要左右相邻的两块实体显示器") }
        let x = left.frame.maxX
        let y = floor((min(left.frame.maxY, right.frame.maxY) + max(left.frame.minY, right.frame.minY)) / 2)
        let scale = max(left.backingScaleFactor, right.backingScaleFactor)
        let cards = [(x - 120, NSColor.red), (x, NSColor.blue)].map { edge, color in
            let window = NSWindow(contentRect: CGRect(x: edge, y: y - 80, width: 120, height: 160),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.backgroundColor = color
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.orderFrontRegardless()
            return window
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = ConfigStore(fileURL: root.appendingPathComponent("settings.json"))
        config.update { $0.privacy.enabled = false; $0.capture.autoCopyToClipboard = false }
        var destination: URL?
        let env = AppEnvironment(config: config) { _, _ in destination }
        let clipboard = NSPasteboard.withUniqueName()
        defer {
            env.captureCoordinator.cancel()
            for window in NSApp.windows where (window.delegate as? EditController)?.environment === env { window.close() }
            cards.forEach { $0.close() }
            clipboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        try await Task.sleep(for: .milliseconds(240))
        for reverse in [false, true] {
            let previous = env.recentScreenshot?.id
            env.captureCoordinator.start(.edit)
            let startScreen = reverse ? right : left
            func overlay(on screen: NSScreen) -> SelectionOverlayWindow? {
                NSApp.windows.compactMap { $0 as? SelectionOverlayWindow }.first { $0.isVisible && $0.frame == screen.frame }
            }
            for _ in 0..<150 where overlay(on: left) == nil || overlay(on: right) == nil {
                try await Task.sleep(for: .milliseconds(40))
            }
            let window = try XCTUnwrap(overlay(on: startScreen))
            let view = try XCTUnwrap(window.contentView as? SelectionOverlayView)
            let peer = try XCTUnwrap(overlay(on: reverse ? left : right)?.contentView as? SelectionOverlayView)
            let first = CGPoint(x: x - 48, y: y - 24), second = CGPoint(x: x + 48, y: y + 24)
            func mouse(_ type: NSEvent.EventType, _ at: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: at), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            view.mouseDown(with: try mouse(.leftMouseDown, reverse ? second : first))
            view.mouseDragged(with: try mouse(.leftMouseDragged, reverse ? first : second))
            view.mouseUp(with: try mouse(.leftMouseUp, reverse ? first : second))
            XCTAssertNil(view.quickToolbarLayout())
            XCTAssertNotNil(peer.quickToolbarLayout(), "工具栏应在松手屏幕上")
            view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36)))
            for _ in 0..<80 where env.recentScreenshot?.id == previous {
                try await Task.sleep(for: .milliseconds(40))
            }
            let doc = try XCTUnwrap(env.recentScreenshot)
            XCTAssertNotEqual(doc.id, previous)
            XCTAssertEqual(doc.baseImage.width, Int(96 * scale))
            XCTAssertEqual(doc.baseImage.height, Int(48 * scale))
            let result = try doc.render()
            let url = root.appendingPathComponent(reverse ? "从右到左.png" : "从左到右.png")
            destination = url
            XCTAssertTrue(env.saveScreenshot(result, chooseLocation: true))
            XCTAssertTrue(env.pinTransfer.copy(result, to: clipboard))
            for readback in [try ImageCodec.decode(Data(contentsOf: url)), try XCTUnwrap(env.pinTransfer.image(from: clipboard))] {
                let pixels = NSBitmapImageRep(cgImage: readback)
                let mid = readback.width / 2
                XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: mid - 3, y: 15)?.usingColorSpace(.sRGB)).redComponent, 0.85)
                XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: mid + 3, y: 15)?.usingColorSpace(.sRGB)).blueComponent, 0.85)
            }
            for window in NSApp.windows where (window.delegate as? EditController)?.environment === env { window.close() }
        }
    }
}

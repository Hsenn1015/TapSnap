import AppKit
import XCTest
import TapSnapCore
import TapSnapImageIO
import TapSnapScreen
@testable import TapSnapApp

final class CaptureModeHandoffTests: XCTestCase {
    private func screen(origin: CGPoint, scale: CGFloat) -> ScreenDescriptor {
        let frame = CGRect(origin: origin, size: CGSize(width: 400, height: 300))
        return ScreenDescriptor(id: 42, frame: frame, visibleFrame: frame,
                                scale: scale, isMain: false, localizedName: "Test")
    }

    private func image(for screen: ScreenDescriptor, color: CGColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(screen.pixelSize.width),
                                            height: Int(screen.pixelSize.height), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(origin: .zero, size: screen.pixelSize))
        return try XCTUnwrap(context.makeImage())
    }

    func testSameSelectedRegionTransfersToLongShotAndRecordingOnOffsetScreens() throws {
        let selected = CGRect(x: 40, y: 60, width: 120, height: 80)
        for origin in [CGPoint.zero, CGPoint(x: -400, y: -300), CGPoint(x: 1920, y: 200)] {
            for scale: CGFloat in [1, 2] {
                let screen = screen(origin: origin, scale: scale)
                var session = ScreenshotSession(mode: .region)
                let frame = try image(for: screen, color: CGColor(gray: 1, alpha: 1))
                session.frames = [CapturedFrame(screen: screen, image: frame)]
                session.select(viewRect: selected, on: screen)
                let global = try XCTUnwrap(session.selectionRect)
                let expectedLocal = CGRect(x: 40, y: 160, width: 120, height: 80)
                XCTAssertEqual(global, expectedLocal.offsetBy(dx: origin.x, dy: origin.y))
                XCTAssertEqual(Geometry.localRect(global, in: screen.frame), expectedLocal,
                               "录屏应使用同一选区的屏幕内坐标")
                let screenshot = try XCTUnwrap(session.croppedImage())
                let longshot = try XCTUnwrap(LongShotSession.cropFrame(frame, rect: global, screen: screen))
                XCTAssertEqual(screenshot.width, Int(selected.width * scale))
                XCTAssertEqual(screenshot.height, Int(selected.height * scale))
                XCTAssertEqual(longshot.width, screenshot.width)
                XCTAssertEqual(longshot.height, screenshot.height)
            }
        }
    }

    func testFreshLongShotFrameReplacesOrdinaryCaptureWithoutChangingSelection() throws {
        let screen = screen(origin: CGPoint(x: -400, y: 150), scale: 2)
        var session = ScreenshotSession(mode: .region)
        session.frames = [CapturedFrame(screen: screen, image: try image(for: screen, color: CGColor(gray: 0, alpha: 1)))]
        session.select(viewRect: CGRect(x: 40, y: 60, width: 120, height: 80), on: screen)
        let originalSelection = session.selectionRect
        let sessionID = session.id
        let oldCrop = try XCTUnwrap(session.croppedImage())
        // 重新采集的是同一屏的干净首帧；选区和会话身份不会被重建。
        session.frames = [CapturedFrame(screen: screen, image: try image(for: screen, color: CGColor(gray: 1, alpha: 1)))]
        let newCrop = try XCTUnwrap(session.croppedImage())
        XCTAssertEqual(session.selectionRect, originalSelection)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(newCrop.width, oldCrop.width)
        XCTAssertEqual(newCrop.height, oldCrop.height)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: newCrop).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
    }

    func testLatestAdjustedSelectionIsUsedForTheHandoff() {
        let screen = screen(origin: CGPoint(x: -400, y: 0), scale: 2)
        var session = ScreenshotSession(mode: .region)
        session.select(viewRect: CGRect(x: 10, y: 10, width: 50, height: 40), on: screen)
        session.select(viewRect: CGRect(x: 80, y: 70, width: 180, height: 100), on: screen)
        XCTAssertEqual(session.selectionRect, CGRect(x: -320, y: 130, width: 180, height: 100))
        XCTAssertEqual(session.targetScreen, screen)
    }

    func testQuickCopyWritesOnlyTheSelectedPixelsToThePasteboard() throws {
        let screen = screen(origin: CGPoint(x: -400, y: 150), scale: 2)
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 80, y: 120, width: 240, height: 160))
        var session = ScreenshotSession(mode: .region)
        session.frames = [CapturedFrame(screen: screen, image: try XCTUnwrap(context.makeImage()))]
        session.select(viewRect: CGRect(x: 40, y: 60, width: 120, height: 80), on: screen)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(AppEnvironment().pinTransfer.copy(try XCTUnwrap(session.croppedImage()), to: board))
        let copied = try ImageCodec.decode(XCTUnwrap(board.data(forType: .png)))
        XCTAssertEqual(copied.width, 240)
        XCTAssertEqual(copied.height, 160)
        let bitmap = NSBitmapImageRep(cgImage: copied)
        for (x, y) in [(0, 0), (239, 159)] {
            let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(pixel.redComponent, 0, accuracy: 0.01)
        }
    }
}

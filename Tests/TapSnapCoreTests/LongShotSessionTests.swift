import CoreGraphics
import TapSnapScreen
import TapSnapStitching
import XCTest
@testable import TapSnapApp

final class LongShotSessionTests: XCTestCase {
    func testFractionalSelectionMatchesInitialScreenshotPixelBounds() throws {
        let screen = ScreenDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                      scale: 2, isMain: true, localizedName: "Test")
        let context = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let rect = CGRect(x: 101.3, y: 67.3, width: 200.3, height: 150.3)
        var selection = ScreenshotSession(mode: .longShot)
        selection.frames = [CapturedFrame(screen: screen, image: image)]
        selection.selectionRect = rect
        selection.targetScreen = screen
        let initial = try XCTUnwrap(selection.croppedImage())
        let streamed = try XCTUnwrap(LongShotSession.cropFrame(image, rect: rect, screen: screen))
        XCTAssertEqual(streamed.width, initial.width)
        XCTAssertEqual(streamed.height, initial.height)
    }

    @MainActor
    func testAutomaticScrollRetriesUnstableFrameAndStitchesMultipleStepsAtRetinaScale() async throws {
        let bounds = CGRect(x: -200, y: 50, width: 180, height: 145)
        let screen = ScreenDescriptor(id: 1, frame: bounds, visibleFrame: bounds,
                                      scale: 2, isMain: false, localizedName: "Retina")
        let local = CGRect(x: 20.3, y: 17.3, width: 120.3, height: 106.3)
        let rect = local.offsetBy(dx: bounds.minX, dy: bounds.minY)
        let page = try makePage(width: 360, height: 1_200)
        func frame(at offset: Int) throws -> CGImage {
            try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: offset, width: 360, height: 290)))
        }
        var selection = ScreenshotSession(mode: .longShot)
        let firstFrame = try frame(at: 0)
        selection.frames = [CapturedFrame(screen: screen, image: firstFrame)]
        selection.selectionRect = rect
        selection.targetScreen = screen
        let first = try XCTUnwrap(selection.croppedImage())
        let stitcher = FrameStitcher(scrollingRect: CGRect(x: 0, y: 0, width: first.width, height: first.height))
        _ = try stitcher.append(first)

        let legacy = try XCTUnwrap(ImageCrop.crop(try frame(at: 80), to: local, scale: 2))
        XCTAssertThrowsError(try stitcher.append(legacy)) { error in
            guard case StitchingError.incompatibleFrame = error else {
                return XCTFail("旧的裁剪方式应复现首轮滚动后的尺寸不匹配")
            }
        }

        let policy = AutomaticScrollPolicy(viewportHeight: local.height, configuredStep: 41,
                                           intervalMilliseconds: 120, overlap: 0.35)
        var offset = 0
        for round in 1...5 {
            var captures = 0
            var pulses = 0
            let grew = try await policy.scrollAndStitch(post: { delta in
                pulses += 1
                offset -= Int(delta) * 2
                return true
            }) { _ in
                captures += 1
                // First paint has no overlap. Waiting for the next paint restores the same step.
                let source = try frame(at: round == 1 && captures == 1 ? 800 : offset)
                let cropped = try XCTUnwrap(LongShotSession.cropFrame(source, rect: rect, screen: screen))
                let previousHeight = try XCTUnwrap(stitcher.currentImage).height
                return try stitcher.append(cropped).height > previousHeight
            }
            XCTAssertEqual(grew, true)
            XCTAssertGreaterThan(pulses, 1)
            XCTAssertEqual(captures, round == 1 ? 2 : 1)
            XCTAssertEqual(offset, round * 82, "Retrying a frame must not scroll again")
            XCTAssertEqual(stitcher.currentImage?.height, first.height + offset)
        }

        let result = try stitcher.finish()
        let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 41, y: 35, width: 241, height: 623)))
        XCTAssertEqual(try pixels(result), try pixels(expected), "No rows may be missing or repeated")
    }

    @MainActor
    func testPausingAutomaticScrollCancelsRemainingWheelEventsAndCapture() async {
        let policy = AutomaticScrollPolicy(viewportHeight: 400, configuredStep: 200,
                                           intervalMilliseconds: 300, overlap: 0.35)
        var pulses = 0
        let task = Task {
            try await policy.scrollAndStitch(post: { _ in
                pulses += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }) { _ in
                XCTFail("Paused scrolling must not try to capture another automatic frame")
                return false
            }
        }
        guard case .failure(let error) = await task.result, error is CancellationError else {
            return XCTFail("The in-flight scroll should be cancelled")
        }
        XCTAssertEqual(pulses, 1)
    }

    @MainActor
    func testAutomaticScrollWaitsWithoutACaptureWhenPointerIsOutside() async throws {
        let policy = AutomaticScrollPolicy(viewportHeight: 400, configuredStep: 200,
                                           intervalMilliseconds: 300, overlap: 0.35)
        var attempts = 0
        let result = try await policy.scrollAndStitch(post: { _ in
            attempts += 1
            return false
        }) { _ in
            XCTFail("Do not count a stitch attempt when no wheel events were sent")
            return false
        }
        XCTAssertNil(result)
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testLeavingThePageStopsTheBurstButStitchesThePartialMovement() async throws {
        let policy = AutomaticScrollPolicy(viewportHeight: 400, configuredStep: 200,
                                           intervalMilliseconds: 300, overlap: 0.35)
        var attempts = 0
        var scroll = Int32.zero
        let result = try await policy.scrollAndStitch(post: { delta in
            attempts += 1
            guard attempts == 1 else { return false }
            scroll -= delta
            return true
        }) { _ in
            XCTAssertEqual(scroll, 25)
            return true
        }
        XCTAssertEqual(result, true)
        XCTAssertEqual(attempts, 2)
    }

    func testAutomaticWheelPreservesThePixelDeltaAndTag() throws {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw XCTSkip("Quartz 输入事件测试需要可用的 macOS WindowServer")
        }
        let event = try XCTUnwrap(LongShotSession.automaticWheel(-28, source: source))

        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -28)
        XCTAssertNotEqual(event.getIntegerValueField(.eventSourceUserData), 0)
    }

    func testAutomaticScrollDoesNotRetargetAnOverlappingApp() {
        func window(pid: pid_t, id: CGWindowID, frame: CGRect) -> [String: Any] {
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id,
             kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let bounds = CGRect(x: -500, y: -100, width: 400, height: 300)
        let cursor = CGPoint(x: -300, y: 20)
        let preview = window(pid: 1, id: 5, frame: bounds)
        let selected = window(pid: 2, id: 6, frame: bounds)
        let cover = window(pid: 3, id: 7, frame: bounds)
        let underlying = LongShotSession.ScrollTarget(pid: 2, windowID: 6)

        XCTAssertEqual(LongShotSession.scrollTargetWindow(in: [preview, selected], at: cursor,
                                                         expectedProcess: 2, ownProcess: 1), underlying)
        XCTAssertNil(LongShotSession.scrollTargetWindow(in: [preview, cover, selected], at: cursor,
                                                       expectedProcess: 2, ownProcess: 1))
    }

    private func makePage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 42
        for index in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let gray = UInt8(seed >> 24)
            bytes[index] = gray
            bytes[index + 1] = gray
            bytes[index + 2] = gray
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}

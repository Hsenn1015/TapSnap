import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import TapSnapScreen

final class ScreenStreamerTests: XCTestCase {
    private func screen(scale: CGFloat = 2) -> ScreenDescriptor {
        ScreenDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                         visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                         scale: scale, isMain: true, localizedName: "Test")
    }

    func testRetinaStreamPreservesBottomRightSelection() {
        let screen = screen()
        let configuration = ScreenStreamer.configuration(for: screen, frameRate: 10, capturesAudio: false)
        let context = CGContext(data: nil, width: configuration.width, height: configuration.height,
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let cropped = ImageCrop.crop(image, to: CGRect(x: 600, y: 450, width: 200, height: 150), scale: screen.scale)
        XCTAssertEqual(cropped?.width, 400, "Retina 右下角选区必须能完整裁出，不能拿 point 尺寸的流乘以 scale")
        XCTAssertEqual(cropped?.height, 300)
        XCTAssertEqual(configuration.width, 1600)
        XCTAssertEqual(configuration.height, 1200)
    }

    func testStandardDisplayAndAudioConfigurationArePreserved() {
        let configuration = ScreenStreamer.configuration(for: screen(scale: 1), frameRate: 30, capturesAudio: true)
        XCTAssertEqual(configuration.width, 800)
        XCTAssertEqual(configuration.height, 600)
        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertTrue(configuration.excludesCurrentProcessAudio)
        XCTAssertEqual(configuration.sampleRate, 48000)
        XCTAssertEqual(configuration.channelCount, 2)
        XCTAssertFalse(configuration.showsCursor)
    }

    func testStartupFailureIsReportedOnMainThread() async {
        let reported = expectation(description: "startup failure")
        let error = NSError(domain: "ScreenStreamerTests", code: 42)
        let streamer = ScreenStreamer(loadContent: { throw error })
        streamer.onError = { received in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual((received as NSError).code, 42)
            XCTAssertFalse(streamer.isStreaming)
            reported.fulfill()
        }
        streamer.start(screen: screen())
        await fulfillment(of: [reported], timeout: 2)
        streamer.onError = nil
    }

    func testCancelledStartupCannotStopNewSession() async {
        let firstRequested = expectation(description: "first content request")
        let secondRequested = expectation(description: "second content request")
        let pending = PendingContent(firstRequested: firstRequested, secondRequested: secondRequested)
        let streamer = ScreenStreamer(loadContent: { try await pending.load() })
        streamer.onError = { _ in XCTFail("取消的旧启动不应报告错误") }
        streamer.start(screen: screen())
        await fulfillment(of: [firstRequested], timeout: 2)
        streamer.stop()
        streamer.start(screen: screen())
        await fulfillment(of: [secondRequested], timeout: 2)
        await pending.failFirst()
        // Give the resumed first startup a turn to reach its catch handler.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(streamer.isStreaming, "旧会话延迟失败不能改掉新会话的状态")
        streamer.stop()
        await pending.failFirst()
    }
}

private actor PendingContent {
    private var requests: [CheckedContinuation<SCShareableContent, Error>] = []
    private var count = 0
    private let firstRequested: XCTestExpectation
    private let secondRequested: XCTestExpectation

    init(firstRequested: XCTestExpectation, secondRequested: XCTestExpectation) {
        self.firstRequested = firstRequested
        self.secondRequested = secondRequested
    }

    func load() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            count += 1
            if count == 1 { firstRequested.fulfill() } else { secondRequested.fulfill() }
        }
    }

    func failFirst() {
        guard !requests.isEmpty else { return }
        requests.removeFirst().resume(throwing: NSError(domain: "ScreenStreamerTests", code: 1))
    }
}

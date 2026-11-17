import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import SwiftUI
import TapSnapConfig
import XCTest
@testable import TapSnapApp
@testable import TapSnapMedia
@testable import TapSnapScreen

private final class TestRecordStream: RecordStream {
    var onFrame: ((ScreenStreamer.Frame) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?
    var excludedApplication = false
    var includesCursor = false
    var stopCount = 0
    var onStart: (() -> Void)?

    func start(screen: ScreenDescriptor, frameRate: Int, capturesAudio: Bool,
               excludingCurrentApplication: Bool, includesCursor: Bool) {
        excludedApplication = excludingCurrentApplication
        self.includesCursor = includesCursor
        onStart?()
    }
    func stop() { stopCount += 1 }
}

private enum TestRecordError: Error { case failed }

private final class TestRecordEncoder: RecordEncoding {
    var prepareError: Error?
    var appendError: Error?
    var finishError: Error?
    var frames: [(width: Int, height: Int, time: TimeInterval)] = []
    var cancelCount = 0
    var finishCount = 0
    var endingTime: TimeInterval?
    var output: URL?
    var onAppend: (() -> Void)?
    var finishGate: CheckedContinuation<Void, Never>?
    var waitsForFinish = false

    func prepare(outputURL: URL) throws {
        if let prepareError { throw prepareError }
        output = outputURL
    }
    func append(_ image: CGImage, at time: TimeInterval) throws {
        onAppend?()
        if let appendError { throw appendError }
        frames.append((image.width, image.height, time))
    }
    func appendAudio(_ sampleBuffer: CMSampleBuffer, pausedSoFar: TimeInterval) -> Bool { true }
    @MainActor func finish(endingAt time: TimeInterval?) async throws -> URL? {
        finishCount += 1
        endingTime = time
        if waitsForFinish { await withCheckedContinuation { finishGate = $0 } }
        if let finishError { throw finishError }
        return output
    }
    func cancel() { cancelCount += 1 }
}

@MainActor
final class RecordSessionTests: XCTestCase {
    private func image(width: Int = 200, height: Int = 100) -> CGImage {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private func session(stream: TestRecordStream, encoder: TestRecordEncoder,
                         rect: CGRect? = nil, timeout: TimeInterval = 15,
                         now: @escaping () -> TimeInterval = { 100 }) -> RecordSession {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let screen = ScreenDescriptor(id: 1, frame: frame, visibleFrame: frame,
                                      scale: 2, isMain: true, localizedName: "Test")
        return RecordSession(configuration: .init(screen: screen, rect: rect, includesCursor: true,
                                                   outputURL: URL(fileURLWithPath: "/tmp/record-session-test.mp4")),
                             makeStream: { stream }, makeEncoder: { _ in encoder }, now: now,
                             startupTimeout: timeout)
    }

    private func begin(_ session: RecordSession, stream: TestRecordStream) async throws {
        let frame = image()
        stream.onStart = { stream.onFrame?(.init(image: frame, timestamp: Date())) }
        try await session.start()
    }

    func testWaitsForFirstFrameAndExcludesOwnApplication() async throws {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        let session = session(stream: stream, encoder: encoder)
        let started = expectation(description: "stream requested")
        stream.onStart = { started.fulfill() }
        let task = Task { try await session.start() }
        await fulfillment(of: [started], timeout: 1)
        guard case .preparing = session.state else { return XCTFail("尚未收到帧不能显示录制中") }
        XCTAssertTrue(stream.excludedApplication)
        XCTAssertTrue(stream.includesCursor)
        stream.onFrame?(.init(image: image(), timestamp: Date()))
        try await task.value
        guard case .recording = session.state else { return XCTFail("第一帧后应进入录制") }
        session.cancel()
    }

    func testRestartFromPausedRecordingKeepsSelectionAndResetsTimer() async throws {
        _ = NSApplication.shared
        guard let screen = ScreenLayout.current().first else { throw XCTSkip("重录控制条需要 macOS WindowServer") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        config.update {
            $0.record.includesCamera = false
            $0.record.showsKeyPresses = false
            $0.record.showsMouseClicks = false
        }
        let frame = ScreenStreamer.Frame(image: image(), timestamp: Date())
        let streams = [TestRecordStream(), TestRecordStream()]
        let encoders = [TestRecordEncoder(), TestRecordEncoder()]
        let initialStart = expectation(description: "initial stream started")
        let restart = expectation(description: "replacement stream started")
        streams[0].onStart = {
            streams[0].onFrame?(frame)
            initialStart.fulfill()
        }
        streams[1].onStart = { restart.fulfill() }
        var now: TimeInterval = 100
        var sessions: [RecordSession] = []
        let environment = AppEnvironment(config: config)
        let controller = RecordController(environment: environment, makeSession: { configuration in
            let stream = streams[sessions.count], encoder = encoders[sessions.count]
            let session = RecordSession(configuration: configuration, makeStream: { stream },
                                        makeEncoder: { _ in encoder }, now: { now }, startupTimeout: 2)
            sessions.append(session)
            return session
        })
        environment.record = controller
        let selection = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertFalse(environment.isUpdateInteractionBusy)
        controller.start(rect: selection, screen: screen)
        XCTAssertTrue(environment.isUpdateInteractionBusy)
        await fulfillment(of: [initialStart], timeout: 2)
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.isVisible && $0.contentViewController is NSHostingController<RecordControlBarView>
        })
        let host = try XCTUnwrap(panel.contentViewController as? NSHostingController<RecordControlBarView>)
        let model = host.rootView.model
        defer { model.onCancel?() }
        let originalFrame = panel.frame
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        now += 7
        model.onPauseToggle?()
        for _ in 0..<100 where !model.isPaused || model.elapsed == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.elapsed, 7)
        XCTAssertTrue(environment.isUpdateInteractionBusy)

        try XCTUnwrap(model.onRestart)()
        await fulfillment(of: [restart], timeout: 2)
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(environment.isUpdateInteractionBusy)
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.elapsed, 0)
        XCTAssertEqual(panel.frame, originalFrame)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(streams[0].stopCount, 1)
        XCTAssertEqual(encoders[0].cancelCount, 1)
        XCTAssertEqual(encoders[0].finishCount, 0)
        XCTAssertNil(controller.lastRecordingURL)
        XCTAssertEqual(sessions.map { $0.configuration.rect }, [selection, selection])
        XCTAssertNotEqual(encoders[0].output, encoders[1].output)

        streams[1].onFrame?(frame)
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.elapsed, 0)
        model.onCancel?()
        for _ in 0..<100 where environment.isUpdateInteractionBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(environment.isUpdateInteractionBusy)
    }

    func testStartupFailureStopsStreamAndRejectsStart() async {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        let session = session(stream: stream, encoder: encoder)
        stream.onStart = { stream.onError?(TestRecordError.failed) }
        do { try await session.start(); XCTFail("启动失败必须抛错") } catch {}
        guard case .failed = session.state else { return XCTFail("应报告失败状态") }
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertEqual(encoder.cancelCount, 1)
    }

    func testWriterPreparationFailureDoesNotStartScreenCapture() async {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        encoder.prepareError = TestRecordError.failed
        stream.onStart = { XCTFail("文件创建失败后不应继续抓屏") }
        let session = session(stream: stream, encoder: encoder)
        do { try await session.start(); XCTFail("准备失败必须抛错") } catch {}
        guard case .failed = session.state else { return XCTFail("应报告失败状态") }
        XCTAssertEqual(encoder.cancelCount, 1)
    }

    func testCancelDuringStartupRejectsWaitAndIgnoresLateFrame() async {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        let session = session(stream: stream, encoder: encoder)
        let started = expectation(description: "stream requested")
        stream.onStart = { started.fulfill() }
        let task = Task { try await session.start() }
        await fulfillment(of: [started], timeout: 1)
        let lateCallback = stream.onFrame
        session.cancel()
        lateCallback?(.init(image: image(), timestamp: Date()))
        do { try await task.value; XCTFail("取消启动应抛错") } catch { XCTAssertTrue(error is CancellationError) }
        await Task.yield()
        guard case .idle = session.state else { return XCTFail("迟到帧不能重新开始录制") }
        XCTAssertTrue(encoder.frames.isEmpty)
    }

    func testStartupWithoutFramesTimesOut() async {
        let session = session(stream: TestRecordStream(), encoder: TestRecordEncoder(), timeout: 0.01)
        do { try await session.start(); XCTFail("不能无限等待第一帧") } catch {}
        guard case .failed = session.state else { return XCTFail("超时应报告失败") }
    }

    func testCancellingStartTaskStopsCaptureWithoutWaitingForTimeout() async {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        let session = session(stream: stream, encoder: encoder)
        let started = expectation(description: "stream requested")
        stream.onStart = { started.fulfill() }
        let task = Task { try await session.start() }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { try await task.value; XCTFail("取消任务必须退出启动等待") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(stream.stopCount, 1)
        guard case .idle = session.state else { return XCTFail("取消后应回到空闲") }
    }

    func testPauseAndFinishedElapsedStayFrozen() async throws {
        var clock: TimeInterval = 100
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        let session = session(stream: stream, encoder: encoder, now: { clock })
        try await begin(session, stream: stream)
        clock = 105
        session.pause()
        clock = 115
        XCTAssertEqual(session.elapsed, 5)
        session.resume()
        clock = 118
        XCTAssertEqual(session.elapsed, 8)
        _ = try await session.finish()
        XCTAssertEqual(encoder.endingTime, 8)
        clock = 200
        XCTAssertEqual(session.elapsed, 8)
    }

    func testFrameFailureIsReportedAndCaptureStops() async throws {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        encoder.appendError = TestRecordError.failed
        let session = session(stream: stream, encoder: encoder)
        let failed = expectation(description: "frame failure")
        session.onStateChange = { if case .failed = $0 { failed.fulfill() } }
        try await begin(session, stream: stream)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertEqual(encoder.cancelCount, 1)
    }

    func testCropsWithActualFrameDimensionsAndDoesNotUseWholeScreen() async throws {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        let session = session(stream: stream, encoder: encoder, rect: CGRect(x: 10, y: 5, width: 30, height: 20))
        let frame = image(width: 300, height: 150)
        stream.onStart = { stream.onFrame?(.init(image: frame, timestamp: Date())) }
        try await session.start()
        _ = try await session.finish()
        XCTAssertEqual(encoder.frames.first?.width, 90)
        XCTAssertEqual(encoder.frames.first?.height, 60)
        XCTAssertEqual(encoder.frames.first?.time, 0)
    }

    func testFinishFailureCannotBecomeSuccessfulResult() async throws {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        encoder.finishError = TestRecordError.failed
        let session = session(stream: stream, encoder: encoder)
        try await begin(session, stream: stream)
        do { _ = try await session.finish(); XCTFail("收尾失败必须抛错") } catch {}
        guard case .failed = session.state else { return XCTFail("不能报告完成") }
    }

    func testRealEncoderRejectsNoFramesAndAppendAfterCancel() async throws {
        let encoder = VideoEncoder(configuration: .init(width: 64, height: 48))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("record-empty-\(UUID().uuidString).mp4")
        defer { encoder.cancel(); try? FileManager.default.removeItem(at: output) }
        try encoder.prepare(outputURL: output)
        do {
            _ = try await encoder.finish()
            XCTFail("没有画面不能报告成功或仅返回nil")
        } catch {
            guard case VideoEncoder.EncoderError.noFrames = error else { return XCTFail("应报告没有画面：\(error)") }
        }
        XCTAssertThrowsError(try encoder.append(image(width: 64, height: 48), at: 0))
    }

    func testStaticScreenRetainsRecordingDurationAndReadableLastFrame() async throws {
        let encoder = VideoEncoder(configuration: .init(width: 64, height: 48))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("record-static-\(UUID().uuidString).mp4")
        defer { encoder.cancel(); try? FileManager.default.removeItem(at: output) }
        try encoder.prepare(outputURL: output)
        try encoder.append(image(width: 64, height: 48), at: 0)
        _ = try await encoder.finish(endingAt: 3)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.05)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let lastFrame = try await generator.image(at: CMTime(seconds: 2.9, preferredTimescale: 600))
        XCTAssertEqual(lastFrame.image.width, 64)
        XCTAssertEqual(lastFrame.image.height, 48)
    }

    func testCancelDuringFinishIgnoresLateOutputAndFrames() async throws {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        encoder.waitsForFinish = true
        let session = session(stream: stream, encoder: encoder)
        try await begin(session, stream: stream)
        let lateFrame = stream.onFrame
        let task = Task { try await session.finish() }
        for _ in 0..<100 where encoder.finishGate == nil { await Task.yield() }
        let gate = try XCTUnwrap(encoder.finishGate)
        guard case .finishing = session.state else { return XCTFail("需要明确收尾状态") }
        session.cancel()
        lateFrame?(.init(image: image(), timestamp: Date()))
        gate.resume()
        do { _ = try await task.value; XCTFail("取消后不能发布文件") } catch { XCTAssertTrue(error is CancellationError) }
        guard case .idle = session.state else { return XCTFail("不能迟到地切回完成") }
        XCTAssertEqual(encoder.frames.count, 1)
    }

    func testReleasingActiveSessionStopsItsCaptureAndWriter() async throws {
        let stream = TestRecordStream(), encoder = TestRecordEncoder()
        var active: RecordSession? = session(stream: stream, encoder: encoder)
        try await begin(active!, stream: stream)
        weak var released = active
        active = nil
        XCTAssertNil(released)
        XCTAssertEqual(stream.stopCount, 1)
        XCTAssertEqual(encoder.cancelCount, 1)
    }

    func testCursorConfigurationUsesRequestedSetting() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let screen = ScreenDescriptor(id: 1, frame: frame, visibleFrame: frame,
                                      scale: 2, isMain: true, localizedName: "Test")
        XCTAssertTrue(ScreenStreamer.configuration(for: screen, frameRate: 30, capturesAudio: false,
                                                    includesCursor: true).showsCursor)
        XCTAssertFalse(ScreenStreamer.configuration(for: screen, frameRate: 30, capturesAudio: false).showsCursor)
    }
}

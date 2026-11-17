import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import TapSnapMedia
@testable import TapSnapScreen
@testable import TapSnapSystem

final class RecordingEnhancementTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tapsnap-record-enhancements-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testTrimRejectsInvalidAndNonFiniteBounds() throws {
        for (start, end) in [(-1.0, 2.0), (1, 1), (2, 1), (.nan, 2), (0, .infinity)] {
            XCTAssertThrowsError(try RecordingTimeRange(start: start, end: end))
        }
        let range = try RecordingTimeRange(start: 1.25, end: 2.75)
        XCTAssertEqual(range.duration, 1.5)
        XCTAssertEqual(range.cmTimeRange.start.seconds, 1.25)
        XCTAssertEqual(range.cmTimeRange.duration.seconds, 1.5)
    }

    func testVideoTrimExportsOnlySelectedFramesAndDuration() async throws {
        let source = try await makeVideo()
        let output = directory.appendingPathComponent("selected.mp4")
        try await VideoTrimmer.export(videoURL: source, to: output, range: .init(start: 1, end: 2))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.02)
        let generator = AVAssetImageGenerator(asset: asset)
        let first = try await generator.image(at: .zero).image
        let last = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image
        for frame in [first, last] {
            let color = pixel(frame, x: 20, y: 20)
            XCTAssertGreaterThan(color.green, 0.8)
            XCTAssertGreaterThan(color.green - color.red, 0.5)
            XCTAssertGreaterThan(color.green - color.blue, 0.5)
        }
        let originalDuration = try await AVURLAsset(url: source).load(.duration).seconds
        XCTAssertEqual(originalDuration, 3, accuracy: 0.02)
    }

    func testGIFHonorsTrimFrameRateAndDimensionsTogether() async throws {
        let source = try await makeVideo()
        let output = directory.appendingPathComponent("selected.gif")
        try await GifExporter.export(videoURL: source, to: output, sampleInterval: 0.2,
                                     maximumPixelDimension: 40, timeRange: .init(start: 1, end: 2))
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 5)
        var duration = 0.0
        for index in 0..<CGImageSourceGetCount(gif) {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, index, nil))
            XCTAssertEqual(frame.width, 40)
            XCTAssertEqual(frame.height, 24)
            let color = pixel(frame, x: 20, y: 12)
            XCTAssertGreaterThan(color.green, 0.8)
            XCTAssertGreaterThan(color.green - color.red, 0.5)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [String: Any])
            let timing = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            duration += try XCTUnwrap(timing[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
        }
        XCTAssertEqual(duration, 1, accuracy: 0.01)
    }

    func testTimedMaskUsesSourceTimeAfterTrimmingMP4() async throws {
        let source = try await makeVideo()
        let output = directory.appendingPathComponent("masked.mp4")
        let mask = try mask(start: 1.2, end: 1.6)
        try await VideoTrimmer.export(videoURL: source, to: output, range: .init(start: 1, end: 2),
                                      annotations: [mask])

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (index, seconds) in [0.1, 0.3, 0.7].enumerated() {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let covered = pixel(image, x: 16, y: 10)
            if index == 1 {
                XCTAssertLessThan(covered.red + covered.green + covered.blue, 0.12)
            } else {
                XCTAssertGreaterThan(covered.green, 0.8)
            }
            XCTAssertGreaterThan(pixel(image, x: 16, y: 36).green, 0.8, "遮盖的位置使用视频的左上坐标")
        }
    }

    func testSingleSourceFrameMaskIsIncludedInVideoAndLowRateGIF() async throws {
        let source = try await makeVideo()
        let sourceAsset = AVURLAsset(url: source)
        let frame = try await RecordingAnnotationRenderer.frameRange(at: 1.23, in: sourceAsset)
        XCTAssertEqual(frame.start, 1.2, accuracy: 0.0001)
        XCTAssertEqual(frame.end, 1.3, accuracy: 0.0001)
        let annotation = try mask(start: frame.start, end: frame.end)
        let video = directory.appendingPathComponent("single-frame-mask.mp4")
        try await VideoTrimmer.export(videoURL: source, to: video, range: .init(start: 1, end: 2), annotations: [annotation])
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (index, seconds) in [0.1, 0.2, 0.3].enumerated() {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let covered = pixel(image, x: 16, y: 10)
            if index == 1 {
                XCTAssertLessThan(covered.red + covered.green + covered.blue, 0.12)
            } else {
                XCTAssertGreaterThan(covered.green, 0.8)
            }
        }
        let output = directory.appendingPathComponent("masked.gif")
        try await GifExporter.export(videoURL: source, to: output, sampleInterval: 0.5,
                                     timeRange: .init(start: 1, end: 2), annotations: [annotation])
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 4)
        for index in 0..<CGImageSourceGetCount(gif) {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, index, nil))
            let covered = pixel(image, x: 16, y: 10)
            if index == 1 {
                XCTAssertLessThan(covered.red + covered.green + covered.blue, 0.12)
            } else {
                XCTAssertGreaterThan(covered.green, 0.8)
            }
            XCTAssertGreaterThan(pixel(image, x: 16, y: 36).green, 0.8)
        }
    }

    private func mask(start: TimeInterval, end: TimeInterval) throws -> RecordingAnnotation {
        RecordingAnnotation(kind: .mask, startPoint: CGPoint(x: 0.1, y: 0.1), endPoint: CGPoint(x: 0.4, y: 0.4),
                            range: try .init(start: start, end: end))
    }

    func testOutOfBoundsTrimPreservesExistingOutputs() async throws {
        let source = try await makeVideo()
        let existing = Data("keep".utf8)
        let range = try RecordingTimeRange(start: 2, end: 4)
        for suffix in ["mp4", "gif"] {
            let output = directory.appendingPathComponent("existing.\(suffix)")
            try existing.write(to: output)
            do {
                if suffix == "mp4" { try await VideoTrimmer.export(videoURL: source, to: output, range: range) }
                else { try await GifExporter.export(videoURL: source, to: output, timeRange: range) }
                XCTFail("越界不能导出不完整片段")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: output), existing)
        }
    }

    func testCancelledTrimPreservesDestinationAndSource() async throws {
        let source = try await makeVideo()
        let output = directory.appendingPathComponent("cancelled.mp4")
        let existing = Data("keep".utf8)
        try existing.write(to: output)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await VideoTrimmer.export(videoURL: source, to: output, range: .init(start: 1, end: 2))
        }
        do { try await task.value; XCTFail("取消应退出") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: output), existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".tapsnap-trim-") })
    }

    func testCameraAndClickCompositingKeepsScreenSizeAndCoordinates() {
        let screen = image(color: CGColor(gray: 0, alpha: 1), width: 640, height: 360)
        let camera = image(color: CGColor(red: 0, green: 1, blue: 0, alpha: 1), width: 80, height: 60)
        let composed = RecordingCompositor.compose(screen, overlay: .init(camera: camera, clicks: [CGPoint(x: 0.2, y: 0.25)]))
        XCTAssertEqual(composed.width, screen.width)
        XCTAssertEqual(composed.height, screen.height)
        XCTAssertGreaterThan(pixel(composed, x: 550, y: 300).green, 0.9, "画中画应写入画面右下方")
        XCTAssertGreaterThan(pixel(composed, x: 128, y: 90).red, 0.2, "点击应按左上原点映射到录制区域")
        XCTAssertLessThan(pixel(composed, x: 128, y: 270).red, 0.1, "不能把点击上下颠倒")
        XCTAssertLessThan(pixel(composed, x: 320, y: 180).green, 0.1)
        XCTAssertTrue(RecordingCompositor.compose(screen, overlay: .init()) === screen)
    }

    func testShortcutOverlaySkipsOrdinaryTypedText() {
        XCTAssertNil(RecordingCompositor.shortcutLabel(keyCode: 0, flags: 0))
        XCTAssertNil(RecordingCompositor.shortcutLabel(keyCode: 0, flags: CGEventFlags.maskShift.rawValue))
        XCTAssertEqual(RecordingCompositor.shortcutLabel(keyCode: 8, flags: CGEventFlags.maskCommand.rawValue), "⌘C")
        XCTAssertNotNil(RecordingCompositor.shortcutLabel(keyCode: 53, flags: 0))
        let screen = image(color: CGColor(gray: 1, alpha: 1), width: 640, height: 360)
        let composed = RecordingCompositor.compose(screen, overlay: .init(shortcut: "⌘C"))
        XCTAssertLessThan(pixel(composed, x: 20, y: 330).red, 0.5, "快捷键提示应实际合成进像素")
    }

    private func makeVideo() async throws -> URL {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 80, AVVideoHeightKey: 48,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey as String: 80, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GIFExportError.destinationFailed }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline else { throw GIFExportError.destinationFailed }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: 80, height: 48,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setFillColor(CGColor(red: index < 10 ? 1 : 0, green: (10..<20).contains(index) ? 1 : 0,
                                         blue: index >= 20 ? 1 : 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 48))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}

private func image(color: CGColor, width: Int = 640, height: Int = 360) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Double, green: Double, blue: Double) {
    let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
    var bytes: [UInt8] = [0, 0, 0, 0]
    let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
}

private final class OverlayTestStream: RecordStream {
    var onFrame: ((ScreenStreamer.Frame) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?
    func start(screen: ScreenDescriptor, frameRate: Int, capturesAudio: Bool,
               excludingCurrentApplication: Bool, includesCursor: Bool) {
        onFrame?(.init(image: image(color: CGColor(gray: 0, alpha: 1)), timestamp: Date()))
    }
    func stop() {}
}

private final class OverlayTestEncoder: RecordEncoding {
    private let lock = NSLock()
    private var values: [CGImage] = []
    var images: [CGImage] { lock.lock(); defer { lock.unlock() }; return values }
    var onAppend: (() -> Void)?
    func prepare(outputURL: URL) throws {}
    func append(_ image: CGImage, at time: TimeInterval) throws {
        lock.withLock { values.append(image) }
        onAppend?()
    }
    func appendAudio(_ sampleBuffer: CMSampleBuffer, pausedSoFar: TimeInterval) -> Bool { true }
    @MainActor func finish(endingAt: TimeInterval?) async throws -> URL? { nil }
    func cancel() {}
}

private final class OverlayTestInput: RecordInputMonitoring {
    var onEvent: ((KeyMouseMonitor.Event) -> Void)?
    var observesKeyboard = false
    var isRunning = false
    var permitsStart = true
    func start() { isRunning = permitsStart }
    func stop() { isRunning = false }
}

@MainActor
final class RecordingOverlaySessionTests: XCTestCase {
    private func session(input: OverlayTestInput, encoder: OverlayTestEncoder) -> RecordSession {
        let bounds = CGRect(x: -1000, y: 200, width: 640, height: 360)
        let screen = ScreenDescriptor(id: 123, frame: bounds, visibleFrame: bounds,
                                      scale: 1, isMain: false, localizedName: "External")
        return RecordSession(configuration: .init(screen: screen, showsMouseClicks: true,
                                                   outputURL: URL(fileURLWithPath: "/tmp/tapsnap-overlay-test.mp4")),
                             makeStream: { OverlayTestStream() }, makeEncoder: { _ in encoder },
                             now: { ProcessInfo.processInfo.systemUptime }, startupTimeout: 1,
                             makeInputMonitor: { input })
    }

    func testClickAppearsOnStaticDesktopAndMonitoringStopsWithSession() async throws {
        let input = OverlayTestInput(), encoder = OverlayTestEncoder()
        let session = session(input: input, encoder: encoder)
        try await session.start()
        XCTAssertTrue(input.isRunning)
        XCTAssertFalse(input.observesKeyboard, "只显示点击时不监听按键")
        let rendered = expectation(description: "static desktop receives click overlay")
        var fulfilled = false
        encoder.onAppend = {
            if let frame = encoder.images.last, pixel(frame, x: 128, y: 90).red > 0.2, !fulfilled {
                fulfilled = true
                rendered.fulfill()
            }
        }
        input.onEvent?(.init(kind: .leftMouseDown, location: CGPoint(x: -872, y: 290), keyCode: nil,
                            modifierFlags: 0, timestamp: CFAbsoluteTimeGetCurrent()))
        await fulfillment(of: [rendered], timeout: 2)
        session.cancel()
        XCTAssertFalse(input.isRunning)
        XCTAssertNil(input.onEvent)
        XCTAssertGreaterThan(encoder.images.count, 1)
    }

    func testUnavailableMonitoringFailsExplicitlyAndCleansUp() async {
        let input = OverlayTestInput(), encoder = OverlayTestEncoder()
        input.permitsStart = false
        let session = session(input: input, encoder: encoder)
        do { try await session.start(); XCTFail("不能静默省略已启用的键鼠提示") }
        catch RecordError.inputMonitoringUnavailable {} catch { XCTFail("unexpected \(error)") }
        guard case .failed = session.state else { return XCTFail("必须显示失败状态") }
        XCTAssertFalse(input.isRunning)
        XCTAssertNil(input.onEvent)
        XCTAssertTrue(encoder.images.isEmpty)
    }
}

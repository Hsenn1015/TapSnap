import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import TapSnapMedia

final class GifExporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tapsnap-gif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func frame(_ index: Int, width: Int = 80, height: Int = 48) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: index % 3 == 0 ? 1 : 0,
                                     green: index % 3 == 1 ? 1 : 0,
                                     blue: index % 3 == 2 ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func makeVideo(frameCount: Int = 10, frameRate: Int = 10) async throws -> URL {
        let url = directory.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 80, AVVideoHeightKey: 48,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey as String: 80,
                                          kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? GIFExportError.destinationFailed
        }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frameCount {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline else { throw writer.error ?? GIFExportError.destinationFailed }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 80, height: 48,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(frame(index), in: CGRect(x: 0, y: 0, width: 80, height: 48))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: Int32(frameRate))))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: Int32(frameRate)))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func source(_ url: URL) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    private func delays(_ source: CGImageSource) throws -> [Double] {
        try (0..<CGImageSourceGetCount(source)).map { index in
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            return try XCTUnwrap((gif[kCGImagePropertyGIFUnclampedDelayTime as String]
                                  ?? gif[kCGImagePropertyGIFDelayTime as String]) as? Double)
        }
    }

    func testFifteenFPSKeepsTotalPlaybackTimeAndLoopCount() throws {
        let url = directory.appendingPathComponent("frames.gif")
        try GifExporter.export(frames: (0..<15).map { frame($0) }, to: url, frameDelay: 1.0 / 15.0, loopCount: 3)
        let imageSource = try source(url)
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 15)
        XCTAssertEqual(try delays(imageSource).reduce(0, +), 1, accuracy: 0.011)
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(imageSource, nil) as? [String: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount as String] as? Int, 3)
    }

    func testInvalidFrameDelayAndLoopAreRejected() {
        let url = directory.appendingPathComponent("invalid.gif")
        for delay in [0.0, -1.0, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try GifExporter.export(frames: [frame(0)], to: url, frameDelay: delay))
        }
        XCTAssertThrowsError(try GifExporter.export(frames: [frame(0)], to: url, loopCount: -1))
    }

    func testVideoLastFrameDoesNotExtendPlayback() async throws {
        let video = try await makeVideo()
        let url = directory.appendingPathComponent("video.gif")
        try await GifExporter.export(videoURL: video, to: url, sampleInterval: 0.3)
        let imageSource = try source(url)
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 4)
        XCTAssertEqual(try delays(imageSource).reduce(0, +), 1, accuracy: 0.011)
    }

    func testDefaultVideoExportUsesFifteenFramesPerSecond() async throws {
        let video = try await makeVideo(frameCount: 30, frameRate: 30)
        let output = directory.appendingPathComponent("default.gif")
        try await GifExporter.export(videoURL: video, to: output)
        let imageSource = try source(output)
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 15)
        XCTAssertEqual(try delays(imageSource).reduce(0, +), 1, accuracy: 0.011)
    }

    func testUnreadableVideoFrameFailsWithoutReplacingOutput() async throws {
        let video = try await makeVideo()
        // 损坏媒体数据而保留 MP4 元数据，使时长可读、实际解码失败。
        var data = try Data(contentsOf: video)
        var offset = 0
        var damaged = false
        while offset + 8 <= data.count {
            var size = Int(data[offset..<offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
            var header = 8
            if size == 1 {
                guard offset + 16 <= data.count else { break }
                size = Int(data[offset + 8..<offset + 16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
                header = 16
            }
            guard size >= header, offset + size <= data.count else { break }
            if data[offset + 4..<offset + 8] == Data("mdat".utf8) {
                data.replaceSubrange(offset + header..<offset + size, with: repeatElement(UInt8(0), count: size - header))
                damaged = true
                break
            }
            offset += size
        }
        XCTAssertTrue(damaged)
        try data.write(to: video)
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.001)
        let output = directory.appendingPathComponent("keep.gif")
        let existing = Data("existing output".utf8)
        try existing.write(to: output)
        do {
            try await GifExporter.export(videoURL: video, to: output)
            XCTFail("损坏的视频帧不能被静默跳过")
        } catch GIFExportError.frameGenerationFailed(let seconds, _) {
            XCTAssertEqual(seconds, 0)
        }
        XCTAssertEqual(try Data(contentsOf: output), existing)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".tapsnap-gif-") })
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testVideoProducesDifferentFramesWithBoundedSizeAndProgress() async throws {
        let video = try await makeVideo()
        let url = directory.appendingPathComponent("scaled.gif")
        let progress = ProgressLog()
        try await GifExporter.export(videoURL: video, to: url, sampleInterval: 0.1,
                                     maximumPixelDimension: 40, progress: { progress.append($0) })
        let imageSource = try source(url)
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 10)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let second = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 1, nil))
        XCTAssertEqual(first.width, 40)
        XCTAssertEqual(first.height, 24)
        XCTAssertNotEqual(first.dataProvider?.data as Data?, second.dataProvider?.data as Data?)
        let values = progress.snapshot
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values.filter { $0 == 1 }.count, 1)
        XCTAssertEqual(values, values.sorted())
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(imageSource, nil) as? [String: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        XCTAssertEqual(gif[kCGImagePropertyGIFLoopCount as String] as? Int, 0)
    }

    func testVeryShortVideoIsALegalSingleFrameGIF() async throws {
        let video = try await makeVideo(frameCount: 1, frameRate: 30)
        let url = directory.appendingPathComponent("short.gif")
        try await GifExporter.export(videoURL: video, to: url)
        let imageSource = try source(url)
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
        XCTAssertEqual(try delays(imageSource).first ?? 0, 1.0 / 30.0, accuracy: 0.011)
    }

    func testInvalidVideoParametersFailBeforeReadingInput() async {
        let missing = directory.appendingPathComponent("missing.mp4")
        let output = directory.appendingPathComponent("invalid.gif")
        for interval in [0.0, -1.0, Double.nan, Double.infinity] {
            do {
                try await GifExporter.export(videoURL: missing, to: output, sampleInterval: interval)
                XCTFail("无效间隔不应进入抽帧")
            } catch GIFExportError.invalidParameters {
            } catch { XCTFail("应先验证参数，实际为 \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancellationKeepsExistingOutputAndRemovesPartialGIF() async throws {
        let video = try await makeVideo()
        let output = directory.appendingPathComponent("keep.gif")
        let existing = Data("existing output".utf8)
        try existing.write(to: output)
        let task = Task {
            try await GifExporter.export(videoURL: video, to: output, progress: { value in
                if value > 0, value < 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do {
            try await task.value
            XCTFail("取消应抛 CancellationError")
        } catch is CancellationError {
        }
        XCTAssertEqual(try Data(contentsOf: output), existing)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".tapsnap-gif-") })
    }

    func testSuccessfulExportReplacesAnExistingFile() throws {
        let output = directory.appendingPathComponent("replace.gif")
        try Data("old".utf8).write(to: output)
        try GifExporter.export(frames: [frame(0), frame(1)], to: output)
        XCTAssertEqual(CGImageSourceGetCount(try source(output)), 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".tapsnap-gif-") })
    }
}

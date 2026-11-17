import AVFoundation
import CoreGraphics
import CoreMedia
import XCTest
@testable import TapSnapMedia

/// 录屏编码的回归测试。
///
/// 重点是音轨：时间戳要从系统时钟重建成「从 0 开始」，暂停的时长要减掉，
/// 否则导出的文件要么没声音，要么音画越走越偏。
final class VideoEncoderTests: XCTestCase {
    private var outputURL: URL!

    override func setUpWithError() throws {
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapsnap-test-\(UUID().uuidString).mp4")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - 素材

    private func makeFrame(width: Int = 64, height: Int = 48) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = 40
            bytes[index + 1] = 120
            bytes[index + 2] = 200
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

    /// 造一段静音 PCM，模拟 `SCStream` 送来的音频样本（时间戳是系统时钟）。
    private func makeAudioBuffer(
        at pts: CMTime,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        frames: Int = 1024
    ) -> CMSampleBuffer? {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        let byteCount = frames * Int(streamDescription.mBytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }

        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private func writeVideo(_ encoder: VideoEncoder, frames: Int, step: TimeInterval) throws {
        let frame = makeFrame()
        for index in 0..<frames {
            try encoder.append(frame, at: Double(index) * step)
        }
    }

    /// 编码器按实时节奏接收样本，测试里要塞进去就得等它 ready。
    private func appendAudioSamples(
        _ samples: [(buffer: CMSampleBuffer, pausedSoFar: TimeInterval)],
        to encoder: VideoEncoder
    ) async throws {
        for sample in samples {
            var attempts = 0
            while !encoder.appendAudio(sample.buffer, pausedSoFar: sample.pausedSoFar) {
                attempts += 1
                if attempts > 200 {
                    XCTFail("音频样本一直写不进去")
                    return
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    // MARK: - 用例

    func testVideoOnlyProducesOneTrack() async throws {
        let encoder = VideoEncoder(configuration: .init(width: 64, height: 48, frameRate: 20))
        try encoder.prepare(outputURL: outputURL)
        try writeVideo(encoder, frames: 10, step: 0.05)

        let url = try await encoder.finish()
        XCTAssertNotNil(url)

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 0)
    }

    func testAudioIsMuxedIntoSecondTrack() async throws {
        let encoder = VideoEncoder(configuration: .init(
            width: 64, height: 48, frameRate: 20, includesAudio: true
        ))
        try encoder.prepare(outputURL: outputURL)
        try writeVideo(encoder, frames: 10, step: 0.05)

        // 音频时间戳故意从 5000 秒开始，验证会被重建成 0 起点。
        let start = CMTime(seconds: 5000, preferredTimescale: 48_000)
        let bufferDuration = 1024.0 / 48_000.0
        var samples: [(buffer: CMSampleBuffer, pausedSoFar: TimeInterval)] = []
        for index in 0..<24 {
            let pts = CMTimeAdd(start, CMTime(seconds: Double(index) * bufferDuration, preferredTimescale: 48_000))
            guard let buffer = makeAudioBuffer(at: pts) else {
                XCTFail("造不出音频样本")
                return
            }
            samples.append((buffer, 0))
        }
        try await appendAudioSamples(samples, to: encoder)

        let url = try await encoder.finish()
        XCTAssertNotNil(url)

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1, "导出的 mp4 应该带一条音轨")

        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.2, "文件不该是空的")

        // 音轨本身也要有内容（24 段 × 21ms ≈ 0.5s）。
        guard let audioTrack = audioTracks.first else { return }
        let audioRange = try await audioTrack.load(.timeRange)
        XCTAssertGreaterThan(audioRange.duration.seconds, 0.4)
    }

    func testPauseIsCutFromAudioTimeline() async throws {
        let encoder = VideoEncoder(configuration: .init(
            width: 64, height: 48, frameRate: 20, includesAudio: true
        ))
        try encoder.prepare(outputURL: outputURL)
        try writeVideo(encoder, frames: 10, step: 0.05)

        let start = CMTime(seconds: 5000, preferredTimescale: 48_000)
        let bufferDuration = 1024.0 / 48_000.0
        // 前 12 段正常，后 12 段是「暂停 2 秒之后」的，时间轴要减掉 2 秒。
        var samples: [(buffer: CMSampleBuffer, pausedSoFar: TimeInterval)] = []
        for index in 0..<24 {
            let wallSeconds = Double(index) * bufferDuration + (index >= 12 ? 2.0 : 0)
            let pts = CMTimeAdd(start, CMTime(seconds: wallSeconds, preferredTimescale: 48_000))
            guard let buffer = makeAudioBuffer(at: pts) else {
                XCTFail("造不出音频样本")
                return
            }
            samples.append((buffer, index >= 12 ? 2.0 : 0))
        }
        try await appendAudioSamples(samples, to: encoder)

        let url = try await encoder.finish()
        XCTAssertNotNil(url)

        let asset = AVURLAsset(url: outputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        // 24 段 × 21.3ms ≈ 0.51s；如果没减掉暂停，时长会变成 2.5s。
        guard let track = audioTracks.first else { return }
        let timeRange = try await track.load(.timeRange)
        XCTAssertLessThan(timeRange.duration.seconds, 1.0, "暂停的 2 秒应该被剪掉")
        XCTAssertGreaterThan(timeRange.duration.seconds, 0.4, "剩下的内容不该被一起丢掉")
    }
}

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// 视频编码。
///
/// 通过 `AVAssetWriter` 写入视频帧和可选音轨。
public final class VideoEncoder {
    public struct Configuration: Sendable {
        public var width: Int
        public var height: Int
        public var frameRate: Int
        /// 视频码率（bps）。
        public var bitrate: Int
        public var fileType: AVFileType
        /// 是否带一条 AAC 音轨。音频样本由调用方按需喂进 `appendAudio`。
        public var includesAudio: Bool
        public var audioSampleRate: Double
        public var audioChannels: Int
        public var audioBitrate: Int

        public init(
            width: Int,
            height: Int,
            frameRate: Int = 30,
            bitrate: Int = 8_000_000,
            fileType: AVFileType = .mp4,
            includesAudio: Bool = false,
            audioSampleRate: Double = 44_100,
            audioChannels: Int = 2,
            audioBitrate: Int = 128_000
        ) {
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.bitrate = bitrate
            self.fileType = fileType
            self.includesAudio = includesAudio
            self.audioSampleRate = audioSampleRate
            self.audioChannels = audioChannels
            self.audioBitrate = audioBitrate
        }
    }

    public enum EncoderError: Error, LocalizedError {
        case writerSetupFailed(underlying: Error?)
        case pixelBufferUnavailable
        case writingFailed(underlying: Error?)
        case noFrames

        public var errorDescription: String? {
            switch self {
            case .writerSetupFailed(let error): return "无法创建录制文件：\(error?.localizedDescription ?? "编码器不可用")"
            case .pixelBufferUnavailable: return "无法准备录制画面"
            case .writingFailed(let error): return "录制文件写入失败：\(error?.localizedDescription ?? "编码器已停止")"
            case .noFrames: return "没有录到可用画面"
            }
        }
    }

    private let configuration: Configuration
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var appendedFrames = 0
    /// 音频轨的第一帧时间戳，用来把系统时钟换算成「从录制开始算」。
    private var firstAudioPTS: CMTime?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var isReady: Bool { writer != nil }

    public func prepare(outputURL: URL) throws {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: configuration.fileType)
            let compression: [String: Any] = [
                AVVideoAverageBitRateKey: configuration.bitrate,
                AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * 2,
            ]
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: configuration.width,
                AVVideoHeightKey: configuration.height,
                AVVideoCompressionPropertiesKey: compression,
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: configuration.width,
                    kCVPixelBufferHeightKey as String: configuration.height,
                ]
            )

            guard writer.canAdd(input) else {
                throw EncoderError.writerSetupFailed(underlying: nil)
            }
            writer.add(input)

            var audioInput: AVAssetWriterInput?
            if configuration.includesAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: configuration.audioSampleRate,
                    AVNumberOfChannelsKey: configuration.audioChannels,
                    AVEncoderBitRateKey: configuration.audioBitrate,
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else {
                    throw EncoderError.writerSetupFailed(underlying: nil)
                }
                writer.add(input)
                audioInput = input
            }

            guard writer.startWriting() else {
                throw EncoderError.writerSetupFailed(underlying: writer.error)
            }
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.audioInput = audioInput
            firstAudioPTS = nil
            appendedFrames = 0
        } catch let error as EncoderError {
            throw error
        } catch {
            throw EncoderError.writerSetupFailed(underlying: error)
        }
    }

    /// 提交一帧（时间为相对会话开始的秒数）。
    public func append(_ image: CGImage, at time: TimeInterval) throws {
        guard let writer, let adaptor, let input else { throw EncoderError.writingFailed(underlying: nil) }
        guard writer.status == .writing else { throw EncoderError.writingFailed(underlying: writer.error) }
        guard input.isReadyForMoreMediaData else { return }

        guard let pool = adaptor.pixelBufferPool else { throw EncoderError.pixelBufferUnavailable }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer
        else { throw EncoderError.pixelBufferUnavailable }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: configuration.width,
                height: configuration.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { throw EncoderError.pixelBufferUnavailable }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: 0,
            y: 0,
            width: configuration.width,
            height: configuration.height
        ))

        let presentationTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
            throw EncoderError.writingFailed(underlying: writer.error)
        }
        appendedFrames += 1
    }

    /// 提交一段音频。
    ///
    /// `pausedSoFar` 是到这一刻为止累计暂停了多久：暂停期间不提交样本，
    /// 恢复后要把这段空白从时间轴上减掉，否则音画会越错越远。
    @discardableResult
    public func appendAudio(_ sampleBuffer: CMSampleBuffer, pausedSoFar: TimeInterval) -> Bool {
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return false }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstAudioPTS == nil { firstAudioPTS = pts }
        guard let first = firstAudioPTS else { return false }

        let elapsed = CMTimeSubtract(pts, first).seconds - pausedSoFar
        guard elapsed >= 0 else { return false }
        let presentationTime = CMTime(seconds: elapsed, preferredTimescale: 600)

        guard let adjusted = Self.retimed(sampleBuffer, to: presentationTime) else { return false }
        return audioInput.append(adjusted)
    }

    private static func retimed(_ sampleBuffer: CMSampleBuffer, to presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    /// 结束写入并返回文件地址。
    @discardableResult
    @MainActor
    public func finish(endingAt time: TimeInterval? = nil) async throws -> URL? {
        guard let writer, let input, let outputURL else { return nil }
        guard writer.status == .writing else {
            let error = EncoderError.writingFailed(underlying: writer.error)
            cancel()
            throw error
        }
        guard appendedFrames > 0 else {
            cancel()
            throw EncoderError.noFrames
        }
        // 静止屏幕可能只有首帧，显式结束时间才能保留用户实际录制的时长。
        if let time, time.isFinite, time > 0 {
            writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        }
        input.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }

        self.writer = nil
        self.input = nil
        self.adaptor = nil
        self.audioInput = nil

        guard writer.status == .completed else { throw EncoderError.writingFailed(underlying: writer.error) }
        return outputURL
    }

    public func cancel() {
        writer?.cancelWriting()
        writer = nil
        input = nil
        adaptor = nil
        audioInput = nil
    }
}

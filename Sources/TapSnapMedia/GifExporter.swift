import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GIFExportError: LocalizedError {
    case emptyFrames
    case destinationFailed
    case invalidParameters
    case frameGenerationFailed(seconds: Double, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .emptyFrames: return "没有可导出的画面"
        case .destinationFailed: return "无法写入 GIF 文件"
        case .invalidParameters: return "GIF 的帧间隔、尺寸或循环次数无效"
        case .frameGenerationFailed(let seconds, let error):
            return String(format: "无法读取视频 %.2f 秒处的画面：%@", seconds, error.localizedDescription)
        }
    }
}

/// 动图导出。
public enum GifExporter {
    /// 把一组帧编码成 GIF。
    /// - Parameters:
    ///   - frames: 按播放顺序排列的帧。
    ///   - frameDelay: 单帧停留时间（秒），例如 30fps 对应 1/30。
    public static func export(
        frames: [CGImage],
        to url: URL,
        frameDelay: Double = 1.0 / 15.0,
        loopCount: Int = 0
    ) throws {
        guard !frames.isEmpty else { throw GIFExportError.emptyFrames }
        try validate(interval: frameDelay, loopCount: loopCount)
        let writer = try Writer(url: url, count: frames.count, loopCount: loopCount)
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            autoreleasepool {
                writer.append(frame, start: Double(index) * frameDelay, end: Double(index + 1) * frameDelay)
            }
        }
        try writer.finish()
    }

    /// 顺序抽帧并写入 GIF，不在内存中收集整段视频的原始帧。
    /// `maximumPixelDimension` 为最长边像素上限，nil 保留视频尺寸。
    /// `playbackSpeed` 为 GIF 播放倍速（0.25...4.0，默认 1.0）；2.0 表示 2 倍速加快，0.5 表示半速慢放。
    /// `progress` 在导出执行线程报告 0...1；只有文件完成后才报告 1。
    /// 调用方可取消所在 Task；取消会终止待处理的抽帧并清理临时文件。
    public static func export(
        videoURL: URL,
        to gifURL: URL,
        sampleInterval: Double = 1.0 / 15.0,
        maximumPixelDimension: Int? = 1280,
        loopCount: Int = 0,
        playbackSpeed: Double = 1.0,
        timeRange: RecordingTimeRange? = nil,
        annotations: [RecordingAnnotation] = [],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try validate(interval: sampleInterval, loopCount: loopCount)
        guard playbackSpeed.isFinite, playbackSpeed >= 0.25, playbackSpeed <= 4.0 else {
            throw GIFExportError.invalidParameters
        }
        if let maximumPixelDimension, !(1...65535).contains(maximumPixelDimension) {
            throw GIFExportError.invalidParameters
        }
        guard videoURL.standardizedFileURL != gifURL.standardizedFileURL else {
            throw GIFExportError.invalidParameters
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: videoURL)
        let assetDuration = try await asset.load(.duration).seconds
        try Task.checkCancellation()
        guard assetDuration.isFinite, assetDuration > 0 else { throw GIFExportError.emptyFrames }
        if let timeRange, timeRange.end > assetDuration + 0.001 { throw GIFExportError.invalidParameters }
        let duration = timeRange?.duration ?? assetDuration
        let startTime = timeRange?.start ?? 0
        let endTime = timeRange?.end ?? assetDuration
        let sourceInterval = sampleInterval * playbackSpeed
        let count = ceil(duration / sourceInterval)
        guard count.isFinite, count > 0, count < Double(Int.max) else { throw GIFExportError.invalidParameters }
        let samples = sampleTimes(start: startTime, end: endTime, interval: sourceInterval, count: Int(count),
                                  annotations: annotations)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maximumPixelDimension {
            generator.maximumSize = CGSize(width: maximumPixelDimension, height: maximumPixelDimension)
        }

        try await withTaskCancellationHandler {
            let writer = try Writer(url: gifURL, count: samples.count, loopCount: loopCount)
            progress?(0)
            for (index, seconds) in samples.enumerated() {
                try Task.checkCancellation()
                let time = CMTime(seconds: seconds, preferredTimescale: 60_000)
                let image: CGImage
                do {
                    image = try await generator.image(at: time).image
                } catch {
                    try Task.checkCancellation()
                    throw GIFExportError.frameGenerationFailed(seconds: seconds - startTime, underlying: error)
                }
                try Task.checkCancellation()
                try autoreleasepool {
                    let active = annotations.filter { RecordingAnnotationRenderer.isActive($0, at: seconds) }
                    let rendered = try RecordingAnnotationRenderer.render(active, over: image)
                    let next = index + 1 < samples.count ? samples[index + 1] : endTime
                    writer.append(rendered,
                                  start: (seconds - startTime) / playbackSpeed,
                                  end: (next - startTime) / playbackSpeed)
                }
                progress?(Double(index + 1) / Double(samples.count + 1))
            }
            try writer.finish()
            progress?(1)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    /// 在普通抽帧之间保留标注的开始与结束，短遮盖也会出现在 GIF。
    private static func sampleTimes(start: Double, end: Double, interval: Double, count: Int,
                                    annotations: [RecordingAnnotation]) -> [Double] {
        let edges = Set(annotations.flatMap { [$0.range.start, $0.range.end] }.filter { start < $0 && $0 < end })
        let replaced = Set(edges.compactMap { edge -> Int? in
            let index = Int(((edge - start) / interval).rounded())
            guard index > 0, index < count, abs(start + Double(index) * interval - edge) < 0.005 else { return nil }
            return index
        })
        let uniform = (0..<count).lazy.filter { !replaced.contains($0) }.map { start + Double($0) * interval }
        return (uniform.filter { $0 < end } + edges).sorted()
    }

    private static func validate(interval: Double, loopCount: Int) throws {
        // GIF 的延迟与循环字段均为 16 位；延迟以百分之一秒存储。
        guard interval.isFinite, interval > 0, interval <= 655.35,
              (0...65535).contains(loopCount) else { throw GIFExportError.invalidParameters }
    }

    private final class Writer {
        let destination: CGImageDestination
        let temporaryURL: URL
        let outputURL: URL

        init(url: URL, count: Int, loopCount: Int) throws {
            outputURL = url
            temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".tapsnap-gif-\(UUID().uuidString).gif")
            guard url.isFileURL,
                  let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL,
                      UTType.gif.identifier as CFString, count, nil) else {
                throw GIFExportError.destinationFailed
            }
            self.destination = destination
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]
            ] as CFDictionary)
        }

        deinit { try? FileManager.default.removeItem(at: temporaryURL) }

        func append(_ frame: CGImage, start: Double, end: Double) {
            // 对时间边界取整，让 15fps 的 6/7 厘秒交替，而不是每帧都取 7 厘秒。
            let delay = max(1, (end * 100).rounded() - (start * 100).rounded()) / 100
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                               kCGImagePropertyGIFUnclampedDelayTime: delay]
            ] as CFDictionary)
        }

        func finish() throws {
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(destination) else { throw GIFExportError.destinationFailed }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
        }
    }
}

/// Lottie 动画播放。
public protocol LottiePlayback: AnyObject {
    func load(json: Data) throws
    func play(loop: Bool)
    func pause()
    func stop()
}

/// 默认空实现：没有接入渲染库时不播动画，但界面逻辑不因此中断。
public final class NullLottiePlayback: LottiePlayback {
    public init() {}
    public func load(json: Data) throws { _ = json }
    public func play(loop: Bool) { _ = loop }
    public func pause() {}
    public func stop() {}
}

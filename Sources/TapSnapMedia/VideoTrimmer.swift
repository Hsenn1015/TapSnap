import AVFoundation
import Foundation

public struct RecordingTimeRange: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public var duration: TimeInterval { end - start }
    public var cmTimeRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                    duration: CMTime(seconds: duration, preferredTimescale: 60_000))
    }

    public init(start: TimeInterval, end: TimeInterval) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw VideoTrimError.invalidRange }
        self.start = start
        self.end = end
    }
}

public enum VideoTrimError: LocalizedError {
    case invalidRange, unavailable, failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "裁剪起止时间无效"
        case .unavailable: return "此视频无法导出片段"
        case .failed(let message): return "片段导出失败：\(message)"
        }
    }
}

public enum VideoTrimmer {
    /// AVFoundation 允许正在导出的会话被另一线程取消；其它属性仍只在导出任务中访问。
    private final class Cancellation: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
        func cancel() { session.cancelExport() }
    }

    /// 保留选区内的音视频，重新编码以避免非关键帧起点产生多余画面。
    public static func export(videoURL: URL, to outputURL: URL, range: RecordingTimeRange,
                              annotations: [RecordingAnnotation] = []) async throws {
        guard videoURL.standardizedFileURL != outputURL.standardizedFileURL else { throw VideoTrimError.invalidRange }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, range.end <= duration + 0.001 else { throw VideoTrimError.invalidRange }
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              exporter.supportedFileTypes.contains(.mp4) else { throw VideoTrimError.unavailable }
        let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".tapsnap-trim-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        exporter.outputURL = temporary
        exporter.outputFileType = .mp4
        exporter.timeRange = range.cmTimeRange
        let edits = annotations.filter { $0.range.start < range.end && range.start < $0.range.end }
        if !edits.isEmpty {
            exporter.videoComposition = try await RecordingAnnotationRenderer.composition(for: asset, annotations: edits)
        }
        try Task.checkCancellation()
        let cancellation = Cancellation(exporter)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                exporter.exportAsynchronously { continuation.resume() }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        guard exporter.status == .completed else {
            throw VideoTrimError.failed(exporter.error?.localizedDescription ?? "编码器未完成")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: outputURL)
        }
    }
}

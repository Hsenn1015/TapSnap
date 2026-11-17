import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// 光标快照。
///
/// 保留光标图像及其热点，用于将光标绘入截图。
public struct CursorSnapshot: Sendable {
    public var image: CGImage?
    public var hotspot: CGPoint
    /// 光标在屏幕全局坐标里的位置。
    public var location: CGPoint

    public init(image: CGImage?, hotspot: CGPoint, location: CGPoint) {
        self.image = image
        self.hotspot = hotspot
        self.location = location
    }

    public static func current() -> CursorSnapshot {
        let location = GlobalPointerBridge.location
        // TODO: 从 NSCursor.current.image 取位图，按屏幕 scale 缩放后返回。
        return CursorSnapshot(image: nil, hotspot: .zero, location: location)
    }
}

/// 避免 `TapSnapScreen` 依赖 `TapSnapSystem` 的强耦合，这里只留一个最小桥接。
enum GlobalPointerBridge {
    static var location: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

/// 实时屏幕流（录屏预览、滚动长截图时持续取帧）。
///
/// 用 `SCStream` 按帧回调。回调在内部串行队列上触发，`onFrame` 里不要直接
/// 碰 UI —— 内容一致，但线程不对。
public final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    public struct Frame: @unchecked Sendable {
        public var image: CGImage
        public var timestamp: Date
    }

    public var isStreaming: Bool { stateLock.withLock { active } }
    public var onFrame: ((Frame) -> Void)?
    /// 系统音频样本（配置了 `capturesAudio` 才会有回调）。
    public var onAudio: ((CMSampleBuffer) -> Void)?
    /// 启动失败或系统中断，在主线程通知调用方。
    public var onError: ((Error) -> Void)?

    private let stateLock = NSLock()
    private var active = false
    private var generation = UUID()
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.sensnap.screen-stream")
    private static let ciContext = CIContext()
    private let loadContent: () async throws -> SCShareableContent

    public override init() {
        loadContent = { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        super.init()
    }

    init(loadContent: @escaping () async throws -> SCShareableContent) {
        self.loadContent = loadContent
        super.init()
    }

    public func start(
        screen: ScreenDescriptor,
        frameRate: Int = 30,
        capturesAudio: Bool = false,
        excludingCurrentApplication: Bool = false,
        includesCursor: Bool = false,
        hideDesktopIcons: Bool = false
    ) {
        let token: UUID? = stateLock.withLock {
            guard !active else { return nil }
            active = true
            generation = UUID()
            return generation
        }
        guard let token else { return }
        Task { [weak self] in
            await self?.startStream(screen: screen, frameRate: frameRate, capturesAudio: capturesAudio,
                                    excludingCurrentApplication: excludingCurrentApplication,
                                    includesCursor: includesCursor, hideDesktopIcons: hideDesktopIcons, token: token)
        }
    }

    private func startStream(
        screen: ScreenDescriptor,
        frameRate: Int,
        capturesAudio: Bool,
        excludingCurrentApplication: Bool,
        includesCursor: Bool,
        hideDesktopIcons: Bool,
        token: UUID
    ) async {
        guard isCurrent(token) else { return }
        do {
            let content = try await loadContent()
            guard isCurrent(token) else { return }
            guard let display = content.displays.first(where: { $0.displayID == screen.id }) else {
                throw CaptureError.noDisplays
            }

            let excludedApps = excludingCurrentApplication
                ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                : []
            let desktopIcons = hideDesktopIcons ? content.windows.filter { window in
                window.windowLayer == Int(CGWindowLevelForKey(.desktopIconWindow)) &&
                    !excludedApps.contains(where: { app in app.processID == window.owningApplication?.processID })
            } : []
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: desktopIcons)
            let configuration = Self.configuration(for: screen, frameRate: frameRate,
                                                   capturesAudio: capturesAudio, includesCursor: includesCursor)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if capturesAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            let installed = stateLock.withLock {
                guard active, generation == token else { return false }
                self.stream = stream
                return true
            }
            guard installed else { return }
            try await stream.startCapture()
            // stop() 可能发生在系统异步启动尚未完成时，完成后再关闭一次。
            if !isCurrent(token) { try? await stream.stopCapture() }
        } catch {
            fail(error, token: token)
        }
    }

    static func configuration(for screen: ScreenDescriptor, frameRate: Int, capturesAudio: Bool,
                              includesCursor: Bool = false) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(screen.pixelSize.width.rounded()))
        configuration.height = max(1, Int(screen.pixelSize.height.rounded()))
        configuration.captureResolution = .best
        configuration.showsCursor = includesCursor
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, frameRate))
        )
        if capturesAudio {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }

        return configuration
    }

    public func stop() {
        let stoppedStream = stateLock.withLock {
            active = false
            generation = UUID()
            let previous = stream
            stream = nil
            return previous
        }
        stoppedStream?.stopCapture { _ in }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        stateLock.withLock { active && generation == token }
    }

    private func fail(_ error: Error, token: UUID) {
        let shouldNotify = stateLock.withLock {
            guard active, generation == token else { return false }
            active = false
            stream = nil
            return true
        }
        guard shouldNotify else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stateLock.withLock({ self.generation == token }) else { return }
            self.onError?(error)
        }
    }

    // MARK: - SCStreamOutput

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard stateLock.withLock({ active && self.stream === stream }) else { return }

        if type == .audio {
            onAudio?(sampleBuffer)
            return
        }
        guard type == .screen else { return }

        // 只有「完整」帧才拿去拼，掉帧时的部分帧会让位移估计错位。
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int,
            status == SCFrameStatus.complete.rawValue
        else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        onFrame?(Frame(image: image, timestamp: Date()))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let token: UUID? = stateLock.withLock {
            self.stream === stream ? generation : nil
        }
        if let token { fail(error, token: token) }
    }
}

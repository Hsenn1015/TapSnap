import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import TapSnapCore
import TapSnapScreen
import TapSnapSystem

public enum RecordError: Error {
    case permissionDenied
    case writerSetupFailed
    case unsupportedFormat(String)
    case startupTimedOut
    case invalidRegion
    case noFrames
    case inputMonitoringUnavailable
}

extension RecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "没有屏幕录制权限"
        case .writerSetupFailed: return "无法创建录制文件"
        case .unsupportedFormat(let format): return "不支持录制格式：\(format)"
        case .startupTimedOut: return "未收到屏幕画面，请重新开始录制"
        case .invalidRegion: return "录制区域超出了屏幕范围"
        case .noFrames: return "没有录到可用画面"
        case .inputMonitoringUnavailable: return "无法显示键鼠提示，请在系统设置中允许 TapSnap 的输入监控权限，或关闭录屏中的键鼠提示"
        }
    }
}

// 注入采集与编码边界，生命周期测试不需要屏幕权限或系统事件。
protocol RecordStream: AnyObject {
    var onFrame: ((ScreenStreamer.Frame) -> Void)? { get set }
    var onAudio: ((CMSampleBuffer) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start(screen: ScreenDescriptor, frameRate: Int, capturesAudio: Bool,
               excludingCurrentApplication: Bool, includesCursor: Bool)
    func stop()
}

protocol RecordEncoding: AnyObject {
    func prepare(outputURL: URL) throws
    func append(_ image: CGImage, at time: TimeInterval) throws
    func appendAudio(_ sampleBuffer: CMSampleBuffer, pausedSoFar: TimeInterval) -> Bool
    @MainActor func finish(endingAt: TimeInterval?) async throws -> URL?
    func cancel()
}

protocol RecordInputMonitoring: AnyObject {
    var onEvent: ((KeyMouseMonitor.Event) -> Void)? { get set }
    var observesKeyboard: Bool { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
}

extension ScreenStreamer: RecordStream {
    func start(screen: ScreenDescriptor, frameRate: Int, capturesAudio: Bool,
               excludingCurrentApplication: Bool, includesCursor: Bool) {
        start(screen: screen, frameRate: frameRate, capturesAudio: capturesAudio,
              excludingCurrentApplication: excludingCurrentApplication, includesCursor: includesCursor,
              hideDesktopIcons: false)
    }
}
extension VideoEncoder: RecordEncoding {}
extension KeyMouseMonitor: RecordInputMonitoring {}

/// error 只在编码队列上写入，主线程排空队列后读取。
private final class RecordWriter: @unchecked Sendable {
    let encoder: RecordEncoding
    var error: Error?
    init(_ encoder: RecordEncoding) { self.encoder = encoder }
}

/// 采集后的音频样本只读传递；编码器调整时间戳时另建副本。
private struct RecordAudioSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

/// 一次录屏会话。
///
/// 协调屏幕和启用的音视频来源，并将采集结果交给 `VideoEncoder`。
///
/// 暂停会把中间的时间轴剪掉；状态通知始终在主线程。
@MainActor
public final class RecordSession {
    public struct Configuration: Sendable {
        public var screen: ScreenDescriptor
        /// 录制区域（相对于该屏幕左上角的点），nil 表示整屏。
        public var rect: CGRect?
        public var frameRate: Int
        public var includesCursor: Bool
        public var includesMicrophone: Bool
        public var includesSystemAudio: Bool
        public var includesCamera: Bool
        public var showsKeyPresses: Bool
        public var showsMouseClicks: Bool
        public var outputURL: URL

        public init(
            screen: ScreenDescriptor,
            rect: CGRect? = nil,
            frameRate: Int = 30,
            includesCursor: Bool = true,
            includesMicrophone: Bool = false,
            includesSystemAudio: Bool = false,
            includesCamera: Bool = false,
            showsKeyPresses: Bool = false,
            showsMouseClicks: Bool = false,
            outputURL: URL
        ) {
            self.screen = screen
            self.rect = rect
            self.frameRate = frameRate
            self.includesCursor = includesCursor
            self.includesMicrophone = includesMicrophone
            self.includesSystemAudio = includesSystemAudio
            self.includesCamera = includesCamera
            self.showsKeyPresses = showsKeyPresses
            self.showsMouseClicks = showsMouseClicks
            self.outputURL = outputURL
        }
    }

    public enum State: Sendable {
        case idle
        case preparing
        case recording
        case paused
        case finishing
        case finished(URL?)
        case failed(String)
    }

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    public var onStateChange: ((State) -> Void)?
    public var onElapsed: ((TimeInterval) -> Void)?

    private var streamer: RecordStream?
    private var microphone: MicrophoneCapture?
    private var camera: CameraCapture?
    private var inputMonitor: RecordInputMonitoring?
    private var overlayTimer: Timer?
    private var lastScreenImage: CGImage?
    private var lastQueuedFrameAt: TimeInterval?
    private var clicks: [(point: CGPoint, time: TimeInterval)] = []
    private var shortcut: (label: String, time: TimeInterval)?
    private var writer: RecordWriter?
    private var startedAt: TimeInterval?
    private var pausedAt: TimeInterval?
    private var stoppedAt: TimeInterval?
    private var accumulatedPause: TimeInterval = 0
    private var generation = UUID()
    private var framePending = false
    private var failure: Error?
    private var startup: CheckedContinuation<Void, Error>?
    private var startupTimer: Task<Void, Never>?
    private var finishingTask: Task<URL?, Error>?
    private let makeStream: () -> RecordStream
    private let makeEncoder: (VideoEncoder.Configuration) -> RecordEncoding
    private let makeInputMonitor: () -> RecordInputMonitoring
    private let now: () -> TimeInterval
    private let startupTimeout: TimeInterval
    /// 编码在独立串行队列上做，取帧回调线程不能直接去写文件。
    private let encodeQueue = DispatchQueue(label: "com.sensnap.record-encode")

    public convenience init(configuration: Configuration) {
        self.init(configuration: configuration, makeStream: { ScreenStreamer() },
                  makeEncoder: { VideoEncoder(configuration: $0) },
                  now: { ProcessInfo.processInfo.systemUptime }, startupTimeout: 15)
    }

    init(configuration: Configuration, makeStream: @escaping () -> RecordStream,
         makeEncoder: @escaping (VideoEncoder.Configuration) -> RecordEncoding,
         now: @escaping () -> TimeInterval, startupTimeout: TimeInterval,
         makeInputMonitor: @escaping () -> RecordInputMonitoring = { KeyMouseMonitor() }) {
        self.configuration = configuration
        self.makeStream = makeStream
        self.makeEncoder = makeEncoder
        self.makeInputMonitor = makeInputMonitor
        self.now = now
        self.startupTimeout = startupTimeout
    }

    deinit {
        startupTimer?.cancel()
        streamer?.stop()
        microphone?.stop()
        camera?.stop()
        inputMonitor?.stop()
        overlayTimer?.invalidate()
        encodeQueue.sync {}
        writer?.encoder.cancel()
    }

    public let configuration: Configuration

    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (pausedAt ?? stoppedAt ?? now()) - startedAt - accumulatedPause)
    }

    public func start() async throws {
        guard case .idle = state else { return }
        try Task.checkCancellation()
        generation = UUID()
        let token = generation
        failure = nil
        state = .preparing
        guard generation == token else { throw CancellationError() }
        do {
            let bounds = CGRect(origin: .zero, size: configuration.screen.frame.size)
            if let rect = configuration.rect, rect.isEmpty || !bounds.contains(rect) {
                throw RecordError.invalidRegion
            }
            let size = outputPixelSize()
            let encoder = makeEncoder(.init(width: size.width, height: size.height,
                                             frameRate: configuration.frameRate,
                                             includesAudio: configuration.includesSystemAudio || configuration.includesMicrophone,
                                             audioSampleRate: 48_000, audioChannels: 2))
            writer = RecordWriter(encoder)
            try encoder.prepare(outputURL: configuration.outputURL)
            if configuration.includesCamera {
                let camera = CameraCapture()
                self.camera = camera
                try await camera.start()
                guard generation == token else { throw CancellationError() }
            }
            try Task.checkCancellation()
            if configuration.showsKeyPresses || configuration.showsMouseClicks {
                let monitor = makeInputMonitor()
                monitor.observesKeyboard = configuration.showsKeyPresses
                monitor.onEvent = { [weak self] event in
                    Task { @MainActor in self?.handleInput(event, token: token) }
                }
                inputMonitor = monitor
                monitor.start()
                guard monitor.isRunning else { throw RecordError.inputMonitoringUnavailable }
            }
        } catch {
            fail(error, token: token)
            throw error
        }

        let streamer = makeStream()
        streamer.onFrame = { [weak self] frame in
            DispatchQueue.main.async { self?.handle(frame.image, token: token) }
        }
        streamer.onAudio = { [weak self] sampleBuffer in
            DispatchQueue.main.async { self?.handleAudio(sampleBuffer, token: token) }
        }
        streamer.onError = { [weak self] error in
            DispatchQueue.main.async { self?.fail(error, token: token) }
        }
        self.streamer = streamer

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                startupTimer = Task { [weak self, startupTimeout] in
                    do { try await Task.sleep(nanoseconds: UInt64(max(0, startupTimeout) * 1_000_000_000)) }
                    catch { return }
                    self?.fail(RecordError.startupTimedOut, token: token)
                }
                streamer.start(screen: configuration.screen, frameRate: configuration.frameRate,
                               capturesAudio: configuration.includesSystemAudio,
                               excludingCurrentApplication: true, includesCursor: configuration.includesCursor)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.cancel()
            }
        }
        guard generation == token else { throw CancellationError() }
    }

    public func pause() {
        guard case .recording = state else { return }
        pausedAt = now()
        state = .paused
        onElapsed?(elapsed)
    }

    public func resume() {
        guard case .paused = state, let pausedAt else { return }
        accumulatedPause += now() - pausedAt
        self.pausedAt = nil
        state = .recording
    }

    /// 结束录制并返回输出文件地址。
    @discardableResult
    public func finish() async throws -> URL? {
        let token = generation
        if let finishingTask {
            let url = try await finishingTask.value
            guard generation == token else { throw CancellationError() }
            return url
        }
        switch state {
        case .idle: return nil
        case .finished(let url): return url
        case .failed: throw failure ?? RecordError.writerSetupFailed
        case .preparing:
            fail(RecordError.noFrames, token: token)
            throw RecordError.noFrames
        case .recording, .paused, .finishing: break
        }
        stoppedAt = now()
        state = .finishing
        guard generation == token else { throw CancellationError() }
        stopCapture()
        encodeQueue.sync {}
        guard generation == token else { throw CancellationError() }
        guard let writer else { throw RecordError.noFrames }
        do {
            if let error = writer.error { throw error }
            let duration = max(elapsed, 1 / Double(max(1, configuration.frameRate)))
            let task = Task { try Task.checkCancellation(); return try await writer.encoder.finish(endingAt: duration) }
            finishingTask = task
            guard let url = try await task.value else { throw RecordError.noFrames }
            guard generation == token else { throw CancellationError() }
            self.writer = nil
            finishingTask = nil
            state = .finished(url)
            return url
        } catch {
            guard generation == token else { throw CancellationError() }
            fail(error, token: token)
            throw error
        }
    }

    public func cancel() {
        generation = UUID()
        stopCapture()
        completeStartup(throwing: CancellationError())
        finishingTask?.cancel()
        finishingTask = nil
        encodeQueue.sync {}
        writer?.encoder.cancel()
        writer = nil
        framePending = false
        startedAt = nil
        pausedAt = nil
        stoppedAt = nil
        accumulatedPause = 0
        state = .idle
    }

    // MARK: - 取帧

    private func handle(_ image: CGImage, token: UUID) {
        guard generation == token else { return }
        if case .paused = state {
            if overlayTimer != nil { lastScreenImage = image }
            return
        }
        if case .preparing = state {
            startedAt = now()
            pausedAt = nil
            stoppedAt = nil
            accumulatedPause = 0
            state = .recording
            guard generation == token, case .recording = state else { return }
            completeStartup()
            if configuration.includesMicrophone {
                let microphone = MicrophoneCapture()
                microphone.onSample = { [weak self] sample in
                    DispatchQueue.main.async { self?.handleAudio(sample, token: token) }
                }
                self.microphone = microphone
                microphone.start()
            }
        }
        guard case .recording = state else { return }
        if configuration.includesCamera || configuration.showsKeyPresses || configuration.showsMouseClicks {
            lastScreenImage = image
            if overlayTimer == nil {
                let timer = Timer(timeInterval: 1 / Double(max(1, configuration.frameRate)), repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let image = self.lastScreenImage else { return }
                        self.handle(image, token: token)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                overlayTimer = timer
            }
        }
        guard !framePending, let writer else { return }
        let time = elapsed
        let configuration = configuration
        if overlayTimer != nil, let lastQueuedFrameAt,
           time - lastQueuedFrameAt < 0.9 / Double(max(1, configuration.frameRate)) { return }
        lastQueuedFrameAt = time
        let overlay = overlayFrame()
        framePending = true
        encodeQueue.async { [weak self] in
            var failure: Error?
            do {
                let frame: CGImage
                if let rect = configuration.rect {
                    let pixelRect = CGRect(x: rect.minX * CGFloat(image.width) / configuration.screen.frame.width,
                                           y: rect.minY * CGFloat(image.height) / configuration.screen.frame.height,
                                           width: rect.width * CGFloat(image.width) / configuration.screen.frame.width,
                                           height: rect.height * CGFloat(image.height) / configuration.screen.frame.height).integral
                    guard let cropped = image.cropping(to: pixelRect) else { throw RecordError.invalidRegion }
                    frame = cropped
                } else {
                    frame = image
                }
                try writer.encoder.append(RecordingCompositor.compose(frame, overlay: overlay), at: time)
            } catch {
                writer.error = error
                failure = error
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.framePending = false
                if let failure { self.fail(failure, token: token) }
                else { self.onElapsed?(self.elapsed) }
            }
        }
    }

    private func handleInput(_ event: KeyMouseMonitor.Event, token: UUID) {
        guard generation == token, case .recording = state else { return }
        switch event.kind {
        case .leftMouseDown, .rightMouseDown:
            guard configuration.showsMouseClicks else { return }
            let local = configuration.rect ?? CGRect(origin: .zero, size: configuration.screen.frame.size)
            let region = local.offsetBy(dx: configuration.screen.frame.minX, dy: configuration.screen.frame.minY)
            guard region.contains(event.location) else { return }
            let point = CGPoint(x: (event.location.x - region.minX) / region.width,
                                y: (event.location.y - region.minY) / region.height)
            clicks.append((point, now()))
        case .keyDown where configuration.showsKeyPresses:
            if let keyCode = event.keyCode,
               let label = RecordingCompositor.shortcutLabel(keyCode: keyCode, flags: event.modifierFlags) {
                shortcut = (label, now())
            }
        default: break
        }
    }

    private func overlayFrame() -> RecordingOverlayFrame {
        let timestamp = now()
        clicks.removeAll { timestamp - $0.time > 0.65 }
        if let shortcut, timestamp - shortcut.time > 1.2 { self.shortcut = nil }
        return RecordingOverlayFrame(camera: camera?.latestFrame,
                                     clicks: clicks.map(\.point), shortcut: shortcut?.label)
    }

    /// 音轨：暂停期间的样本直接丢掉，恢复后由编码器按累计暂停时长把时间轴压回来。
    private func handleAudio(_ sampleBuffer: CMSampleBuffer, token: UUID) {
        guard generation == token, case .recording = state, let writer else { return }
        let paused = accumulatedPause
        let sample = RecordAudioSample(buffer: sampleBuffer)
        encodeQueue.async {
            _ = writer.encoder.appendAudio(sample.buffer, pausedSoFar: paused)
        }
    }

    private func stopCapture() {
        streamer?.onFrame = nil
        streamer?.onAudio = nil
        streamer?.onError = nil
        streamer?.stop()
        streamer = nil
        microphone?.onSample = nil
        microphone?.stop()
        microphone = nil
        camera?.stop()
        camera = nil
        inputMonitor?.onEvent = nil
        inputMonitor?.stop()
        inputMonitor = nil
        overlayTimer?.invalidate()
        overlayTimer = nil
        lastScreenImage = nil
        lastQueuedFrameAt = nil
        clicks.removeAll()
        shortcut = nil
    }

    private func completeStartup(throwing error: Error? = nil) {
        startupTimer?.cancel()
        startupTimer = nil
        let continuation = startup
        startup = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    private func fail(_ error: Error, token: UUID) {
        guard generation == token else { return }
        generation = UUID()
        stoppedAt = now()
        failure = error
        stopCapture()
        completeStartup(throwing: error)
        finishingTask?.cancel()
        finishingTask = nil
        encodeQueue.sync {}
        writer?.encoder.cancel()
        writer = nil
        framePending = false
        state = .failed(error.localizedDescription)
    }

    /// H.264 要求宽高是偶数，取整时顺手抹平。
    private func outputPixelSize() -> (width: Int, height: Int) {
        let scale = configuration.screen.scale
        let size = configuration.rect?.size ?? configuration.screen.frame.size
        func even(_ value: CGFloat) -> Int {
            max(2, Int((value * scale).rounded()) & ~1)
        }
        return (even(size.width), even(size.height))
    }
}

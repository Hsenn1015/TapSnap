import AVFoundation
import CoreMedia
import Foundation

/// 麦克风采集。
///
/// 用 `AVCaptureSession` 采集 PCM 样本并交给视频编码器。
public final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    public var onSample: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.sensnap.microphone-session")
    private let sampleQueue = DispatchQueue(label: "com.sensnap.microphone")
    private let requestAccess: (@escaping (Bool) -> Void) -> Void
    private let runSession: (MicrophoneCapture) -> Void
    private let stopSession: (MicrophoneCapture) -> Void
    private var isConfigured = false
    private var wantsRunning = false
    private var generation: UInt = 0

    public override init() {
        requestAccess = { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) }
        runSession = { $0.configureAndRun() }
        stopSession = { $0.session.stopRunning() }
        super.init()
    }

    init(requestAccess: @escaping (@escaping (Bool) -> Void) -> Void,
         runSession: @escaping (MicrophoneCapture) -> Void,
         stopSession: @escaping (MicrophoneCapture) -> Void) {
        self.requestAccess = requestAccess
        self.runSession = runSession
        self.stopSession = stopSession
        super.init()
    }

    /// 首次调用会弹系统麦克风权限。没授权就静默不开始（录制照样出画面）。
    public func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.wantsRunning else { return }
            self.wantsRunning = true
            self.generation &+= 1
            let generation = self.generation
            self.requestAccess { [weak self] granted in
                self?.sessionQueue.async { [weak self] in
                    guard let self, self.wantsRunning, self.generation == generation else { return }
                    guard granted else {
                        self.wantsRunning = false
                        return
                    }
                    self.runSession(self)
                }
            }
        }
    }

    public func stop() {
        sessionQueue.async {
            self.wantsRunning = false
            self.generation &+= 1
            self.stopSession(self)
        }
    }

    private func configureAndRun() {
        if !isConfigured, !configure() { return }
        if !session.isRunning { session.startRunning() }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return false }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            return false
        }
        session.addOutput(output)

        isConfigured = true
        return true
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSample?(sampleBuffer)
    }
}

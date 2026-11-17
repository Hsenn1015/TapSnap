import AVFoundation
import CoreImage
import Foundation

enum CameraCaptureError: LocalizedError {
    case permissionDenied, unavailable
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "摄像头未获授权，请在系统设置中允许 TapSnap 使用摄像头，或关闭画中画"
        case .unavailable: return "摄像头不可用，请检查设备是否连接或被占用"
        }
    }
}

/// 摄像头始终本地采集，保留最新一帧供录屏编码队列合成。
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sensnap.record-camera")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var generation = UUID()
    private var frame: CGImage?
    private var session: AVCaptureSession?

    var latestFrame: CGImage? { lock.lock(); defer { lock.unlock() }; return frame }

    func start() async throws {
        let token = UUID()
        lock.withLock { generation = token }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard authorized else { throw CameraCaptureError.permissionDenied }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.lock.withLock({ self.generation == token }) else {
                    continuation.resume(throwing: CancellationError()); return
                }
                do {
                    guard let camera = AVCaptureDevice.default(for: .video) else { throw CameraCaptureError.unavailable }
                    let input = try AVCaptureDeviceInput(device: camera)
                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraCaptureError.unavailable }
                    session.addInput(input)
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    session.commitConfiguration()
                    self.session = session
                    session.startRunning()
                    guard session.isRunning else { throw CameraCaptureError.unavailable }
                    continuation.resume()
                } catch {
                    self.session?.stopRunning()
                    self.session = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        lock.withLock { generation = UUID(); frame = nil }
        queue.async { [self] in
            session?.stopRunning()
            session = nil
            lock.withLock { frame = nil }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard session?.isRunning == true, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let snapshot = context.createCGImage(image, from: image.extent) else { return }
        lock.withLock { frame = snapshot }
    }
}

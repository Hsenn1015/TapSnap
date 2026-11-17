import CoreGraphics
import Foundation
import Vision

/// 二维码 / 条形码识别结果。
public struct BarcodeResult: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var payload: String
    /// 归一化坐标（原点左下，Vision 约定）。
    public var normalizedBounds: CGRect
    public var symbology: String

    public init(payload: String, normalizedBounds: CGRect, symbology: String) {
        self.payload = payload
        self.normalizedBounds = normalizedBounds
        self.symbology = symbology
    }
}

/// 二维码识别。
///
/// 用 `VNDetectBarcodesRequest` 识别 QR、Code 128、EAN 等常见码制。
public final class BarcodeDetector {
    public init() {}

    public func detect(in image: CGImage) -> [BarcodeResult] {
        // 不显式设置 symbologies：系统默认就认所有它支持的码制。
        let request = VNDetectBarcodesRequest()

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }

        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            return BarcodeResult(
                payload: payload,
                normalizedBounds: observation.boundingBox,
                symbology: observation.symbology.rawValue
            )
        }
    }
}

/// 人脸检测。
///
/// 使用系统的人脸识别请求返回人脸区域，供自动打码等流程使用。
public final class FaceDetector {
    public init() {}

    /// 返回归一化坐标（原点左下）的人脸框。
    public func detect(in image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).map { $0.boundingBox }
    }
}

/// 界面元素区域检测。
///
/// 使用 Vision 矩形检测为截图选区吸附提供候选边界。
public final class UIRegionDetector {
    public struct Region: Hashable, Sendable {
        public var bounds: CGRect
        /// 置信度，0...1。
        public var confidence: Float

        public init(bounds: CGRect, confidence: Float) {
            self.bounds = bounds
            self.confidence = confidence
        }
    }

    public init() {}

    /// 返回按面积从大到小排序的候选区域（归一化坐标，原点左下）。
    public func detectRegions(in image: CGImage, minimumConfidence: Float = 0.6) -> [Region] {
        let request = VNDetectRectanglesRequest()
        // 工具栏和输入框常是细长的，允许较小的长宽比。
        request.minimumAspectRatio = 0.05
        request.maximumAspectRatio = 1
        request.minimumSize = 0.02
        request.minimumConfidence = minimumConfidence
        request.quadratureTolerance = 12
        request.maximumObservations = 32

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }

        let pixelSize = CGSize(width: image.width, height: image.height)
        return (request.results ?? [])
            .filter { Self.isAlignedWithScreen($0, pixelSize: pixelSize) }
            .map { Region(bounds: $0.boundingBox, confidence: $0.confidence) }
            .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    }

    private static func isAlignedWithScreen(_ observation: VNRectangleObservation, pixelSize: CGSize) -> Bool {
        func isAligned(_ first: CGPoint, _ second: CGPoint, horizontal: Bool) -> Bool {
            let dx = abs(second.x - first.x) * pixelSize.width
            let dy = abs(second.y - first.y) * pixelSize.height
            let length = horizontal ? dx : dy
            let drift = horizontal ? dy : dx
            // 短边允许两像素识别误差，长边允许约 5° 的倾斜。
            return length.isFinite && drift.isFinite && length > 0 && drift <= max(2, length * 0.0875)
        }

        // Vision 的直角容差无法排除旋转矩形。检查四条边，避免把斜边包围盒当成控件。
        return isAligned(observation.topLeft, observation.topRight, horizontal: true)
            && isAligned(observation.bottomLeft, observation.bottomRight, horizontal: true)
            && isAligned(observation.topLeft, observation.bottomLeft, horizontal: false)
            && isAligned(observation.topRight, observation.bottomRight, horizontal: false)
    }
}

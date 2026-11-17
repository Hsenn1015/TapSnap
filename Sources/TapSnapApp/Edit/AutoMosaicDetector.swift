import CoreGraphics
import Foundation
import TapSnapVision
import Vision

enum AutoMosaicDetector {
    static func detect(in image: CGImage, faces: Bool, text: Bool) throws -> [CGRect] {
        var boxes = faces ? FaceDetector().detect(in: image) : []
        if text {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            boxes += (request.results ?? []).map(\.boundingBox)
        }
        return boxes
    }

    /// Vision 的左下原点转换为画布左上原点，只处理用户框入的目标。
    static func documentRects(_ boxes: [CGRect], canvas: CGSize, selection: CGRect) -> [CGRect] {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        return boxes.compactMap { box in
            let rect = CGRect(x: box.minX * canvas.width, y: (1 - box.maxY) * canvas.height,
                              width: box.width * canvas.width, height: box.height * canvas.height)
            guard rect.intersects(selection) else { return nil }
            let padded = rect.insetBy(dx: -4, dy: -4).intersection(canvasRect)
            return padded.isEmpty || padded.isNull ? nil : padded
        }
    }
}

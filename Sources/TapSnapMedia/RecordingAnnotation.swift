import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import TapSnapCore

/// 位置相对转正后的画面，左上角是 (0, 0)，时间保留原录屏时间。
public struct RecordingAnnotation: Equatable, Sendable, Identifiable {
    public enum Kind: Int, CaseIterable, Sendable {
        case arrow, rectangle, text, mask, ellipse, line, pen, highlight

        public var title: String {
            switch self {
            case .arrow: return "箭头"
            case .rectangle: return "方框"
            case .text: return "文字"
            case .mask: return "打码"
            case .ellipse: return "椭圆"
            case .line: return "直线"
            case .pen: return "画笔"
            case .highlight: return "高亮"
            }
        }
    }

    public struct Style: Equatable, Sendable {
        public enum StrokePattern: String, CaseIterable, Sendable {
            case solid, dashed, dotted
        }

        public var color: RGBAColor
        /// 以画面短边为 720 的大小计量，使预览和不同尺寸的导出保持同一比例。
        public var lineWidth: Double
        public var fontSize: Double
        public var fillColor: RGBAColor?
        public var textBackground: RGBAColor?
        public var strokePattern: StrokePattern
        public var isBold: Bool

        public init(color: RGBAColor = .init(red: 0.34, green: 0.89, blue: 0.74),
                    lineWidth: Double = 5.04, fontSize: Double = 36, fillColor: RGBAColor? = nil,
                    textBackground: RGBAColor? = nil, strokePattern: StrokePattern = .solid, isBold: Bool = true) {
            self.color = color
            self.lineWidth = lineWidth
            self.fontSize = fontSize
            self.fillColor = fillColor
            self.textBackground = textBackground
            self.strokePattern = strokePattern
            self.isBold = isBold
        }

        public static func defaults(for kind: Kind) -> Style {
            switch kind {
            case .text: return .init(color: .white, textBackground: .init(white: 0.07, alpha: 0.86))
            case .mask: return .init(color: .black)
            case .highlight: return .init(color: .init(rgb: 0xfcd34d, alpha: 0.44), lineWidth: 24)
            default: return .init()
            }
        }
    }

    public let id: UUID
    public var kind: Kind
    public var startPoint: CGPoint
    public var endPoint: CGPoint
    public var text: String
    public var range: RecordingTimeRange
    public var style: Style
    public var points: [CGPoint]

    public init(id: UUID = UUID(), kind: Kind, startPoint: CGPoint, endPoint: CGPoint,
                text: String = "", range: RecordingTimeRange, style: Style? = nil, points: [CGPoint] = []) {
        self.id = id
        self.kind = kind
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.text = text
        self.range = range
        self.style = style ?? .defaults(for: kind)
        self.points = points
    }
}

/// 保留已解析的轨道和剪辑列表，让连续逐帧只需要查找采样游标。
public final class RecordingFrameTiming {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let segments: [CMTimeMapping]

    public init(asset: AVURLAsset) async throws {
        let precise = AVURLAsset(url: asset.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await precise.loadTracks(withMediaType: .video).first else {
            throw VideoTrimError.unavailable
        }
        let segments = try await track.load(.segments).filter { !$0.isEmpty }.map(\.timeMapping)
        guard !segments.isEmpty else { throw VideoTrimError.unavailable }
        self.asset = precise
        self.track = track
        self.segments = segments
    }

    public func range(at time: TimeInterval) throws -> RecordingTimeRange {
        guard time.isFinite, let first = segments.first, let last = segments.last else {
            throw VideoTrimError.invalidRange
        }
        let requested = CMTime(seconds: min(max(first.target.start.seconds, time),
                                           last.target.end.seconds - 1.0 / 60_000), preferredTimescale: 60_000)
        guard let segment = segments.first(where: { $0.target.containsTime(requested) }) else {
            throw VideoTrimError.unavailable
        }
        // 编码器可能重排帧并写入剪辑列表，采样游标使用媒体时间而播放器使用轨道时间。
        let mediaTime = CMTimeMapTimeFromRangeToRange(requested, fromRange: segment.target, toRange: segment.source)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: mediaTime) else { throw VideoTrimError.unavailable }
        let frameStart = CMTimeMapTimeFromRangeToRange(cursor.presentationTimeStamp,
                                                       fromRange: segment.source, toRange: segment.target)
        let start = max(segment.target.start.seconds, frameStart.seconds)
        var end = segment.target.end.seconds
        if cursor.stepInPresentationOrder(byCount: 1) == 1 {
            let nextFrameStart = CMTimeMapTimeFromRangeToRange(cursor.presentationTimeStamp,
                                                               fromRange: segment.source, toRange: segment.target)
            end = min(end, nextFrameStart.seconds)
        }
        return try .init(start: start, end: end)
    }
}

public enum RecordingAnnotationRenderer {
    /// 调用者提供左上原点、向下为正的画布坐标。
    public static func draw(_ annotations: [RecordingAnnotation], in context: CGContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: CGRect(origin: .zero, size: size))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for annotation in annotations {
            context.beginPath()
            let lineWidth = self.lineWidth(of: annotation, size: size)
            context.setLineWidth(lineWidth)
            context.setStrokeColor(annotation.style.color.cgColor)
            let pattern = annotation.kind == .highlight ? .solid : annotation.style.strokePattern
            switch pattern {
            case .solid: context.setLineDash(phase: 0, lengths: [])
            case .dashed: context.setLineDash(phase: 0, lengths: [lineWidth * 2.5, lineWidth * 1.8])
            case .dotted: context.setLineDash(phase: 0, lengths: [lineWidth * 0.01, lineWidth * 2.3])
            }
            let start = scaled(annotation.startPoint, size: size)
            let end = scaled(annotation.endPoint, size: size)
            let rect = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized
            switch annotation.kind {
            case .arrow:
                let angle = atan2(end.y - start.y, end.x - start.x)
                let tip = min(hypot(end.x - start.x, end.y - start.y) * 0.42, lineWidth * 4)
                context.move(to: start)
                context.addLine(to: end)
                if pattern != .solid {
                    context.strokePath()
                    context.setLineDash(phase: 0, lengths: [])
                }
                for wing in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    context.move(to: CGPoint(x: end.x - cos(angle + wing) * tip, y: end.y - sin(angle + wing) * tip))
                    context.addLine(to: end)
                }
                context.strokePath()
            case .line:
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
            case .rectangle, .ellipse:
                if annotation.kind == .ellipse { context.addEllipse(in: rect) }
                else { context.addRect(rect) }
                if let fill = annotation.style.fillColor {
                    context.setFillColor(fill.cgColor)
                    context.drawPath(using: .fillStroke)
                } else {
                    context.strokePath()
                }
            case .pen, .highlight:
                let points = pathPoints(annotation)
                guard let first = points.first else { continue }
                let origin = scaled(first, size: size)
                if points.allSatisfy({ $0 == first }) {
                    context.setFillColor(annotation.style.color.cgColor)
                    context.fillEllipse(in: CGRect(x: origin.x - lineWidth / 2, y: origin.y - lineWidth / 2,
                                                   width: lineWidth, height: lineWidth))
                } else {
                    context.move(to: origin)
                    for point in points.dropFirst() { context.addLine(to: scaled(point, size: size)) }
                    context.strokePath()
                }
            case .text:
                let layout = textLayout(annotation, size: size)
                if let background = annotation.style.textBackground {
                    context.setFillColor(background.cgColor)
                    context.addPath(CGPath(roundedRect: layout.bounds, cornerWidth: layout.paddingY,
                                           cornerHeight: layout.paddingY, transform: nil))
                    context.fillPath()
                }
                context.saveGState()
                context.translateBy(x: layout.bounds.minX + layout.paddingX, y: layout.bounds.minY + layout.paddingY + layout.ascent)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                context.textPosition = .zero
                CTLineDraw(layout.line, context)
                context.restoreGState()
            case .mask:
                context.saveGState()
                context.setShouldAntialias(false)
                context.setFillColor(annotation.style.color.cgColor.copy(alpha: 1) ?? RGBAColor.black.cgColor)
                context.fill(rect.integral)
                context.restoreGState()
            }
        }
    }

    public static func bounds(of annotation: RecordingAnnotation, size: CGSize) -> CGRect {
        if annotation.kind == .text { return textLayout(annotation, size: size).bounds }
        if annotation.kind == .pen || annotation.kind == .highlight {
            var bounds = CGRect.null
            for point in pathPoints(annotation) {
                bounds = bounds.union(CGRect(origin: scaled(point, size: size), size: .zero))
            }
            let radius = lineWidth(of: annotation, size: size) / 2
            return bounds.insetBy(dx: -radius, dy: -radius)
        }
        let start = scaled(annotation.startPoint, size: size)
        let end = scaled(annotation.endPoint, size: size)
        return CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized
    }

    public static func lineWidth(of annotation: RecordingAnnotation, size: CGSize) -> CGFloat {
        let width = annotation.style.lineWidth
        let referenceWidth = width.isFinite && width > 0 ? width : RecordingAnnotation.Style.defaults(for: annotation.kind).lineWidth
        return max(1, referenceWidth * min(size.width, size.height) / 720)
    }

    public static func composition(for asset: AVAsset, annotations: [RecordingAnnotation]) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoTrimError.unavailable }
        let overlays = OverlayCache()
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage
            let active = annotations.indices.filter { isActive(annotations[$0], at: request.compositionTime.seconds) }
            guard !active.isEmpty else {
                request.finish(with: source, context: nil)
                return
            }
            do {
                let overlay = try overlays.image(for: active, in: annotations, size: source.extent.size)
                let positioned = overlay
                    .transformed(by: CGAffineTransform(translationX: source.extent.minX, y: source.extent.minY))
                request.finish(with: positioned.composited(over: source), context: nil)
            } catch {
                request.finish(with: error)
            }
        }
        composition.sourceTrackIDForFrameTiming = track.trackID
        return composition
    }

    /// 使用实际采样时间，暂停在不等帧距的录屏上也只选择当前画面。
    public static func frameRange(at time: TimeInterval, in asset: AVURLAsset) async throws -> RecordingTimeRange {
        try await RecordingFrameTiming(asset: asset).range(at: time)
    }

    static func isActive(_ annotation: RecordingAnnotation, at time: TimeInterval) -> Bool {
        annotation.range.start <= time && time < annotation.range.end
    }

    static func render(_ annotations: [RecordingAnnotation], over image: CGImage) throws -> CGImage {
        guard !annotations.isEmpty else { return image }
        let size = CGSize(width: image.width, height: image.height)
        let context = try bitmap(size: size)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        drawTopDown(annotations, in: context, size: size)
        guard let result = context.makeImage() else { throw VideoTrimError.failed("无法绘制视频标注") }
        return result
    }

    private static func scaled(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private static func pathPoints(_ annotation: RecordingAnnotation) -> [CGPoint] {
        annotation.points.isEmpty ? [annotation.startPoint, annotation.endPoint] : annotation.points
    }

    private static func textLayout(_ annotation: RecordingAnnotation, size: CGSize)
        -> (line: CTLine, bounds: CGRect, ascent: CGFloat, paddingX: CGFloat, paddingY: CGFloat) {
        let referenceSize = annotation.style.fontSize
        let fontSize = max(8, (referenceSize.isFinite && referenceSize > 0 ? referenceSize : 36)
                           * min(size.width, size.height) / 720)
        let font = CTFontCreateUIFontForLanguage(annotation.style.isBold ? .emphasizedSystem : .system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): annotation.style.color.cgColor
        ]
        let paddingX = fontSize * 0.38
        let paddingY = fontSize * 0.24
        let fullLine = CTLineCreateWithAttributedString(NSAttributedString(string: annotation.text, attributes: attributes))
        let maxWidth = max(0, size.width - paddingX * 2)
        let truncation = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let line = CTLineCreateTruncatedLine(fullLine, Double(maxWidth), .end, truncation) ?? fullLine
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil)) + paddingX * 2
        let height = ascent + descent + paddingY * 2
        let position = scaled(annotation.startPoint, size: size)
        let bounds = CGRect(x: min(position.x, max(0, size.width - width)),
                            y: min(position.y, max(0, size.height - height)), width: width, height: height)
        return (line, bounds, ascent, paddingX, paddingY)
    }

    private static func bitmap(size: CGSize) throws -> CGContext {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VideoTrimError.failed("无法为视频帧分配标注画布")
        }
        return context
    }

    /// 同一时段的标注不随画面像素变化，播放时复用已经绘制的图层。
    private final class OverlayCache: @unchecked Sendable {
        private let images = NSCache<NSString, CIImage>()

        init() {
            images.countLimit = 3
            images.totalCostLimit = 48 * 1024 * 1024
        }

        func image(for indices: [Int], in annotations: [RecordingAnnotation], size: CGSize) throws -> CIImage {
            let key = "\(size.width)x\(size.height):\(indices)" as NSString
            if let cached = images.object(forKey: key) { return cached }
            let context = try bitmap(size: size)
            drawTopDown(indices.map { annotations[$0] }, in: context, size: size)
            guard let overlay = context.makeImage() else { throw VideoTrimError.failed("无法绘制视频标注") }
            let image = CIImage(cgImage: overlay)
            images.setObject(image, forKey: key, cost: overlay.bytesPerRow * overlay.height)
            return image
        }
    }

    private static func drawTopDown(_ annotations: [RecordingAnnotation], in context: CGContext, size: CGSize) {
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(annotations, in: context, size: size)
    }
}

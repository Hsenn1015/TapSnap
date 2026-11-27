import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import TapSnapCore
import TapSnapPrivacy

/// 可设置字体、段落与背景的文字标注。
final class TextItem: EditItem {
    enum BackgroundStyle: String, Codable, Sendable {
        case none
        case solid
        case rounded
    }

    struct Format: Hashable, Sendable {
        var fontFamily = ""
        var isBold = true
        var isItalic = false
        var isUnderlined = false
        var isStruckThrough = false
        var alignment: NSTextAlignment = .left
    }

    let id = UUID()
    let kind: EditItemKind = .text
    var style: EditItemStyle
    var bounds: CGRect
    var text: String
    var background: BackgroundStyle
    /// Maximum total box width (including insets), retained while typing or changing font size.
    var textContainerWidth: CGFloat?
    static let textInset = CGSize(width: 4, height: 2)

    init(text: String = "", bounds: CGRect, style: EditItemStyle = EditItemStyle(), background: BackgroundStyle = .none) {
        self.text = text
        self.bounds = bounds
        self.style = style
        self.background = background
    }

    /// Shared with the native inline editor so caret positions and exported glyphs agree.
    func textAttributes(scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let format = style.textFormat
        let size = max(8, style.fontSize) * scale
        let fonts = NSFontManager.shared
        let systemFont = NSFont.systemFont(ofSize: size, weight: format.isBold ? .bold : .regular)
        let baseFont: NSFont
        if format.fontFamily.isEmpty {
            baseFont = systemFont
        } else {
            baseFont = fonts.font(withFamily: format.fontFamily, traits: format.isBold ? .boldFontMask : [],
                                  weight: format.isBold ? 9 : 5, size: size)
                ?? fonts.font(withFamily: format.fontFamily, traits: [], weight: 5, size: size)
                ?? systemFont
        }
        let font = format.isItalic ? fonts.convert(baseFont, toHaveTrait: .italicFontMask) : baseFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = format.alignment
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: style.resolvedColor) ?? NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        if format.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if format.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let traits = fonts.traits(of: font)
        if format.isItalic && !traits.contains(.italicFontMask) { attributes[.obliqueness] = 0.18 }
        if format.isBold && !traits.contains(.boldFontMask) { attributes[.strokeWidth] = -2.0 }
        return attributes
    }

    /// Size from the same TextKit layout used by NSTextView, including empty final lines.
    func fitToText(maxWidth: CGFloat? = nil) {
        if let maxWidth, maxWidth.isFinite {
            textContainerWidth = max(1, maxWidth)
        }
        let limit = textContainerWidth ?? 100_000
        let layout = makeTextLayout(width: limit)
        let used = layout.manager.usedRect(for: layout.container)
        let extra = layout.manager.extraLineFragmentRect
        let font = layout.font
        let minimumHeight = layout.manager.defaultLineHeight(for: font)
        let naturalWidth = max(min(24, limit), ceil(used.width) + Self.textInset.width * 2)
        // Center and right alignment use the same full box width as the inline editor.
        var width = textContainerWidth != nil && style.textFormat.alignment != .left ? limit : min(limit, naturalWidth)
        let height = ceil(max(minimumHeight, max(used.maxY, extra.maxY))) + Self.textInset.height * 2
        // Natural fitting must not make a wrapped line reflow after committing the editor.
        if width < limit {
            let fitted = makeTextLayout(width: width)
            if fitted.manager.usedRect(for: fitted.container).height > used.height + 0.5 {
                width = limit
            }
        }
        bounds.size = CGSize(width: width, height: height)
    }

    private func makeTextLayout(width: CGFloat) -> (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer, font: NSFont) {
        let attributes = textAttributes()
        let storage = NSTextStorage(string: text, attributes: attributes)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width - Self.textInset.width * 2), height: 100_000))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return (storage, manager, container, attributes[.font] as! NSFont)
    }

    func drawBackground(in context: CGContext, bounds: CGRect) {
        guard background != .none else { return }
        var color = style.textBackgroundColor
        color.alpha *= style.opacity
        context.saveGState()
        context.setFillColor(color.cgColor)
        if background == .rounded {
            let radius = min(6, bounds.width / 2, bounds.height / 2)
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        } else {
            context.fill(bounds)
        }
        context.restoreGState()
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard !text.isEmpty else {
            // 还没有内容时画个虚线框，让用户知道这里有个待输入的文字块。
            context.saveGState()
            context.setStrokeColor(style.resolvedColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 2])
            context.stroke(bounds)
            context.restoreGState()
            return
        }

        drawBackground(in: context, bounds: bounds)

        let layout = makeTextLayout(width: bounds.width)
        let range = layout.manager.glyphRange(for: layout.container)
        context.saveGState()
        context.clip(to: bounds)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let origin = CGPoint(x: bounds.minX + Self.textInset.width, y: bounds.minY + Self.textInset.height)
        layout.manager.drawBackground(forGlyphRange: range, at: origin)
        layout.manager.drawGlyphs(forGlyphRange: range, at: origin)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

/// 马赛克和模糊。
///
/// `autoDetect` 为 true 时先用 UI 区域检测找出人脸/文字再打码。
final class MosaicItem: EditItem {
    enum Mode: Hashable, Sendable {
        case mosaic
        case blur
        case redaction(PrivacyMaskAppearance)

        var redactionAppearance: PrivacyMaskAppearance? {
            if case let .redaction(appearance) = self { return appearance }
            return nil
        }

        var title: String {
            switch self {
            case .mosaic: return "经典像素化"
            case .blur: return "模糊"
            case .redaction(let appearance): return appearance.style.title
            }
        }
    }

    let id = UUID()
    let kind: EditItemKind = .mosaic
    var style: EditItemStyle
    var bounds: CGRect {
        didSet { redactionMask?.bounds = bounds }
    }
    var mode: Mode {
        didSet { updateRedactionMask() }
    }
    var blockSize: Int
    var autoDetect: Bool

    init(
        bounds: CGRect,
        style: EditItemStyle = EditItemStyle(),
        mode: Mode = .mosaic,
        blockSize: Int = 12,
        autoDetect: Bool = false
    ) {
        self.bounds = bounds
        self.style = style
        self.mode = mode
        self.blockSize = blockSize
        self.autoDetect = autoDetect
        updateRedactionMask()
    }

    private var sourceImage: CGImage?
    private static let ciContext = CIContext()
    private(set) var redactionMask: PrivacyMaskItem?

    private func updateRedactionMask() {
        guard let appearance = mode.redactionAppearance else {
            redactionMask = nil
            return
        }
        if let redactionMask {
            redactionMask.appearance = appearance
        } else {
            redactionMask = PrivacyMaskItem(bounds: bounds, appearance: appearance)
        }
        sourceImage = nil
    }

    func prepare(source: CGImage, scale: CGFloat) {
        if let redactionMask {
            redactionMask.prepareBackground(source: source, scale: scale, excluding: [])
        } else {
            sourceImage = source
        }
    }

    func draw(in context: CGContext, scale: CGFloat) {
        if let redactionMask {
            redactionMask.draw(in: context, scale: scale)
            return
        }
        guard let sourceImage, bounds.width > 1, bounds.height > 1 else { return }
        let pixelRect = CGRect(
            x: bounds.minX * scale,
            y: bounds.minY * scale,
            width: bounds.width * scale,
            height: bounds.height * scale
        ).integral
        guard let patch = sourceImage.cropping(to: pixelRect) else { return }

        switch mode {
        case .mosaic:
            // 降到「一格一个像素」再放大回去，就得到块状马赛克。
            let block = max(2, CGFloat(blockSize))
            let columns = max(1, Int((bounds.width / block).rounded()))
            let rows = max(1, Int((bounds.height / block).rounded()))
            guard let small = AnnotateDrawing.downsample(patch, width: columns, height: rows) else { return }
            context.interpolationQuality = .none
            AnnotateDrawing.drawImageUpright(small, in: bounds, context: context)
            context.interpolationQuality = .high
        case .blur:
            guard let blurred = Self.blurred(patch, radius: max(2, CGFloat(blockSize) / 2)) else { return }
            AnnotateDrawing.drawImageUpright(blurred, in: bounds, context: context)
        case .redaction:
            break
        }
    }

    private static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        let input = CIImage(cgImage: image)
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }
}

/// 沿自由笔迹绘制半透明高亮。
final class HighlightItem: EditItem {
    static let widthMultiplier: CGFloat = 4
    static let minimumWidth: CGFloat = 6

    let id = UUID()
    let kind: EditItemKind = .highlight
    var style: EditItemStyle
    private(set) var points: [CGPoint]

    init(points: [CGPoint], style: EditItemStyle) {
        self.points = points
        self.style = style
    }

    static func lineWidth(for style: EditItemStyle) -> CGFloat {
        max(minimumWidth, style.resolvedLineWidth * widthMultiplier)
    }

    private var lineWidth: CGFloat { Self.lineWidth(for: style) }

    var bounds: CGRect {
        get { points.isEmpty ? .zero : inkPath(width: lineWidth).boundingBoxOfPath }
        set {
            let original = bounds
            let delta = CGPoint(x: newValue.minX - original.minX, y: newValue.minY - original.minY)
            points = points.map { $0 + delta }
        }
    }

    func draw(in context: CGContext, scale: CGFloat) {
        context.saveGState()
        context.setAlpha(0.35)
        context.setFillColor(style.resolvedColor)
        context.addPath(inkPath(width: lineWidth))
        context.fillPath()
        context.restoreGState()
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        inkPath(width: lineWidth + 2 * tolerance).contains(point)
    }

    private func inkPath(width: CGFloat) -> CGPath {
        if points.count == 1, let point = points.first {
            let rect = CGRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width)
            return CGPath(ellipseIn: rect, transform: nil)
        }
        return AnnotateDrawing.smoothPath(points).copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round,
                                                      miterLimit: 1)
    }
}

/// 支持数字、带圈数字和字母等格式的序号标注。
final class SerialItem: EditItem {
    enum Format: String, Codable, CaseIterable, Sendable {
        case numeric
        case circled
        case lowerAlpha
        case upperAlpha

        var displayName: String {
            switch self {
            case .numeric: return "1 2 3"
            case .circled: return "① ② ③"
            case .lowerAlpha: return "a b c"
            case .upperAlpha: return "A B C"
            }
        }
    }

    let id = UUID()
    let kind: EditItemKind = .serialNumber
    var style: EditItemStyle
    var bounds: CGRect
    var index: Int
    var format: Format

    init(index: Int, bounds: CGRect, style: EditItemStyle = EditItemStyle(), format: Format = .numeric) {
        self.index = index
        self.bounds = bounds
        self.style = style
        self.format = format
    }

    var label: String {
        switch format {
        case .numeric: return "\(index)"
        case .lowerAlpha: return alphabeticLabel.lowercased()
        case .upperAlpha: return alphabeticLabel
        case .circled:
            return (1...20).contains(index) ? String(UnicodeScalar(0x2460 + index - 1)!) : "(\(index))"
        }
    }

    private var alphabeticLabel: String {
        var number = max(1, index)
        var result = ""
        while number > 0 {
            number -= 1
            result = String(UnicodeScalar(65 + number % 26)!) + result
            number /= 26
        }
        return result
    }

    func draw(in context: CGContext, scale: CGFloat) {
        let diameter = min(bounds.width, bounds.height)
        guard diameter > 0 else { return }
        let circle = CGRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.setFillColor(style.resolvedColor)
        context.fillEllipse(in: circle)
        context.restoreGState()

        let fontScale: CGFloat = label.count >= 3 ? 0.36 : (label.count == 2 ? 0.46 : 0.55)
        let attributed = AnnotateDrawing.attributedText(
            label,
            fontSize: max(7, diameter * fontScale),
            color: CGColor(gray: 1, alpha: 1)
        )
        AnnotateDrawing.drawCentered(attributed, in: circle, context: context)
    }
}

/// 放大镜标注。
final class MagnifierItem: EditItem {
    let id = UUID()
    let kind: EditItemKind = .magnifier
    var style: EditItemStyle
    var bounds: CGRect
    var zoom: CGFloat

    init(bounds: CGRect, style: EditItemStyle = EditItemStyle(), zoom: CGFloat = 2) {
        self.bounds = bounds
        self.style = style
        self.zoom = zoom
    }

    private var sourceImage: CGImage?

    func prepare(source: CGImage, scale: CGFloat) {
        sourceImage = source
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard let sourceImage else { return }
        let radius = min(bounds.width, bounds.height) / 2
        guard radius > 0 else { return }
        let center = bounds.center
        // 圆里显示的是中心附近 2r/zoom 那么大的一块，再放大 zoom 倍填满圆。
        let samplePixels = (radius * 2) / max(1, zoom) * scale
        let pixelRect = CGRect(
            x: center.x * scale - samplePixels / 2,
            y: center.y * scale - samplePixels / 2,
            width: samplePixels,
            height: samplePixels
        ).integral

        let circle = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.saveGState()
        context.addEllipse(in: circle)
        context.clip()
        if let patch = sourceImage.cropping(to: pixelRect) {
            AnnotateDrawing.drawImageUpright(patch, in: circle, context: context)
        }
        context.restoreGState()

        // 白色描边让放大镜在画面上更容易辨认。
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(style.resolvedLineWidth)
        let inset = style.resolvedLineWidth / 2
        context.strokeEllipse(in: circle.insetBy(dx: inset, dy: inset))
        context.restoreGState()
    }
}

/// 水印标注。
///
/// 在选定区域内支持旋转、透明度、居中或平铺。
final class WatermarkItem: EditItem {
    enum Content { case text, timestamp, image }
    let id = UUID()
    let kind: EditItemKind = .watermark
    var style: EditItemStyle
    var bounds: CGRect
    var text: String
    var angle: Double
    var isTiled: Bool
    var content: Content = .text
    var logo: CGImage?
    var includesTime = true
    let capturedAt: Date

    var displayText: String {
        guard content == .timestamp else { return text }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = includesTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        return formatter.string(from: capturedAt)
    }

    init(text: String, bounds: CGRect, style: EditItemStyle = EditItemStyle(), angle: Double = -30, isTiled: Bool = true,
         capturedAt: Date = Date()) {
        self.capturedAt = capturedAt
        self.text = text
        self.bounds = bounds
        self.style = style
        self.angle = angle
        self.isTiled = isTiled
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if content == .image {
            guard let logo else { return }
            let factor = min(bounds.width / CGFloat(logo.width), bounds.height / CGFloat(logo.height))
            let size = CGSize(width: CGFloat(logo.width) * factor, height: CGFloat(logo.height) * factor)
            context.saveGState()
            context.translateBy(x: bounds.midX, y: bounds.midY)
            context.scaleBy(x: 1, y: -1)
            context.setAlpha(style.opacity)
            context.interpolationQuality = .high
            context.draw(logo, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
            return
        }
        let label = displayText
        guard !label.isEmpty else { return }
        let attributed = AnnotateDrawing.attributedText(
            label,
            fontSize: max(8, style.fontSize),
            color: style.resolvedColor,
            bold: false
        )
        let size = AnnotateDrawing.measure(attributed)
        guard size.width > 0, size.height > 0 else { return }

        let stepX = max(size.width + 48, 96)
        let stepY = max(size.height + 36, 56)
        let reach = hypot(bounds.width, bounds.height) / 2

        context.saveGState()
        context.clip(to: bounds)
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: angle * .pi / 180)
        if !isTiled {
            AnnotateDrawing.drawCentered(attributed,
                in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                context: context)
            context.restoreGState()
            return
        }
        var row = -reach
        while row < reach {
            var column = -reach
            while column < reach {
                AnnotateDrawing.drawCentered(
                    attributed,
                    in: CGRect(x: column, y: row - size.height / 2, width: size.width, height: size.height),
                    context: context
                )
                column += stepX
            }
            row += stepY
        }
        context.restoreGState()
    }
}

/// 带箭头的自由曲线，可用来标示流程和方向。
final class PathTagItem: EditItem {
    let id = UUID()
    let kind: EditItemKind = .pathTag
    var style: EditItemStyle
    var points: [CGPoint]
    var showsArrowHead: Bool

    init(points: [CGPoint] = [], style: EditItemStyle = EditItemStyle(), showsArrowHead: Bool = true) {
        self.points = points
        self.style = style
        self.showsArrowHead = showsArrowHead
    }

    var bounds: CGRect {
        get {
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
        }
        set {
            let delta = CGPoint(x: newValue.minX - bounds.minX, y: newValue.minY - bounds.minY)
            points = points.map { $0 + delta }
        }
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard points.count > 1 else { return }
        let (shaft, head) = paths

        context.saveGState()
        AnnotateDrawing.configureStroke(style, in: context)
        context.setFillColor(style.resolvedColor)
        context.setLineJoin(.round)
        context.addPath(shaft)
        context.strokePath()
        if let head {
            context.addPath(head)
            context.fillPath()
        }
        context.restoreGState()
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        guard points.count > 1 else { return false }
        let (shaft, head) = paths
        if AnnotateDrawing.hitsStroke(shaft, at: point, width: style.resolvedLineWidth, tolerance: tolerance) { return true }
        guard let head else { return false }
        return head.contains(point) || AnnotateDrawing.hitsStroke(head, at: point, width: 0, tolerance: tolerance)
    }

    private var paths: (shaft: CGPath, head: CGPath?) {
        guard showsArrowHead, let tip = points.last, let previous = points.dropLast().last else {
            return (AnnotateDrawing.smoothPath(points), nil)
        }
        let angle = atan2(tip.y - previous.y, tip.x - previous.x)
        let headLength = max(AnnotateDrawing.minimumHeadLength, style.resolvedLineWidth * 3.5)
        let shaftEnd = CGPoint(x: tip.x - cos(angle) * headLength * 0.85,
                               y: tip.y - sin(angle) * headLength * 0.85)
        let head = AnnotateDrawing.arrowHead(tip: tip, angle: angle, length: headLength, width: headLength * 0.7)
        return (AnnotateDrawing.smoothPath(Array(points.dropLast()) + [shaftEnd]), head)
    }
}

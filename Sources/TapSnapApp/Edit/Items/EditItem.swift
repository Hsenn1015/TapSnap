import CoreGraphics
import Foundation
import TapSnapCore
import TapSnapPrivacy

/// 标注项的种类。
enum EditItemKind: String, Codable, CaseIterable, Sendable {
    case arrow
    case line
    case rectangle
    case ellipse
    case pen
    case text
    case mosaic
    case highlight
    case serialNumber
    case magnifier
    case watermark
    case pathTag
    case polygon
    case spotlight
    case privacy

    var isShape: Bool { self == .rectangle || self == .ellipse || self == .polygon }
    var usesSketchPoints: Bool { self == .pen || self == .pathTag || self == .highlight }
    var supportsHandDrawn: Bool { isShape || self == .arrow || self == .line }
}

/// 标注项的通用样式。
struct EditItemStyle: Hashable, Sendable {
    enum StrokeStyle: Hashable, Sendable {
        case standard, handDrawn
    }

    enum HandDrawnRoughness: Hashable, Sendable {
        case subtle, natural, pronounced, expressive
    }

    enum HandDrawnPen: Hashable, Sendable {
        case single, sketch, ink
    }

    enum HandDrawnFill: CaseIterable, Hashable, Sendable {
        case hachure, crossHatch, zigzag, horizontal, dots, solid
    }

    enum StrokePattern: Hashable, Sendable {
        case solid, dashed, dotted
    }

    enum ShapeFill: Hashable, Sendable {
        case outline, fill, fillAndOutline
    }

    var color: RGBAColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var opacity: Double
    var strokeStyle: StrokeStyle = .standard
    var handDrawnPen: HandDrawnPen = .sketch
    var handDrawnRoughness: HandDrawnRoughness = .natural
    var handDrawnFill: HandDrawnFill = .hachure
    var strokePattern: StrokePattern = .solid
    var shapeFill: ShapeFill = .outline
    var fillColor: RGBAColor?
    var cornerRadius: CGFloat = 0
    var textFormat = TextItem.Format()
    var textBackgroundColor = RGBAColor(white: 0, alpha: 0.65)

    var shapeFillColor: RGBAColor {
        if let fillColor { return fillColor }
        var fill = color
        if shapeFill == .fillAndOutline {
            fill.alpha *= strokeStyle == .handDrawn && handDrawnFill != .solid ? 0.62 : 0.25
        }
        return fill
    }

    init(
        color: RGBAColor = RGBAColor(rgb: 0xFF3B30),
        lineWidth: CGFloat = 3,
        fontSize: CGFloat = 14,
        opacity: Double = 1
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.opacity = opacity
    }
}

/// 所有可绘制标注项的协议。
///
/// 各类图元实现统一的绘制与命中接口，共享值类型的样式配置。
protocol EditItem: AnyObject, Identifiable {
    var id: UUID { get }
    var kind: EditItemKind { get }
    var style: EditItemStyle { get set }
    /// 在画布坐标系里的包围盒（原点左上）。
    var bounds: CGRect { get set }

    /// 画之前拿到底图，马赛克 / 放大镜这类需要采样原图的条目才用得上。
    func prepare(source: CGImage, scale: CGFloat)

    /// 把自己画进上下文。
    func draw(in context: CGContext, scale: CGFloat)

    /// 命中测试，用于选中与拖动。
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool
}

extension EditItem {
    func prepare(source: CGImage, scale: CGFloat) {}

    var privacyMask: PrivacyMaskItem? {
        (self as? PrivacyMaskItem) ?? (self as? MosaicItem)?.redactionMask
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat = 4) -> Bool {
        bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }
}

final class PrivacyMaskItem: EditItem {
    let id = UUID()
    let kind: EditItemKind = .privacy
    var bounds: CGRect
    var style = EditItemStyle()
    var appearance: PrivacyMaskAppearance
    private var backgroundPatch: (source: CGImage, rect: CGRect, excluded: [CGRect],
                                  appearance: PrivacyMaskAppearance, image: CGImage?)?

    init(bounds: CGRect, appearance: PrivacyMaskAppearance) {
        self.bounds = bounds
        self.appearance = appearance
    }

    func pixelBounds(scale: CGFloat) -> CGRect {
        bounds.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
    }

    func prepareBackground(source: CGImage, scale: CGFloat, excluding masks: [CGRect]) {
        guard appearance.style.usesSurroundings else {
            backgroundPatch = nil
            return
        }
        let rect = pixelBounds(scale: scale)
        let outset = (PrivacyMask.samplingOutset * scale).rounded(.up)
        let neighborhood = rect.insetBy(dx: -outset, dy: -outset)
        let nearby = masks.filter { $0.intersects(neighborhood) }
        if let backgroundPatch, backgroundPatch.source === source, backgroundPatch.rect == rect,
           backgroundPatch.excluded == nearby, backgroundPatch.appearance == appearance { return }
        let patch = PrivacyMask.backgroundPatch(around: rect, in: source, appearance: appearance,
                                                scale: scale, excluding: nearby)
        backgroundPatch = (source, rect, nearby, appearance, patch)
    }

    func draw(in context: CGContext, scale: CGFloat) {
        let pixels = pixelBounds(scale: scale)
        let rect = pixels.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        PrivacyMask.draw(rect, appearance: appearance, in: context, patch: backgroundPatch?.image)
    }
}

/// 保存标注图元、底图和裁剪范围的文档。
final class EditDocument {
    let baseImage: CGImage
    let scale: CGFloat
    private(set) var items: [any EditItem]
    private var sampledSource: (rects: [CGRect], image: CGImage)?
    var selectedItemID: UUID?
    /// 裁剪框（画布坐标），nil 表示不裁剪。
    var cropRect: CGRect?

    init(baseImage: CGImage, scale: CGFloat = 1, items: [any EditItem] = []) {
        self.baseImage = baseImage
        self.scale = scale
        self.items = items
    }

    var canvasSize: CGSize {
        CGSize(width: CGFloat(baseImage.width) / scale, height: CGFloat(baseImage.height) / scale)
    }

    func append(_ item: any EditItem) {
        items.append(item)
        selectedItemID = item.id
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        if selectedItemID == id { selectedItemID = nil }
    }

    func item(at point: CGPoint) -> (any EditItem)? {
        // 后加入的在上面，命中测试要从后往前。
        items.reversed().first { $0.privacyMask != nil && $0.hitTest(point) }
            ?? items.reversed().first { item in
                if item.kind == .highlight { return item.hitTest(point, tolerance: 4) }
                return item.hitTest(point)
            }
    }

    var selectedItem: (any EditItem)? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    /// 当前选中项能不能拖边框改大小。
    /// 按路径定义的标注，修改包围盒只会平移，所以只允许整体拖动。
    var canResizeSelectedItem: Bool {
        guard let selectedItem else { return false }
        switch selectedItem.kind {
        case .arrow, .line, .pen, .pathTag, .highlight:
            return false
        default:
            return true
        }
    }

    /// 放大镜和普通马赛克只采样已经遮住隐私区域的底图。
    func sourceForEffects() throws -> CGImage {
        let rects = privacyPixelBounds
        if let sampledSource, sampledSource.rects == rects { return sampledSource.image }
        let image = try PrivacyMask.flattened(baseImage, covering: rects)
        sampledSource = rects.isEmpty ? nil : (rects, image)
        return image
    }

    var privacyPixelBounds: [CGRect] {
        items.compactMap { $0.privacyMask?.pixelBounds(scale: scale) }
    }

    var outputPixelBounds: CGRect {
        let full = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        guard let cropRect, cropRect.width > 0, cropRect.height > 0 else { return full }
        let crop = cropRect.applying(CGAffineTransform(scaleX: scale, y: scale)).integral.intersection(full)
        return crop.isEmpty ? full : crop
    }

    func drawItems(in context: CGContext, excluding excludedID: UUID? = nil, dirtyRect: CGRect? = nil) {
        // A redaction stays on top even when another annotation is added afterwards.
        for item in items where item.privacyMask == nil && item.id != excludedID {
            if item is MagnifierItem || item is MosaicItem {
                guard let safeSource = try? sourceForEffects() else { continue }
                item.prepare(source: safeSource, scale: scale)
            } else {
                item.prepare(source: baseImage, scale: scale)
            }
            item.draw(in: context, scale: scale)
        }
        let masks = items.compactMap(\.privacyMask)
        let excluded = masks.map { $0.pixelBounds(scale: scale) }
        let outset = PrivacyMask.feather + 1 / scale
        let privacyArea = dirtyRect?.insetBy(dx: -outset, dy: -outset)
        for item in masks where privacyArea?.intersects(item.bounds) ?? true {
            item.prepareBackground(source: baseImage, scale: scale, excluding: excluded)
            item.draw(in: context, scale: scale)
        }
    }

    /// 把底图与所有标注合成为最终图片。
    func render() throws -> CGImage {
        if items.isEmpty, cropRect == nil { return baseImage }
        let pixelSize = CGSize(
            width: max(1, (canvasSize.width * scale).rounded()),
            height: max(1, (canvasSize.height * scale).rounded())
        )
        guard let context = CGContext(
            data: nil,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw EditRenderError.contextCreationFailed
        }

        context.interpolationQuality = .high
        context.draw(baseImage, in: CGRect(origin: .zero, size: pixelSize))

        // 标注用的是「原点左上、y 向下、单位点」，这里把 CTM 掰到那个坐标系，
        // 线的粗细和字号就不用每处再乘 scale。
        context.saveGState()
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: scale, y: -scale)
        drawItems(in: context)
        context.restoreGState()

        guard let composed = context.makeImage() else {
            throw EditRenderError.contextCreationFailed
        }
        let crop = outputPixelBounds
        if crop.size == pixelSize {
            return composed
        }
        guard let cropped = composed.cropping(to: crop) else { throw EditRenderError.contextCreationFailed }
        return cropped
    }
}

enum EditRenderError: Error {
    case notImplemented
    case contextCreationFailed
}

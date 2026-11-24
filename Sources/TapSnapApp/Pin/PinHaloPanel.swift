import AppKit
import TapSnapConfig
import TapSnapCore
import TapSnapSystem

/// 从贴图自身快速提取的左右半区主色，用于「自适应取色溢光」。
struct PinAmbientPalette: Equatable {
    var left: RGBAColor
    var right: RGBAColor

    static let fallback = PinAmbientPalette(
        left: RGBAColor(rgb: 0x38bdf8, alpha: 1),
        right: RGBAColor(rgb: 0xa78bfa, alpha: 1)
    )

    /// 缩小到 8×8 采样左右主色（耗时 < 0.2ms），并对高饱和区域加权让背光更有氛围感。
    static func extract(from image: CGImage) -> PinAmbientPalette {
        let size = 8
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .fallback
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        func average(columns: Range<Int>) -> RGBAColor {
            var rSum = 0.0, gSum = 0.0, bSum = 0.0, wSum = 0.0
            for y in 0..<size {
                for x in columns {
                    let offset = (y * size + x) * 4
                    let alpha = Double(pixels[offset + 3]) / 255.0
                    guard alpha > 0.08 else { continue }
                    let r = Double(pixels[offset]) / 255.0 / alpha
                    let g = Double(pixels[offset + 1]) / 255.0 / alpha
                    let b = Double(pixels[offset + 2]) / 255.0 / alpha
                    let maxC = max(r, max(g, b))
                    let minC = min(r, min(g, b))
                    let chroma = maxC - minC
                    // 给鲜艳像素更高权重，同时避免纯黑或纯白完全主导背光。
                    let weight = alpha * (0.25 + chroma * 3.2)
                    rSum += r * weight
                    gSum += g * weight
                    bSum += b * weight
                    wSum += weight
                }
            }
            guard wSum > 0.01 else { return fallback.left }
            var r = min(1, max(0, rSum / wSum))
            var g = min(1, max(0, gSum / wSum))
            var b = min(1, max(0, bSum / wSum))
            // 适度提亮低亮度暗色并轻微增强饱和度，避免白图或黑图变成灰泥。
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            if maxC - minC < 0.08 {
                // 几乎纯灰/纯白/纯黑的截图，给出清爽冷灰蓝氛围光。
                return RGBAColor(red: 0.42, green: 0.56, blue: 0.86, alpha: 1)
            }
            let mid = (maxC + minC) * 0.5
            let boost = 1.22
            r = min(1, max(0, mid + (r - mid) * boost))
            g = min(1, max(0, mid + (g - mid) * boost))
            b = min(1, max(0, mid + (b - mid) * boost))
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            if luma < 0.35 {
                let lift = 0.35 - luma
                r = min(1, r + lift)
                g = min(1, g + lift)
                b = min(1, b + lift)
            }
            return RGBAColor(red: r, green: g, blue: b, alpha: 1)
        }

        return PinAmbientPalette(left: average(columns: 0..<4), right: average(columns: 4..<8))
    }
}

/// 贴图阴影完整视觉参数。
struct PinShadowAppearance: Equatable {
    var style: PinShadowStyle = .auroraAmbient
    var intensity: Double = 1.0
    var spread: Double = 1.0
    var ambientPalette: PinAmbientPalette = .fallback

    init(
        style: PinShadowStyle = .auroraAmbient,
        intensity: Double = 1.0,
        spread: Double = 1.0,
        ambientPalette: PinAmbientPalette = .fallback
    ) {
        self.style = style
        self.intensity = min(max(intensity, 0.5), 1.6)
        self.spread = min(max(spread, 0.6), 1.5)
        self.ambientPalette = ambientPalette
    }

    init(settings: TapSnapConfig.Settings.Pin, ambientPalette: PinAmbientPalette = .fallback) {
        self.init(
            style: settings.shadowStyle,
            intensity: settings.shadowIntensity,
            spread: settings.shadowSpread,
            ambientPalette: ambientPalette
        )
    }
}

/// 贴图阴影与边框绘制（供 `PinHaloPanel` 和设置页实时预览共用）。
enum PinShadowArtwork {
    static func draw(_ appearance: PinShadowAppearance, in context: CGContext, bounds: CGRect, opening: CGRect) {
        guard !opening.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }

        // 保留矩形开口，透明图片的像素也不会被阴影或光晕染色。
        context.addRect(bounds)
        context.addRect(opening)
        context.clip(using: .evenOdd)

        let d = appearance.intensity
        let s = CGFloat(appearance.spread)

        switch appearance.style {
        case .auroraAmbient:
            drawAuroraAmbient(in: context, opening: opening, depth: d, spread: s)
        case .elevation:
            drawElevation(in: context, opening: opening, depth: d, spread: s)
        case .ambilight:
            drawAmbilight(in: context, opening: opening, palette: appearance.ambientPalette, depth: d, spread: s)
        case .frostedBezel:
            drawFrostedBezel(in: context, opening: opening, depth: d, spread: s)
        case .crispPaper:
            drawCrispPaper(in: context, opening: opening, depth: d, spread: s)
        case .neonHalo:
            drawNeonHalo(in: context, opening: opening, depth: d, spread: s)
        }
    }

    private static func drawAuroraAmbient(in context: CGContext, opening: CGRect, depth d: Double, spread s: CGFloat) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // 1. 深层环境悬浮阴影，拉开贴图与下方窗口的纵深层次。
        context.setShadow(offset: CGSize(width: 0, height: -5 * s), blur: 18 * s,
                          color: CGColor(gray: 0, alpha: min(0.78, 0.44 * d)))
        context.fill(opening)

        // 2. 近距离接触阴影，让浅色贴图贴在白底界面上边缘依然清晰锐利。
        context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 5.5 * s,
                          color: CGColor(gray: 0, alpha: min(0.72, 0.34 * d)))
        context.fill(opening)

        // 3. 柔和双色极光微晕，保留 TapSnap 品牌辨识度。
        let (left, right) = opening.divided(atDistance: opening.width / 2, from: .minXEdge)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setShadow(offset: .zero, blur: 10 * s,
                          color: CGColor(red: 0.25, green: 0.83, blue: 0.77, alpha: min(0.62, 0.14 * d)))
        context.fill(left)
        context.setShadow(offset: .zero, blur: 10 * s,
                          color: CGColor(red: 0.61, green: 0.50, blue: 0.95, alpha: min(0.62, 0.14 * d)))
        context.fill(right)

        // 4. 极细外轮廓描边，防止浅灰边界在亮底上隐身。
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: min(0.50, 0.24 * d)))
        context.setLineWidth(1)
        context.stroke(opening.insetBy(dx: -0.5, dy: -0.5))
    }

    private static func drawElevation(in context: CGContext, opening: CGRect, depth d: Double, spread s: CGFloat) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        // 远景环境影 + 中景定向影 + 近景接触影，纯中性无色偏。
        context.setShadow(offset: CGSize(width: 0, height: -9 * s), blur: 20 * s,
                          color: CGColor(gray: 0, alpha: min(0.74, 0.36 * d)))
        context.fill(opening)

        context.setShadow(offset: CGSize(width: 0, height: -3.5 * s), blur: 9 * s,
                          color: CGColor(gray: 0, alpha: min(0.72, 0.30 * d)))
        context.fill(opening)

        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5 * s,
                          color: CGColor(gray: 0, alpha: min(0.68, 0.26 * d)))
        context.fill(opening)

        // 深浅自适应双层微边（暗边托亮底，柔白边托暗底）。
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: min(0.45, 0.22 * d)))
        context.setLineWidth(1)
        context.stroke(opening.insetBy(dx: -0.5, dy: -0.5))

        context.setStrokeColor(CGColor(gray: 1, alpha: min(0.32, 0.16 * d)))
        context.setLineWidth(0.75)
        context.stroke(opening.insetBy(dx: -1.25, dy: -1.25))
    }

    private static func drawAmbilight(
        in context: CGContext,
        opening: CGRect,
        palette: PinAmbientPalette,
        depth d: Double,
        spread s: CGFloat
    ) {
        // 1. 中性触地托影，保持清晰轮廓。
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setShadow(offset: CGSize(width: 0, height: -4.5 * s), blur: 12 * s,
                          color: CGColor(gray: 0, alpha: min(0.65, 0.30 * d)))
        context.fill(opening)

        // 2. 自适应取色左右漫射背光。
        let (left, right) = opening.divided(atDistance: opening.width / 2, from: .minXEdge)
        let bleedAlpha = min(0.85, 0.48 * d)
        let leftColor = CGColor(red: palette.left.red, green: palette.left.green, blue: palette.left.blue, alpha: bleedAlpha)
        let rightColor = CGColor(red: palette.right.red, green: palette.right.green, blue: palette.right.blue, alpha: bleedAlpha)

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setShadow(offset: CGSize(width: 0, height: -2.5 * s), blur: 18 * s, color: leftColor)
        context.fill(left)
        context.setShadow(offset: CGSize(width: 0, height: -2.5 * s), blur: 18 * s, color: rightColor)
        context.fill(right)

        // 3. 克制外描边。
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: min(0.45, 0.22 * d)))
        context.setLineWidth(1)
        context.stroke(opening.insetBy(dx: -0.5, dy: -0.5))
    }

    private static func drawFrostedBezel(in context: CGContext, opening: CGRect, depth d: Double, spread s: CGFloat) {
        let bezel: CGFloat = 3.5
        let outer = opening.insetBy(dx: -bezel, dy: -bezel)
        let outerPath = CGPath(roundedRect: outer, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)

        // 1. 玻璃片下方的干净悬浮落影。
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setShadow(offset: CGSize(width: 0, height: -6.5 * s), blur: 17 * s,
                          color: CGColor(gray: 0, alpha: min(0.75, 0.40 * d)))
        context.addPath(outerPath)
        context.fillPath()

        context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4.5 * s,
                          color: CGColor(gray: 0, alpha: min(0.65, 0.28 * d)))
        context.addPath(outerPath)
        context.fillPath()

        // 2. 半透明磨砂晶体画框填充（竖向轻渐变）。
        context.saveGState()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addPath(outerPath)
        context.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.78),
            CGColor(red: 0.88, green: 0.91, blue: 0.96, alpha: 0.62)
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: outer.midX, y: outer.maxY),
                end: CGPoint(x: outer.midX, y: outer.minY),
                options: []
            )
        }
        context.restoreGState()

        // 3. 外暗内亮晶体倒角线。
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: min(0.55, 0.28 * d)))
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.strokePath()

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.65))
        context.setLineWidth(0.75)
        context.addPath(CGPath(roundedRect: outer.insetBy(dx: 1.3, dy: 1.3), cornerWidth: 3.2, cornerHeight: 3.2, transform: nil))
        context.strokePath()
    }

    private static func drawCrispPaper(in context: CGContext, opening: CGRect, depth d: Double, spread s: CGFloat) {
        let offX = 4.5 * s
        let offY = -5.5 * s

        // 1. 轻微底部柔影，避免生硬锯齿感。
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setShadow(offset: CGSize(width: offX * 1.15, height: offY * 1.15), blur: 7.5 * s,
                          color: CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: min(0.60, 0.22 * d)))
        context.fill(opening)

        // 2. 实体卡片偏移硬影。
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: min(0.72, 0.34 * d)))
        context.fill(opening.offsetBy(dx: offX, dy: offY))

        // 3. 锐利墨色外框。
        context.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: min(0.88, 0.60 * d)))
        context.setLineWidth(1.4)
        context.stroke(opening.insetBy(dx: -0.7, dy: -0.7))
    }

    private static func drawNeonHalo(in context: CGContext, opening: CGRect, depth d: Double, spread s: CGFloat) {
        // 1. 深色托底，保证亮白界面上霓虹也能鲜明呈现。
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setShadow(offset: CGSize(width: 0, height: -2.5 * s), blur: 10 * s,
                          color: CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: min(0.72, 0.40 * d)))
        context.fill(opening)

        // 2. 青蓝—兰紫双色外层辉光与紧致内晕。
        let (left, right) = opening.divided(atDistance: opening.width / 2, from: .minXEdge)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setShadow(offset: .zero, blur: 15 * s,
                          color: CGColor(red: 0.22, green: 0.74, blue: 0.97, alpha: min(0.90, 0.56 * d)))
        context.fill(left)
        context.setShadow(offset: .zero, blur: 15 * s,
                          color: CGColor(red: 0.75, green: 0.52, blue: 0.99, alpha: min(0.90, 0.56 * d)))
        context.fill(right)

        context.setShadow(offset: .zero, blur: 4.5 * s,
                          color: CGColor(red: 0.49, green: 0.83, blue: 0.99, alpha: min(0.92, 0.65 * d)))
        context.fill(opening)

        // 3. 纤细电光渐变描边。
        context.saveGState()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        let strokeRect = opening.insetBy(dx: -0.9, dy: -0.9)
        let strokePath = CGPath(rect: strokeRect, transform: nil).copy(
            strokingWithWidth: 1.8, lineCap: .square, lineJoin: .miter, miterLimit: 2
        )
        context.addPath(strokePath)
        context.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1),
            CGColor(red: 0.51, green: 0.55, blue: 0.97, alpha: 1),
            CGColor(red: 0.91, green: 0.47, blue: 0.98, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: strokeRect.minX, y: strokeRect.maxY),
                end: CGPoint(x: strokeRect.maxX, y: strokeRect.minY),
                options: []
            )
        }
        context.restoreGState()
    }
}

/// 贴图外的阴影与柔和光晕单独绘制，贴图本身仍使用原来的窗口尺寸。
final class PinHaloPanel: NSPanel {
    static let padding: CGFloat = 28

    static func padding(for spread: Double) -> CGFloat {
        ceil(padding * CGFloat(min(max(spread, 0.6), 1.5)))
    }

    static func frame(around pinFrame: NSRect, spread: Double = 1.0) -> NSRect {
        let pad = padding(for: spread)
        return pinFrame.insetBy(dx: -pad, dy: -pad)
    }

    private let haloView: PinHaloView
    private(set) var shadowAppearance: PinShadowAppearance

    init(pinFrame: NSRect, appearance: PinShadowAppearance = .init()) {
        self.shadowAppearance = appearance
        let pad = Self.padding(for: appearance.spread)
        let frame = pinFrame.insetBy(dx: -pad, dy: -pad)
        self.haloView = PinHaloView(frame: CGRect(origin: .zero, size: frame.size), shadowAppearance: appearance, padding: pad)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ScreenCaptureProtection.apply(to: self)
        contentView = haloView
    }

    func update(appearance: PinShadowAppearance, pinFrame: NSRect) {
        self.shadowAppearance = appearance
        let pad = Self.padding(for: appearance.spread)
        let targetFrame = pinFrame.insetBy(dx: -pad, dy: -pad)
        haloView.padding = pad
        haloView.shadowAppearance = appearance
        if frame != targetFrame {
            setFrame(targetFrame, display: true)
        } else {
            haloView.needsDisplay = true
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PinHaloView: NSView {
    var shadowAppearance: PinShadowAppearance { didSet { if shadowAppearance != oldValue { needsDisplay = true } } }
    var padding: CGFloat { didSet { if padding != oldValue { needsDisplay = true } } }

    init(frame: NSRect, shadowAppearance: PinShadowAppearance, padding: CGFloat) {
        self.shadowAppearance = shadowAppearance
        self.padding = padding
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let opening = bounds.insetBy(dx: padding, dy: padding)
        guard !opening.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        PinShadowArtwork.draw(shadowAppearance, in: context, bounds: bounds, opening: opening)
    }
}

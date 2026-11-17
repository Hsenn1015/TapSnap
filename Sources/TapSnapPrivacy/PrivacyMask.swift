import CoreGraphics
import Foundation

public enum PrivacyMaskStyle: String, CaseIterable, Codable, Hashable, Sendable {
    case frosted, erase, mosaic, graphite, mist, stripes, solid

    public var title: String {
        switch self {
        case .frosted: return "羽化柔焦"
        case .erase: return "同色擦除"
        case .mosaic: return "低对比马赛克"
        case .graphite: return "石墨"
        case .mist: return "雾白"
        case .stripes: return "斜纹"
        case .solid: return "自选色"
        }
    }

    public var usesPatternSize: Bool { self == .mosaic || self == .stripes }
    public var usesSurroundings: Bool { self != .graphite && self != .solid }
}

public struct PrivacyMaskAppearance: Codable, Hashable, Sendable {
    public var style: PrivacyMaskStyle = .frosted
    public var patternSize: Double = 8
    public var rgb: UInt32 = 0x46566C

    public init(style: PrivacyMaskStyle = .frosted, patternSize: Double = 8, rgb: UInt32 = 0x46566C) {
        self.style = style
        self.patternSize = patternSize
        self.rgb = rgb
    }
}

public enum PrivacyMask {
    /// Maximum distance in document points from the protected rectangle to the end of the fade.
    public static let feather: CGFloat = 5
    public static let samplingOutset: CGFloat = 8

    public static func draw(_ rect: CGRect, appearance: PrivacyMaskAppearance, in context: CGContext,
                            patch: CGImage? = nil) {
        guard !rect.isEmpty else { return }
        let effectBounds = rect.insetBy(dx: -feather, dy: -feather)
        let solidFill = appearance.style == .solid ? appearance.rgb : 0x21252E
        let fill = patch == nil ? color(solidFill) : CGColor(gray: 1, alpha: 1)

        context.saveGState()
        context.setBlendMode(.normal)
        context.setAlpha(1)
        context.clip(to: effectBounds)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setShouldAntialias(true)
        // Each round outline expands outward from the protected rectangle. Feather
        // width stays the same at different zoom levels and backing scales.
        context.setBlendMode(.copy)
        for index in stride(from: 8, through: 1, by: -1) {
            let progress = CGFloat(index) / 9
            let expansion = feather * progress
            let opacity = 1 - progress * progress * (3 - 2 * progress)
            let outline = rect.insetBy(dx: -expansion, dy: -expansion)
            let radius = min(expansion * 1.8, 5, min(outline.width, outline.height) / 2)
            context.setFillColor(fill.copy(alpha: opacity) ?? fill)
            context.addPath(CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }

        // Keep every pixel in the protected rectangle opaque, including the corners.
        context.setShouldAntialias(false)
        context.setFillColor(fill)
        context.fill(rect)

        if let patch {
            context.setShouldAntialias(true)
            context.setBlendMode(.sourceIn)
            context.interpolationQuality = appearance.style == .mosaic ? .none : .high
            context.translateBy(x: effectBounds.minX, y: effectBounds.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(patch, in: CGRect(origin: .zero, size: effectBounds.size))
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Reconstruct an opaque low-resolution patch using only pixels outside all covered regions.
    public static func backgroundPatch(around bounds: CGRect, in image: CGImage, appearance: PrivacyMaskAppearance,
                                       scale: CGFloat = 1, excluding masks: [CGRect] = []) -> CGImage? {
        guard appearance.style.usesSurroundings, !bounds.isEmpty else { return nil }
        let bounds = bounds.integral
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let effect = bounds.insetBy(dx: -feather * scale, dy: -feather * scale)
        let patternSize = min(max(appearance.patternSize.isFinite ? appearance.patternSize : 8, 3), 24)
        let step = (appearance.style == .mosaic ? patternSize : 2) * scale
        let width = min(192, max(1, Int(ceil(effect.width / step))))
        let height = min(192, max(1, Int(ceil(effect.height / step))))
        guard let output = bitmap(width: width, height: height), let data = output.data else { return nil }
        let depth = min(samplingOutset * scale, max(2, bounds.height * 0.28)).rounded(.up)

        func sample(_ strip: CGRect, horizontal: Bool) -> [SIMD3<Double>]? {
            let strip = strip.intersection(imageBounds)
            guard !strip.isEmpty, !masks.contains(where: { $0.integral.intersects(strip) }),
                  let crop = image.cropping(to: strip),
                  let sample = bitmap(width: horizontal ? width : 1, height: horizontal ? 1 : height),
                  let data = sample.data else { return nil }
            sample.interpolationQuality = .high
            sample.draw(crop, in: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            let stride = horizontal ? 4 : sample.bytesPerRow
            return (0..<(horizontal ? width : height)).map { i in
                let pixel = pixels + i * stride
                return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
            }
        }

        let above = sample(CGRect(x: effect.minX, y: bounds.minY - depth, width: effect.width, height: depth), horizontal: true)
        let below = sample(CGRect(x: effect.minX, y: bounds.maxY, width: effect.width, height: depth), horizontal: true)
        let left = sample(CGRect(x: bounds.minX - depth, y: effect.minY, width: depth, height: effect.height), horizontal: false)
        let right = sample(CGRect(x: bounds.maxX, y: effect.minY, width: depth, height: effect.height), horizontal: false)

        let top = above ?? below
        let bottom = below ?? above
        let leading = left ?? right
        let trailing = right ?? left
        let across = bounds.height / (bounds.width + bounds.height)
        let neutral = SIMD3<Double>(208, 212, 218)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let py = effect.minY + (Double(y) + 0.5) * effect.height / Double(height)
            let v = min(1, max(0, (py - bounds.minY) / bounds.height))
            let line = exp(-pow((v - 0.5) / 0.29, 2))
            for x in 0..<width {
                let px = effect.minX + (Double(x) + 0.5) * effect.width / Double(width)
                let u = min(1, max(0, (px - bounds.minX) / bounds.width))
                let vertical = top.map { $0[x] * (1 - v) + (bottom?[x] ?? $0[x]) * v }
                let horizontal = leading.map { $0[y] * (1 - u) + (trailing?[y] ?? $0[y]) * u }
                let base = interpolate(vertical, horizontal, weight: across) ?? neutral
                let luminance = base.x * 0.21 + base.y * 0.72 + base.z * 0.07
                // The texture is independent of the text and fades into the reconstructed base.
                let edge = min(1, min(u, 1 - u) / 0.24)
                let contrast = (128 - luminance) * line * edge
                let variation: Double
                switch appearance.style {
                case .frosted: variation = contrast * 0.28
                case .mosaic:
                    let tile = (x * 41 + y * 17 + x * y * 7) % 19 - 9
                    variation = (Double(tile) * 1.4 + contrast * 0.12) * line
                case .mist: variation = (255 - luminance) * line * edge * 0.09
                case .stripes:
                    let phase = ((px - effect.minX + py - effect.minY) / (patternSize * scale * 2))
                    variation = (phase - phase.rounded(.down) < 0.38 ? 11 : -4) * line
                case .erase, .graphite, .solid: variation = 0
                }
                let pixel = pixels + y * output.bytesPerRow + x * 4
                for channel in 0..<3 {
                    pixel[channel] = UInt8(min(255, max(0, (base[channel] + variation).rounded())))
                }
                pixel[3] = 255
            }
        }
        return output.makeImage()
    }

    private static func interpolate(_ vertical: SIMD3<Double>?, _ horizontal: SIMD3<Double>?,
                                    weight: Double) -> SIMD3<Double>? {
        if let vertical, let horizontal { return vertical * (1 - weight) + horizontal * weight }
        return vertical ?? horizontal
    }

    public static func flattened(_ image: CGImage, covering rects: [CGRect]) throws -> CGImage {
        guard !rects.isEmpty else { return image }
        guard let context = bitmap(width: image.width, height: image.height) else {
            throw PrivacyScanError.imageProcessingFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.setBlendMode(.copy)
        context.setShouldAntialias(false)
        context.setFillColor(color(0))
        context.fill(rects.map(\.integral))
        guard let result = context.makeImage() else { throw PrivacyScanError.imageProcessingFailed }
        return result
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func color(_ rgb: UInt32) -> CGColor {
        CGColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

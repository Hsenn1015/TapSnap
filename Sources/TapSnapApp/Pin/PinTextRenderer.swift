import AppKit
import CoreGraphics
import Foundation

/// 将剪贴板纯文本渲染为高分贴图卡片，复用现有贴图窗口、阴影、缩放与分组体系。
enum PinTextRenderer {
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 13
    static let minimumWidth: CGFloat = 120
    static let maximumWidth: CGFloat = 460
    static let maximumHeight: CGFloat = 520
    static let cornerRadius: CGFloat = 10

    static func render(_ text: String, isDark: Bool, scale: CGFloat = 2) -> (image: CGImage, scale: CGFloat)? {
        let clampedScale = min(max(1, scale.isFinite ? scale : 2), 3)
        let font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping

        let textColor = isDark
            ? NSColor(srgbRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)
            : NSColor(srgbRed: 0.09, green: 0.11, blue: 0.14, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]

        let maxTextWidth = maximumWidth - horizontalPadding * 2
        let maxTextHeight = maximumHeight - verticalPadding * 2

        // 先按无限宽度测自然宽度，再收敛到可读列宽内排版，避免短工单号被拉得过宽。
        let naturalLayout = makeLayout(text: text, attributes: attributes,
                                       containerSize: CGSize(width: 100_000, height: 100_000),
                                       truncatingTail: false)
        let naturalWidth = ceil(naturalLayout.manager.usedRect(for: naturalLayout.container).width)
        let textWidth = min(maxTextWidth, max(minimumWidth - horizontalPadding * 2, naturalWidth))

        let finalLayout = makeLayout(text: text, attributes: attributes,
                                     containerSize: CGSize(width: textWidth, height: maxTextHeight),
                                     truncatingTail: true)
        let used = finalLayout.manager.usedRect(for: finalLayout.container)
        let lineHeight = ceil(finalLayout.manager.defaultLineHeight(for: font))
        let fittedWidth = min(maxTextWidth, max(minimumWidth - horizontalPadding * 2, ceil(used.width)))
        let fittedHeight = min(maxTextHeight, max(lineHeight, ceil(used.height)))

        let cardSize = CGSize(
            width: ceil(fittedWidth + horizontalPadding * 2),
            height: ceil(fittedHeight + verticalPadding * 2)
        )
        let pixelWidth = max(1, Int((cardSize.width * clampedScale).rounded()))
        let pixelHeight = max(1, Int((cardSize.height * clampedScale).rounded()))

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: pixelWidth * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return nil }

        context.scaleBy(x: clampedScale, y: clampedScale)

        let cardRect = CGRect(origin: .zero, size: cardSize)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let fillColor = isDark
            ? CGColor(colorSpace: space, components: [0.12, 0.135, 0.17, 1])!
            : CGColor(colorSpace: space, components: [0.988, 0.992, 0.998, 1])!
        let borderColor = isDark
            ? CGColor(colorSpace: space, components: [1, 1, 1, 0.14])!
            : CGColor(colorSpace: space, components: [0, 0, 0, 0.12])!

        context.saveGState()
        context.addPath(cardPath)
        context.setFillColor(fillColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        let strokeRect = cardRect.insetBy(dx: 0.5, dy: 0.5)
        let strokePath = CGPath(roundedRect: strokeRect, cornerWidth: max(0, cornerRadius - 0.5),
                                cornerHeight: max(0, cornerRadius - 0.5), transform: nil)
        context.addPath(strokePath)
        context.setStrokeColor(borderColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        // TextKit 期望左上角原点、y 向下坐标。
        context.saveGState()
        context.addPath(cardPath)
        context.clip()
        context.translateBy(x: 0, y: cardSize.height)
        context.scaleBy(x: 1, y: -1)
        let glyphRange = finalLayout.manager.glyphRange(for: finalLayout.container)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let origin = CGPoint(x: horizontalPadding, y: verticalPadding)
        finalLayout.manager.drawBackground(forGlyphRange: glyphRange, at: origin)
        finalLayout.manager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()

        guard let image = context.makeImage() else { return nil }
        return (image, clampedScale)
    }

    private static func makeLayout(
        text: String,
        attributes: [NSAttributedString.Key: Any],
        containerSize: CGSize,
        truncatingTail: Bool
    ) -> (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) {
        let storage = NSTextStorage(string: text, attributes: attributes)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: containerSize)
        container.lineFragmentPadding = 0
        container.lineBreakMode = truncatingTail ? .byTruncatingTail : .byWordWrapping
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }
}

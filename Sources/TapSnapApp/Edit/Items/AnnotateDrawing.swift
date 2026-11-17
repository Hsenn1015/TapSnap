import CoreGraphics
import CoreText
import Foundation
import TapSnapCore

/// 标注绘制用的小工具。
///
/// 所有 `EditItem.draw(in:scale:)` 都在同一个坐标系里工作：**原点左上、y 向下、
/// 单位是点**（由 `EditDocument.render()` 和画布覆盖层统一设置）。
/// 这个坐标系里直接画 `CGImage` 会垂直镜像、直接画文字会倒置，所以两者都要
/// 先做一次局部反翻转 —— 见 `drawImageUpright` 和 `drawCentered`。
enum AnnotateDrawing {
    /// 线宽 / 字号在文档坐标里已经是点，不用再乘 scale。
    static let minimumLineWidth: CGFloat = 1
    static let minimumHeadLength: CGFloat = 8

    // MARK: - 图像

    /// 在 y 向下的上下文里把图画正（否则会上下镜像）。
    static func drawImageUpright(_ image: CGImage, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// 把一张图降采样到指定像素尺寸（马赛克用，后续放大时保持 blocky）。
    static func downsample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - 路径

    static func configureStroke(_ style: EditItemStyle, in context: CGContext) {
        let width = style.resolvedLineWidth
        context.setStrokeColor(style.resolvedColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        switch style.strokePattern {
        case .solid: context.setLineDash(phase: 0, lengths: [])
        case .dashed: context.setLineDash(phase: 0, lengths: [width * 3, width * 2.5])
        case .dotted: context.setLineDash(phase: 0, lengths: [0.01, width * 2.25])
        }
    }

    static func drawStroke(_ path: CGPath, style: EditItemStyle, in context: CGContext,
                           lineJoin: CGLineJoin = .round) {
        context.saveGState()
        configureStroke(style, in: context)
        context.setLineJoin(lineJoin)
        if style.strokeStyle == .handDrawn {
            HandDrawnStroke.draw(path, style: style, in: context)
        } else {
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    static func drawShape(_ path: CGPath, style: EditItemStyle, in context: CGContext,
                          lineJoin: CGLineJoin = .miter) {
        context.saveGState()
        if style.shapeFill != .outline {
            var fill = style.shapeFillColor
            fill.alpha *= style.opacity
            if style.strokeStyle == .handDrawn {
                let fillPath = HandDrawnStroke.roughened(path, width: style.resolvedLineWidth,
                                                       roughness: style.handDrawnRoughness)
                HandDrawnStroke.fill(fillPath, color: fill.cgColor, width: style.resolvedLineWidth,
                                    pattern: style.handDrawnFill, in: context)
            } else {
                context.setFillColor(fill.cgColor)
                context.addPath(path)
                context.fillPath()
            }
        }
        if style.shapeFill != .fill {
            drawStroke(path, style: style, in: context, lineJoin: lineJoin)
        }
        context.restoreGState()
    }

    /// 用「相邻点中点 + 原始点作控制点」的二次贝塞尔把折线变平滑。
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// 三角箭头，尖端在 `tip`，朝 `angle` 方向。
    static func arrowHead(tip: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat) -> CGPath {
        let back = CGPoint(x: tip.x - cos(angle) * length, y: tip.y - sin(angle) * length)
        let half = width / 2
        let left = CGPoint(
            x: back.x + cos(angle + .pi / 2) * half,
            y: back.y + sin(angle + .pi / 2) * half
        )
        let right = CGPoint(
            x: back.x + cos(angle - .pi / 2) * half,
            y: back.y + sin(angle - .pi / 2) * half
        )
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        return path
    }

    // MARK: - 文字

    static func attributedText(
        _ text: String,
        fontSize: CGFloat,
        color: CGColor,
        bold: Bool = true
    ) -> NSAttributedString {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// 单行文字的外接尺寸（点在文档坐标里）。
    static func measure(_ text: NSAttributedString) -> CGSize {
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// 把单行文字画在 rect 的中央，正立。
    static func drawCentered(_ text: NSAttributedString, in rect: CGRect, context: CGContext) {
        let line = CTLineCreateWithAttributedString(text)
        drawLine(line, in: rect, context: context)
    }

    static func drawLine(_ line: CTLine, in rect: CGRect, context: CGContext) {
        let ink = CTLineGetBoundsWithOptions(line, [])
        guard ink.width > 0 || ink.height > 0 else { return }
        let originX = rect.minX + (rect.width - ink.width) / 2 - ink.minX
        let originY = rect.minY + (rect.height - ink.height) / 2 + ink.maxY

        context.saveGState()
        context.translateBy(x: originX, y: originY)
        context.scaleBy(x: 1, y: -1) // 反翻转，否则字形倒置
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// 按给定锚点画单行文字（左对齐、基线在 `baseline`），正立。
    static func drawLine(_ line: CTLine, at point: CGPoint, context: CGContext) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

extension EditItemStyle {
    /// 把样式里的透明度乘进颜色，AppKit 侧不用再单独记一个 alpha。
    var resolvedColor: CGColor {
        RGBAColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha * opacity
        ).cgColor
    }

    var resolvedLineWidth: CGFloat {
        max(AnnotateDrawing.minimumLineWidth, lineWidth)
    }
}

import CoreGraphics
import Foundation
import TapSnapCore

/// 支持不同箭头样式的线段。
final class ArrowItem: EditItem {
    enum HeadStyle: String, Codable, Sendable {
        case simple
        case filled
        case hollow
    }

    let id = UUID()
    let kind: EditItemKind = .arrow
    var style: EditItemStyle
    var start: CGPoint
    var end: CGPoint
    var headStyle: HeadStyle

    init(start: CGPoint, end: CGPoint, style: EditItemStyle = EditItemStyle(), headStyle: HeadStyle = .filled) {
        self.start = start
        self.end = end
        self.style = style
        self.headStyle = headStyle
    }

    var bounds: CGRect {
        get {
            CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        }
        set {
            let delta = CGPoint(x: newValue.minX - bounds.minX, y: newValue.minY - bounds.minY)
            start = start + delta
            end = end + delta
        }
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard start != end else { return }
        let color = style.resolvedColor
        let lineWidth = style.resolvedLineWidth
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(AnnotateDrawing.minimumHeadLength, lineWidth * 3.5)
        let headWidth = headLength * 0.7
        // 线缩到箭头根部，免得线头从尖端戳出来。
        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * headLength * 0.85,
            y: end.y - sin(angle) * headLength * 0.85
        )

        let shaft = CGMutablePath()
        shaft.addLines(between: [start, shaftEnd])
        AnnotateDrawing.drawStroke(shaft, style: style, in: context)

        let head = AnnotateDrawing.arrowHead(
            tip: end,
            angle: angle,
            length: headLength,
            width: headWidth
        )
        var solidStyle = style
        solidStyle.strokePattern = .solid
        switch headStyle {
        case .filled:
            context.saveGState()
            context.setFillColor(color)
            context.addPath(style.strokeStyle == .handDrawn
                            ? HandDrawnStroke.roughened(head, width: lineWidth, roughness: style.handDrawnRoughness) : head)
            context.fillPath()
            context.restoreGState()
        case .hollow:
            AnnotateDrawing.drawStroke(head, style: solidStyle, in: context)
        case .simple:
            // 只画两条边，线条风格。
            let back = CGPoint(
                x: end.x - cos(angle) * headLength,
                y: end.y - sin(angle) * headLength
            )
            let half = headWidth / 2
            let openHead = CGMutablePath()
            openHead.addLines(between: [
                CGPoint(x: back.x + cos(angle + .pi / 2) * half, y: back.y + sin(angle + .pi / 2) * half),
                end,
                CGPoint(x: back.x + cos(angle - .pi / 2) * half, y: back.y + sin(angle - .pi / 2) * half)
            ])
            AnnotateDrawing.drawStroke(openHead, style: solidStyle, in: context)
        }
    }
}

/// 直线。
final class LineItem: EditItem {
    let id = UUID()
    let kind: EditItemKind = .line
    var style: EditItemStyle
    var start: CGPoint
    var end: CGPoint

    init(start: CGPoint, end: CGPoint, style: EditItemStyle = EditItemStyle()) {
        self.start = start
        self.end = end
        self.style = style
    }

    var bounds: CGRect {
        get {
            CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        }
        set {
            let delta = CGPoint(x: newValue.minX - bounds.minX, y: newValue.minY - bounds.minY)
            start = start + delta
            end = end + delta
        }
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard start != end else { return }
        let path = CGMutablePath()
        path.addLines(between: [start, end])
        AnnotateDrawing.drawStroke(path, style: style, in: context)
    }
}

/// 矩形和椭圆标注。
final class ShapeItem: EditItem {
    let id = UUID()
    let kind: EditItemKind
    var style: EditItemStyle
    var bounds: CGRect

    init(kind: EditItemKind, bounds: CGRect, style: EditItemStyle = EditItemStyle()) {
        self.kind = kind
        self.bounds = bounds
        self.style = style
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path: CGPath
        switch kind {
        case .ellipse, .magnifier:
            path = CGPath(ellipseIn: bounds, transform: nil)
        default:
            let radius = min(style.cornerRadius, bounds.width / 2, bounds.height / 2)
            path = radius > 0
                ? CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: bounds, transform: nil)
        }
        AnnotateDrawing.drawShape(path, style: style, in: context)
    }
}

/// 自由画笔。
final class PenItem: EditItem {
    let id = UUID()
    let kind: EditItemKind = .pen
    var style: EditItemStyle
    var points: [CGPoint]

    init(points: [CGPoint] = [], style: EditItemStyle = EditItemStyle()) {
        self.points = points
        self.style = style
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
        guard let first = points.first else { return }
        context.saveGState()
        AnnotateDrawing.configureStroke(style, in: context)
        context.setLineJoin(.round)
        if points.count == 1 {
            context.setFillColor(style.resolvedColor)
            let radius = style.resolvedLineWidth / 2
            context.fillEllipse(in: CGRect(
                x: first.x - radius,
                y: first.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        } else {
            context.addPath(AnnotateDrawing.smoothPath(points))
            context.strokePath()
        }
        context.restoreGState()
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat = 4) -> Bool {
        // 画笔的包围盒很大，命中测试要贴近折线本身。
        points.contains { $0.distance(to: point) <= max(tolerance, style.lineWidth) }
    }
}

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
        let (shaft, head) = paths
        AnnotateDrawing.drawStroke(shaft, style: style, in: context)
        if headStyle == .filled {
            context.saveGState()
            context.setFillColor(style.resolvedColor)
            context.addPath(AnnotateDrawing.shapeFillPath(head, style: style))
            context.fillPath()
            context.restoreGState()
        } else {
            AnnotateDrawing.drawStroke(head, style: headStrokeStyle, in: context)
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        guard start != end else { return false }
        let (shaft, head) = paths
        if AnnotateDrawing.hitsStroke(shaft, at: point, style: style, tolerance: tolerance) { return true }
        if headStyle == .filled {
            let fill = AnnotateDrawing.shapeFillPath(head, style: style)
            return fill.contains(point) || AnnotateDrawing.hitsStroke(fill, at: point, width: 0, tolerance: tolerance)
        }
        return AnnotateDrawing.hitsStroke(head, at: point, style: headStrokeStyle, tolerance: tolerance)
    }

    private var headStrokeStyle: EditItemStyle {
        var solid = style
        solid.strokePattern = .solid
        return solid
    }

    private var paths: (shaft: CGPath, head: CGPath) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(AnnotateDrawing.minimumHeadLength, style.resolvedLineWidth * 3.5)
        // 线缩到箭头根部，免得线头从尖端戳出来。
        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * headLength * 0.85,
            y: end.y - sin(angle) * headLength * 0.85
        )

        let shaft = CGMutablePath()
        shaft.addLines(between: [start, shaftEnd])
        let head = AnnotateDrawing.arrowHead(tip: end, angle: angle, length: headLength,
                                             width: headLength * 0.7, closed: headStyle != .simple)
        return (shaft, head)
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
        AnnotateDrawing.drawStroke(path, style: style, in: context)
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        start != end && AnnotateDrawing.hitsStroke(path, at: point, style: style, tolerance: tolerance)
    }

    private var path: CGPath {
        let path = CGMutablePath()
        path.addLines(between: [start, end])
        return path
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
        AnnotateDrawing.drawShape(path, style: style, in: context)
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        return AnnotateDrawing.hitsShape(path, at: point, style: style, tolerance: tolerance)
    }

    private var path: CGPath {
        switch kind {
        case .ellipse, .magnifier:
            return CGPath(ellipseIn: bounds, transform: nil)
        default:
            let radius = min(style.cornerRadius, bounds.width / 2, bounds.height / 2)
            return radius > 0
                ? CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: bounds, transform: nil)
        }
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

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if points.count == 1, let center = points.first {
            return center.distance(to: point) <= style.resolvedLineWidth / 2 + tolerance
        }
        return AnnotateDrawing.hitsStroke(AnnotateDrawing.smoothPath(points), at: point,
                                          width: style.resolvedLineWidth, tolerance: tolerance)
    }
}

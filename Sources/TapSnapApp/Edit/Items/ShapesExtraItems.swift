import CoreGraphics
import Foundation
import TapSnapCore

/// 多边形标注。
///
/// 交互是「逐点点击、⏎ 或双击闭合」，不是拖一个矩形。
final class PolygonItem: EditItem {
    let id = UUID()
    let kind: EditItemKind = .polygon
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
        guard points.count >= 3 else { return }
        AnnotateDrawing.drawShape(path, style: style, in: context, lineJoin: .round)
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        points.count >= 3 && AnnotateDrawing.hitsShape(path, at: point, style: style, tolerance: tolerance)
    }

    private var path: CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }
}

/// 聚光灯压暗整张图，只留一个明亮的椭圆区域。
final class SpotlightItem: EditItem {
    let id = UUID()
    let kind: EditItemKind = .spotlight
    var style: EditItemStyle
    var bounds: CGRect

    /// 画布尺寸要靠底图推算出来 —— 压暗的是整张图，不只是自己的包围盒。
    private var canvasSize: CGSize = .zero

    init(bounds: CGRect, style: EditItemStyle = EditItemStyle(opacity: 0.55)) {
        self.bounds = bounds
        self.style = style
    }

    func prepare(source: CGImage, scale: CGFloat) {
        guard scale > 0 else { return }
        canvasSize = CGSize(
            width: CGFloat(source.width) / scale,
            height: CGFloat(source.height) / scale
        )
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard canvasSize.width > 0, bounds.width > 1, bounds.height > 1 else { return }

        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: canvasSize))
        path.addEllipse(in: bounds)

        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.55 * max(0.05, style.opacity)))
        context.addPath(path)
        // even-odd：椭圆内部被挖掉，外面全压暗。
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }
}

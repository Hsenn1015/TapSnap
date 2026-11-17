import CoreGraphics
import Foundation

// 屏幕坐标系（原点在左上、y 向下）与视图坐标系（原点在左下、y 向上）之间的
// 换算，以及各模块共用的几何小工具。

public extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    func rounded(to scale: CGFloat) -> CGPoint {
        CGPoint(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale)
    }
}

public extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    /// 按比例缩放，保持中心不动。
    func scaled(by factor: CGFloat) -> CGRect {
        let newWidth = width * factor
        let newHeight = height * factor
        return CGRect(
            x: midX - newWidth / 2,
            y: midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
    }

    /// 在容器内翻转 y 轴（屏幕坐标 -> 视图坐标）。
    func flippedVertically(in container: CGRect) -> CGRect {
        CGRect(
            x: minX,
            y: container.maxY - maxY,
            width: width,
            height: height
        )
    }

    /// 吸附到像素网格，避免截图选区出现半像素边缘。
    func snapped(to scale: CGFloat) -> CGRect {
        guard scale > 0 else { return self }
        return CGRect(
            x: (minX * scale).rounded() / scale,
            y: (minY * scale).rounded() / scale,
            width: max(1, (width * scale).rounded()) / scale,
            height: max(1, (height * scale).rounded()) / scale
        )
    }
}

public enum Geometry {
    /// 把屏幕全局坐标转换为某个屏幕内的局部坐标。
    public static func localRect(_ rect: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: rect.minY - screenFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 把多个矩形合并为一个外接矩形。
    public static func boundingBox(of rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}

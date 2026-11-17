import AppKit
import TapSnapConfig
import TapSnapCore

/// 共用于实际选区和设置预览。手柄绘制在边框图层上方，命中仍由选区视图处理。
enum SelectionBorderArtwork {
    static func drawRim(_ style: SelectionBorderStyle, around rect: CGRect, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let path = CGPath(rect: rect, transform: nil)

        switch style {
        case .aurora:
            break // 极光沿用原有的动画图层。
        case .pixelSteps:
            stroke(path, color: 0x1e2345, width: 3, in: context)
            stroke(path, color: 0xbfb7fb, width: 1.3, in: context)
        case .twoTonePrint:
            stroke(path, color: 0x203138, width: 4.2, alpha: 0.66, in: context)
            stroke(CGPath(rect: rect.offsetBy(dx: -1.8, dy: 1.5), transform: nil),
                   color: 0x56d7d9, width: 1.65, in: context)
            stroke(CGPath(rect: rect.offsetBy(dx: 1.8, dy: -1.5), transform: nil),
                   color: 0xff876f, width: 1.65, in: context)
        case .fabricStitch:
            context.setLineJoin(.round)
            stroke(path, color: 0xe5dfca, width: 8, in: context)
            stroke(path, color: 0x284b5b, width: 6, in: context)
            context.setLineDash(phase: 0, lengths: [3.5, 3])
            stroke(path, color: 0xeee0bc, width: 1.1, in: context)
        case .iceMint:
            let rim = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.setShadow(offset: .zero, blur: 6, color: RGBAColor(rgb: 0x4bcbea, alpha: 0.48).cgColor)
            stroke(rim, color: 0x153245, width: 3.5, alpha: 0.75, in: context)
        case .monochrome:
            stroke(path, color: 0x171c20, width: 3, in: context)
            stroke(CGPath(rect: rect.insetBy(dx: 0.65, dy: 0.65), transform: nil),
                   color: 0xffffff, width: 1, in: context)
        case .viewfinder:
            stroke(path, color: 0x223742, width: 3, alpha: 0.52, in: context)
            stroke(path, color: 0xdcf0f4, width: 1, alpha: 0.55, in: context)
        case .amberDash:
            stroke(path, color: 0x422d18, width: 3.8, alpha: 0.74, in: context)
            context.setLineDash(phase: 0, lengths: [5, 3])
            stroke(path, color: 0xffcd81, width: 2, in: context)
        case .coolWhiteSweep:
            let rim = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            stroke(rim, color: 0x294257, width: 3, in: context)
            stroke(rim, color: 0xb2d9ef, width: 1, in: context)
        }
    }

    /// 四角从左上顺时针排列，边中点沿用同一组手柄大小。
    static func drawHandles(_ style: SelectionBorderStyle, around rect: CGRect, size: CGFloat,
                            showsResizeHandles: Bool, in context: CGContext) {
        let (fill, edge): (UInt32, UInt32)
        switch style {
        case .aurora: fill = 0xffffff; edge = 0x9454e0
        case .pixelSteps: fill = 0xc9bbff; edge = 0x25294e
        case .twoTonePrint: fill = 0xfff0d7; edge = 0x334c4e
        case .fabricStitch: fill = 0xecdcb7; edge = 0x203b48
        case .iceMint: fill = 0xb7e9fa; edge = 0x255e75
        case .monochrome: fill = 0xffffff; edge = 0x171c20
        case .viewfinder: fill = 0xe0f8ff; edge = 0x102735
        case .amberDash: fill = 0xffe1ac; edge = 0x6b4823
        case .coolWhiteSweep: fill = 0xd4edf8; edge = 0x294257
        }
        func drawSquare(at point: CGPoint, side: CGFloat, color: UInt32) {
            let box = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
            let radius: CGFloat = style == .aurora ? 1.5 : 1
            let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.setFillColor(RGBAColor(rgb: color).cgColor)
            context.setStrokeColor(RGBAColor(rgb: edge).cgColor)
            context.setLineWidth(style == .aurora ? 1.5 : 1)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        }

        context.saveGState()
        defer { context.restoreGState() }
        let midpoints = [CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.midY),
                         CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY)]
        if showsResizeHandles {
            for point in midpoints {
                drawSquare(at: point, side: style == .aurora ? size : size - 1, color: fill)
            }
        }

        let cornerExtent = min(rect.width, rect.height) * 0.4
        let corners: [(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat)] = [
            (rect.minX, rect.maxY, 1, -1), (rect.maxX, rect.maxY, -1, -1),
            (rect.maxX, rect.minY, -1, 1), (rect.minX, rect.minY, 1, 1),
        ]
        for (index, corner) in corners.enumerated() {
            let point = CGPoint(x: corner.x, y: corner.y)
            func relative(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: point.x + x * corner.dx, y: point.y + y * corner.dy)
            }
            switch style {
            case .pixelSteps:
                let scale = min(1, cornerExtent / 16)
                let steps: [(CGFloat, CGFloat)] = [(-2, -2), (16, -2), (16, 2), (9, 2), (9, 5),
                                                    (5, 5), (5, 9), (2, 9), (2, 16), (-2, 16)]
                let path = CGMutablePath()
                path.addLines(between: steps.map { relative($0 * scale, $1 * scale) })
                path.closeSubpath()
                let colors: [UInt32] = [0xa9dafa, 0xc3b3ff, 0x9ee8cb, 0xc3b3ff]
                context.setFillColor(RGBAColor(rgb: colors[index]).cgColor)
                context.setStrokeColor(RGBAColor(rgb: edge).cgColor)
                context.setLineWidth(1.2)
                context.addPath(path)
                context.drawPath(using: .fillStroke)
            case .twoTonePrint:
                context.setFillColor(RGBAColor(rgb: 0x62dbdc).cgColor)
                context.fill(CGRect(x: point.x - 4, y: point.y - 1, width: 5, height: 5))
                context.setFillColor(RGBAColor(rgb: 0xff876f).cgColor)
                context.fill(CGRect(x: point.x, y: point.y - 4, width: 4, height: 4))
            case .fabricStitch:
                context.setFillColor(RGBAColor(rgb: 0x284b5b).cgColor)
                context.fill(CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
                let cross = CGMutablePath()
                cross.addLines(between: [relative(-2.7, -2.7), relative(2.7, 2.7)])
                cross.addLines(between: [relative(-2.7, 2.7), relative(2.7, -2.7)])
                stroke(cross, color: index == 2 ? 0xffc475 : 0xf3e3bc, width: 1.15, in: context)
            case .viewfinder:
                let length = min(18, cornerExtent)
                let path = CGMutablePath()
                path.addLines(between: [relative(0, length), point, relative(length, 0)])
                stroke(path, color: edge, width: 4.6, in: context)
                stroke(path, color: index == 2 ? 0x84e9c8 : fill, width: 3, in: context)
            default:
                if showsResizeHandles {
                    drawSquare(at: point, side: size, color: style == .iceMint && index == 2 ? 0x83f2cc : fill)
                }
            }
        }
    }

    private static func stroke(_ path: CGPath, color: UInt32, width: CGFloat, alpha: Double = 1, in context: CGContext) {
        context.setStrokeColor(RGBAColor(rgb: color, alpha: alpha).cgColor)
        context.setLineWidth(width)
        context.addPath(path)
        context.strokePath()
    }
}

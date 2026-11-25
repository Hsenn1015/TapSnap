import CoreGraphics
import CoreText
import Foundation
import TapSnapConfig
import TapSnapCore

/// 录屏鼠标点击事件渲染快照（归一化坐标 0...1，原点左上）。
public struct RecordingClickEffect: Sendable {
    public enum Button: Sendable {
        case left
        case right
    }

    public var point: CGPoint
    /// 动画进度 0...1。
    public var progress: Double
    public var button: Button
    public var clickCount: Int
    public var style: RecordingMouseClickStyle

    public init(
        point: CGPoint,
        progress: Double = 0.18,
        button: Button = .left,
        clickCount: Int = 1,
        style: RecordingMouseClickStyle = .liquidRipple
    ) {
        self.point = point
        self.progress = min(1, max(0, progress))
        self.button = button
        self.clickCount = max(1, clickCount)
        self.style = style
    }
}

/// 录屏鼠标滚轮滑动渲染快照（归一化坐标 0...1，原点左上）。
public struct RecordingScrollEffect: Sendable {
    public var point: CGPoint
    /// 可见度 0...1（滚动时迅速升至 1，停滚后平滑淡出）。
    public var alpha: Double
    /// 滚动方向：+1 向下滚动，-1 向上滚动。
    public var direction: Double
    /// 累计滚动距离，驱动精密刻度步进。
    public var accumulated: Double
    /// 连续时间戳（秒），驱动波浪、水流与滑珠相位。
    public var time: Double
    public var style: RecordingMouseScrollStyle

    public init(
        point: CGPoint,
        alpha: Double,
        direction: Double,
        accumulated: Double,
        time: Double,
        style: RecordingMouseScrollStyle = .glassPill
    ) {
        self.point = point
        self.alpha = min(1, max(0, alpha))
        self.direction = direction >= 0 ? 1 : -1
        self.accumulated = accumulated
        self.time = time
        self.style = style
    }
}

/// 录屏鼠标点击（14 款）与滚轮（5 款）原生 CoreGraphics 渲染器。
/// 供 `RecordingCompositor` 视频帧合成与「设置 → 录屏」实时预览共用。
public enum RecordingMouseEffectsArtwork {
    public struct PaletteColors: Sendable {
        public let left: RGBAColor
        public let right: RGBAColor
        public let spec: RGBAColor
    }

    public static func paletteColors(for palette: RecordingMouseEffectPalette) -> PaletteColors {
        func rgb(_ hex: UInt32) -> RGBAColor { RGBAColor(rgb: hex, alpha: 1) }
        switch palette {
        case .glassBlue:
            return .init(left: rgb(0x38bdf8), right: rgb(0xa855f7), spec: rgb(0xffffff))
        case .applePure:
            return .init(left: rgb(0xf8fafc), right: rgb(0x60a5fa), spec: rgb(0xffffff))
        case .leicaCoral:
            return .init(left: rgb(0xf97316), right: rgb(0x38bdf8), spec: rgb(0xfff7ed))
        case .mintTeal:
            return .init(left: rgb(0x2dd4bf), right: rgb(0xf472b6), spec: rgb(0xf0fdfa))
        case .goldAmber:
            return .init(left: rgb(0xfbbf24), right: rgb(0x818cf8), spec: rgb(0xfffbeb))
        }
    }

    // MARK: - 14 款鼠标点击动效（坐标系：CGContext 原点左下，Y 轴向上）

    public static func drawClick(
        style: RecordingMouseClickStyle,
        at point: CGPoint,
        progress u: Double,
        button: RecordingClickEffect.Button,
        clickCount: Int,
        palette: RecordingMouseEffectPalette,
        unit: CGFloat,
        in ctx: CGContext
    ) {
        guard u >= 0, u <= 1 else { return }
        let p = paletteColors(for: palette)
        let col = button == .right ? p.right : p.left
        let isRight = button == .right
        let s = unit

        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch style {
        case .liquidRipple:
            let e1 = easeOutCubic(u)
            let fade1 = pow(1 - u, 1.45)
            let r1 = CGFloat(5 + 24 * e1) * s

            // 轻微暗边托底，亮白界面上同样清晰
            ctx.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 0.18 * fade1))
            ctx.setLineWidth(3.0 * s)
            strokeCircle(at: point, radius: r1, in: ctx)

            // 主液态玻璃折射环
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 7 * s, color: cg(col, alpha: 0.52 * fade1))
            strokeCircleGradient(
                at: point, radius: r1, lineWidth: CGFloat(2.4 - 1.0 * e1) * s,
                stops: [
                    (0, cg(p.spec, alpha: 0.96 * fade1)),
                    (0.55, cg(col, alpha: 0.92 * fade1)),
                    (1, cg(p.spec, alpha: 0.55 * fade1)),
                ],
                in: ctx
            )
            ctx.restoreGState()

            // 中心液态柔光与微晶点
            if u < 0.48 {
                let fillA = (1 - u / 0.48) * 0.42
                drawRadialFill(
                    at: point, radius: r1 * 0.85,
                    stops: [
                        (0, cg(p.spec, alpha: min(0.85, fillA * 1.4))),
                        (0.55, cg(col, alpha: fillA * 0.85)),
                        (1, cg(col, alpha: 0)),
                    ],
                    in: ctx
                )
            }

            // 第二圈错峰细水波
            if u > 0.14 {
                let u2 = (u - 0.14) / 0.86
                let e2 = easeOutCubic(u2)
                let f2 = pow(1 - u2, 1.6)
                let r2 = CGFloat(3 + 17 * e2) * s
                ctx.setStrokeColor(cg(col, alpha: 0.74 * f2))
                ctx.setLineWidth(1.2 * s)
                strokeCircle(at: point, radius: r2, in: ctx)
            }

        case .opticalFocus:
            let fade = pow(1 - u, 1.35)
            let snap = u < 0.32 ? (1 - easeOutCubic(u / 0.32)) : 0
            let r = CGFloat(14 + 8 * snap + 6 * easeOutCubic(u)) * s
            let rot = (isRight ? CGFloat.pi / 4 : 0) + CGFloat(easeOutCubic(u)) * 0.22

            if u < 0.55 {
                let da = 1 - u / 0.55
                ctx.setFillColor(cg(col, alpha: da))
                let dotR = CGFloat(3.6 - 1.5 * u) * s
                ctx.fillEllipse(in: CGRect(x: point.x - dotR, y: point.y - dotR, width: dotR * 2, height: dotR * 2))
            }
            ctx.setLineCap(.round)
            for i in 0..<4 {
                let a0 = rot + CGFloat(i) * .pi / 2 + 0.26
                let a1 = rot + CGFloat(i + 1) * .pi / 2 - 0.26
                ctx.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 0.28 * fade))
                ctx.setLineWidth(3.1 * s)
                ctx.addArc(center: point, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
                ctx.strokePath()

                ctx.setStrokeColor(cg(col, alpha: 0.96 * fade))
                ctx.setLineWidth(2.0 * s)
                ctx.addArc(center: point, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
                ctx.strokePath()
            }
            if isRight {
                ctx.setStrokeColor(cg(p.spec, alpha: 0.65 * fade))
                ctx.setLineWidth(1.1 * s)
                strokeCircle(at: point, radius: r * 0.62, in: ctx)
            }

        case .microSpark:
            let e = easeOutCubic(u)
            let fade = pow(1 - u, 1.4)
            let rRing = CGFloat(4 + 18 * e) * s
            ctx.setStrokeColor(cg(col, alpha: 0.85 * fade))
            ctx.setLineWidth(1.6 * s)
            strokeCircle(at: point, radius: rRing, in: ctx)

            let rays = isRight ? 6 : 8
            let innerR = CGFloat(8 + 14 * e) * s
            let rayLen = CGFloat(6.5 * (1 - u * 0.55)) * s
            ctx.setLineCap(.round)
            for i in 0..<rays {
                let ang = CGFloat(i) / CGFloat(rays) * .pi * 2 + (isRight ? .pi / 6 : 0)
                let p1 = CGPoint(x: point.x + cos(ang) * innerR, y: point.y + sin(ang) * innerR)
                let p2 = CGPoint(x: point.x + cos(ang) * (innerR + rayLen), y: point.y + sin(ang) * (innerR + rayLen))
                ctx.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 0.22 * fade))
                ctx.setLineWidth(2.8 * s)
                ctx.beginPath(); ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()

                ctx.setStrokeColor(i % 2 == 0 ? cg(col, alpha: 0.95 * fade) : cg(p.spec, alpha: 0.90 * fade))
                ctx.setLineWidth(1.6 * s)
                ctx.beginPath(); ctx.move(to: p1); ctx.addLine(to: p2); ctx.strokePath()
            }

        case .tactileGlass:
            let rScale: Double = u < 0.22
                ? 0.72 + (u / 0.22) * 0.34
                : 1.06 + easeOutCubic((u - 0.22) / 0.78) * 0.42
            let fade = u < 0.15 ? (u / 0.15) : pow(1 - (u - 0.15) / 0.85, 1.5)
            let r = CGFloat(16 * rScale) * s
            drawRadialFill(
                at: CGPoint(x: point.x - r * 0.2, y: point.y + r * 0.2),
                circleCenter: point, radius: r,
                stops: [
                    (0, cg(p.spec, alpha: 0.55 * fade)),
                    (0.65, cg(col, alpha: 0.30 * fade)),
                    (1, cg(col, alpha: 0.08 * fade)),
                ],
                in: ctx
            )
            ctx.setStrokeColor(cg(p.spec, alpha: 0.72 * fade))
            ctx.setLineWidth(1.3 * s)
            strokeCircle(at: point, radius: r, in: ctx)

            ctx.setFillColor(cg(col, alpha: 0.92 * fade))
            let dotR = 2.8 * s
            ctx.fillEllipse(in: CGRect(x: point.x - dotR, y: point.y - dotR, width: dotR * 2, height: dotR * 2))

        case .dualPulse:
            let e1 = easeOutCubic(u)
            let f1 = pow(1 - u, 1.35)
            let r1 = CGFloat(5 + 23 * e1) * s
            ctx.setStrokeColor(cg(col, alpha: 0.95 * f1))
            ctx.setLineWidth(CGFloat(2.3 - 0.9 * e1) * s)
            strokeCircle(at: point, radius: r1, in: ctx)

            if u > 0.12 {
                let u2 = (u - 0.12) / 0.88
                let e2 = easeOutCubic(u2)
                let f2 = pow(1 - u2, 1.45)
                let r2 = CGFloat(4 + 17 * e2) * s
                ctx.saveGState()
                ctx.setLineCap(.round)
                ctx.setLineDash(phase: 0, lengths: [4 * s, 4 * s])
                ctx.setStrokeColor(cg(p.spec, alpha: 0.78 * f2))
                ctx.setLineWidth(1.4 * s)
                strokeCircle(at: point, radius: r2, in: ctx)
                ctx.restoreGState()
            }

        case .keycapBadge:
            let e = easeOutCubic(u)
            let fade = pow(1 - u, 1.4)
            let r = CGFloat(4 + 20 * e) * s
            ctx.setStrokeColor(cg(col, alpha: 0.88 * fade))
            ctx.setLineWidth(1.7 * s)
            strokeCircle(at: point, radius: r, in: ctx)

            let label = clickCount >= 2 ? "双击" : (isRight ? "右键" : "左键")
            let badgeAlpha = u < 0.12 ? u / 0.12 : (u > 0.65 ? max(0, 1 - (u - 0.65) / 0.35) : 1)
            let rise = CGFloat(e) * 10 * s
            let bw = 34 * s, bh = 18 * s
            let box = CGRect(x: point.x + 13 * s, y: point.y + 8 * s + rise, width: bw, height: bh)
            let boxPath = CGPath(roundedRect: box, cornerWidth: 5 * s, cornerHeight: 5 * s, transform: nil)

            ctx.saveGState()
            ctx.setAlpha(CGFloat(badgeAlpha))
            ctx.setShadow(offset: CGSize(width: 0, height: -2 * s), blur: 6 * s, color: CGColor(gray: 0, alpha: 0.25))
            ctx.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 0.88))
            ctx.addPath(boxPath)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(cg(col, alpha: 0.88))
            ctx.setLineWidth(1.1 * s)
            ctx.addPath(boxPath)
            ctx.strokePath()
            drawCenteredText(label, in: box, fontSize: 10 * s, color: CGColor(gray: 1, alpha: 1), in: ctx)
            ctx.restoreGState()

        case .squareBracket:
            let fade = u < 0.14 ? u / 0.14 : pow(1 - (u - 0.14) / 0.86, 1.4)
            let snap = u < 0.35 ? (1 - easeOutCubic(u / 0.35)) : 0
            let half = CGFloat(12.5 + 8.5 * snap + 3 * easeOutCubic(u)) * s
            let arm = 6.5 * s

            ctx.saveGState()
            ctx.translateBy(x: point.x, y: point.y)
            if isRight { ctx.rotate(by: .pi / 4) }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (-half, half, 1, -1), (half, half, -1, -1),
                (half, -half, -1, 1), (-half, -half, 1, 1),
            ]
            for (cx, cy, dx, dy) in corners {
                let pth = CGMutablePath()
                pth.move(to: CGPoint(x: cx + dx * arm, y: cy))
                pth.addLine(to: CGPoint(x: cx, y: cy))
                pth.addLine(to: CGPoint(x: cx, y: cy + dy * arm))

                ctx.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 0.24 * fade))
                ctx.setLineWidth(3.1 * s)
                ctx.addPath(pth); ctx.strokePath()

                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 5 * s, color: cg(col, alpha: 0.55 * fade))
                ctx.setStrokeColor(cg(col, alpha: 0.96 * fade))
                ctx.setLineWidth(2.0 * s)
                ctx.addPath(pth); ctx.strokePath()
                ctx.restoreGState()
            }
            if u < 0.45 {
                let da = 1 - u / 0.45
                ctx.setFillColor(cg(p.spec, alpha: 0.9 * da))
                let sq = CGRect(x: -2.2 * s, y: -2.2 * s, width: 4.4 * s, height: 4.4 * s)
                ctx.addPath(CGPath(roundedRect: sq, cornerWidth: 1.2 * s, cornerHeight: 1.2 * s, transform: nil))
                ctx.fillPath()
            }
            ctx.restoreGState()

        case .miniMouse:
            let e = easeOutCubic(u)
            let fade = u < 0.12 ? u / 0.12 : (u > 0.68 ? max(0, 1 - (u - 0.68) / 0.32) : 1)
            let r = CGFloat(3 + 16 * e) * s
            ctx.setStrokeColor(cg(col, alpha: 0.80 * pow(1 - u, 1.4)))
            ctx.setLineWidth(1.5 * s)
            strokeCircle(at: point, radius: r, in: ctx)

            let mw = 17 * s, mh = 24 * s
            let mr = mw / 2
            let mx = point.x + 15 * s
            let my = point.y - mh - 8 * s + CGFloat(e) * 4 * s
            let mRect = CGRect(x: mx, y: my, width: mw, height: mh)
            let mPath = CGPath(roundedRect: mRect, cornerWidth: mr, cornerHeight: mr, transform: nil)

            ctx.saveGState()
            ctx.setAlpha(CGFloat(fade))
            ctx.setShadow(offset: CGSize(width: 0, height: -2 * s), blur: 7 * s, color: CGColor(gray: 0, alpha: 0.28))
            ctx.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 0.88))
            ctx.addPath(mPath)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)

            // 点亮左键或右键上半区（Y 轴向上，顶部在 maxY）
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: mRect.insetBy(dx: 1 * s, dy: 1 * s), cornerWidth: max(1, mr - 1 * s), cornerHeight: max(1, mr - 1 * s), transform: nil))
            ctx.clip()
            let flash = (clickCount >= 2 && u > 0.25 && u < 0.42) ? 0.35 : 0.95
            ctx.setFillColor(cg(col, alpha: flash))
            let btnH = mh * 0.48
            let btnY = mRect.maxY - btnH
            if isRight {
                ctx.fill(CGRect(x: mRect.midX + 0.5 * s, y: btnY, width: mw / 2, height: btnH))
            } else {
                ctx.fill(CGRect(x: mRect.minX, y: btnY, width: mw / 2 - 0.5 * s, height: btnH))
            }
            ctx.restoreGState()

            // 外廓与 T 型分割线
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.44))
            ctx.setLineWidth(1.15 * s)
            ctx.addPath(mPath)
            ctx.strokePath()
            ctx.beginPath()
            ctx.move(to: CGPoint(x: mRect.minX + 1 * s, y: btnY))
            ctx.addLine(to: CGPoint(x: mRect.maxX - 1 * s, y: btnY))
            ctx.move(to: CGPoint(x: mRect.midX, y: mRect.maxY - 1 * s))
            ctx.addLine(to: CGPoint(x: mRect.midX, y: btnY))
            ctx.strokePath()

            // 迷你滚轮小点
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.96))
            let wheelRect = CGRect(x: mRect.midX - 1 * s, y: mRect.maxY - 9 * s, width: 2 * s, height: 4.5 * s)
            ctx.addPath(CGPath(roundedRect: wheelRect, cornerWidth: 1 * s, cornerHeight: 1 * s, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()

        case .orbitalSweep:
            let dir: CGFloat = isRight ? 1 : -1
            let r = CGFloat(13 + 7 * easeOutCubic(u)) * s
            let head = CGFloat(easeOutCubic(min(1, u * 1.45))) * .pi * 1.95
            let tail: CGFloat = u > 0.22 ? CGFloat(easeOutCubic((u - 0.22) / 0.78)) * .pi * 1.95 : 0
            let startA = CGFloat.pi / 2 + dir * tail
            let endA = CGFloat.pi / 2 + dir * head
            let fade = u > 0.7 ? (1 - (u - 0.7) / 0.3) : 1

            if abs(endA - startA) > 0.04 {
                let clockwise = dir < 0
                ctx.setLineCap(.round)
                ctx.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 0.20 * fade))
                ctx.setLineWidth(3.3 * s)
                ctx.addArc(center: point, radius: r, startAngle: startA, endAngle: endA, clockwise: clockwise)
                ctx.strokePath()

                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 6 * s, color: cg(col, alpha: 0.70 * fade))
                ctx.setStrokeColor(cg(col, alpha: 0.96 * fade))
                ctx.setLineWidth(2.2 * s)
                ctx.addArc(center: point, radius: r, startAngle: startA, endAngle: endA, clockwise: clockwise)
                ctx.strokePath()
                ctx.restoreGState()

                let hx = point.x + cos(endA) * r
                let hy = point.y + sin(endA) * r
                ctx.setFillColor(cg(p.spec, alpha: fade))
                let br = 2.0 * s
                ctx.fillEllipse(in: CGRect(x: hx - br, y: hy - br, width: br * 2, height: br * 2))
            }

        case .crosshairSnap:
            let fade = pow(1 - u, 1.35)
            let approach = 1 - easeOutCubic(min(1, u * 2.4))
            let gap = CGFloat(4.5 + 10 * approach + 3 * u) * s
            let len = CGFloat(7.5 * (1 - u * 0.35)) * s

            ctx.saveGState()
            ctx.translateBy(x: point.x, y: point.y)
            if isRight { ctx.rotate(by: .pi / 4) }
            ctx.setLineCap(.round)

            let axes: [(CGFloat, CGFloat)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
            for (dx, dy) in axes {
                let a = CGPoint(x: dx * gap, y: dy * gap)
                let b = CGPoint(x: dx * (gap + len), y: dy * (gap + len))
                ctx.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 0.25 * fade))
                ctx.setLineWidth(3.0 * s)
                ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()

                ctx.setStrokeColor(cg(col, alpha: 0.96 * fade))
                ctx.setLineWidth(1.8 * s)
                ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            }
            ctx.setStrokeColor(cg(p.spec, alpha: 0.90 * fade))
            ctx.setLineWidth(1.1 * s)
            ctx.stroke(CGRect(x: -2.5 * s, y: -2.5 * s, width: 5 * s, height: 5 * s))
            ctx.restoreGState()

        case .spotlightHalo:
            let e = easeOutCubic(u)
            let fade = u < 0.16 ? u / 0.16 : pow(1 - (u - 0.16) / 0.84, 1.55)
            let r = CGFloat(18 + 18 * e) * s
            drawRadialFill(
                at: point, radius: r,
                stops: [
                    (0, cg(p.spec, alpha: 0.55 * fade)),
                    (0.28, cg(col, alpha: 0.48 * fade)),
                    (0.62, cg(col, alpha: 0.18 * fade)),
                    (1, cg(col, alpha: 0)),
                ],
                in: ctx
            )
            ctx.setFillColor(cg(p.spec, alpha: 0.95 * fade))
            let cr = CGFloat(3.2 * (1 - u * 0.4)) * s
            ctx.fillEllipse(in: CGRect(x: point.x - cr, y: point.y - cr, width: cr * 2, height: cr * 2))

        case .sonarTriple:
            for i in 0..<3 {
                let delay = Double(i) * 0.13
                guard u >= delay else { continue }
                let lu = (u - delay) / (1 - delay)
                let e = easeOutCubic(lu)
                let f = pow(1 - lu, 1.45)
                let r = CGFloat(3 + 25 * e) * s
                ctx.setStrokeColor(i == 1 ? cg(p.spec, alpha: 0.85 * f) : cg(col, alpha: 0.92 * f))
                ctx.setLineWidth((i == 0 ? 1.4 : 1.0) * s)
                strokeCircle(at: point, radius: r, in: ctx)
            }

        case .diamondPrism:
            let e = easeOutCubic(u)
            let fade = pow(1 - u, 1.35)
            let sz = CGFloat(5 + 17 * e) * s
            let rot = CGFloat.pi / 4 + CGFloat(e) * 0.30 * (isRight ? -1 : 1)

            ctx.saveGState()
            ctx.translateBy(x: point.x, y: point.y)
            ctx.rotate(by: rot)
            let rect = CGRect(x: -sz, y: -sz, width: sz * 2, height: sz * 2)
            let path = CGPath(roundedRect: rect, cornerWidth: 3 * s, cornerHeight: 3 * s, transform: nil)

            ctx.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 0.22 * fade))
            ctx.setLineWidth(3.0 * s)
            ctx.addPath(path); ctx.strokePath()

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 7 * s, color: cg(col, alpha: 0.60 * fade))
            strokeGradient(
                path: path, lineWidth: CGFloat(2.1 - 0.8 * e) * s,
                start: CGPoint(x: -sz, y: sz), end: CGPoint(x: sz, y: -sz),
                stops: [
                    (0, cg(p.spec, alpha: 0.98 * fade)),
                    (0.5, cg(col, alpha: 0.95 * fade)),
                    (1, cg(p.spec, alpha: 0.65 * fade)),
                ],
                in: ctx
            )
            ctx.restoreGState()

            if isRight {
                let isz = sz * 0.58
                let ipath = CGPath(roundedRect: CGRect(x: -isz, y: -isz, width: isz * 2, height: isz * 2),
                                   cornerWidth: 2 * s, cornerHeight: 2 * s, transform: nil)
                ctx.setStrokeColor(cg(col, alpha: 0.72 * fade))
                ctx.setLineWidth(1.2 * s)
                ctx.addPath(ipath); ctx.strokePath()
            }
            ctx.restoreGState()

        case .liquidPetal:
            let e = easeOutCubic(u)
            let fade = u < 0.14 ? u / 0.14 : pow(1 - (u - 0.14) / 0.86, 1.45)
            let dist = CGFloat(3 + 13 * e) * s
            let pr = CGFloat(5.2 - 1.6 * e) * s
            let baseRot = (isRight ? CGFloat.pi / 4 : 0) + CGFloat(e) * 0.45
            let count = isRight ? 6 : 4
            for i in 0..<count {
                let a = baseRot + CGFloat(i) / CGFloat(count) * .pi * 2
                let pt = CGPoint(x: point.x + cos(a) * dist, y: point.y + sin(a) * dist)
                drawRadialFill(
                    at: CGPoint(x: pt.x - pr * 0.2, y: pt.y + pr * 0.2),
                    circleCenter: pt, radius: pr,
                    stops: [
                        (0, cg(p.spec, alpha: 0.88 * fade)),
                        (0.65, cg(col, alpha: 0.48 * fade)),
                        (1, cg(col, alpha: 0.08 * fade)),
                    ],
                    in: ctx
                )
                ctx.setStrokeColor(cg(col, alpha: 0.65 * fade))
                ctx.setLineWidth(0.9 * s)
                strokeCircle(at: pt, radius: pr, in: ctx)
            }
        }
    }

    // MARK: - 5 款鼠标滚轮滑动动效（direction: +1 向下，-1 向上；Y 轴向上所以向下为 -Y）

    public static func drawScroll(
        style: RecordingMouseScrollStyle,
        at point: CGPoint,
        alpha: Double,
        direction: Double,
        accumulated: Double,
        time t: Double,
        palette: RecordingMouseEffectPalette,
        unit: CGFloat,
        in ctx: CGContext
    ) {
        guard alpha > 0.01 else { return }
        let p = paletteColors(for: palette)
        let col = p.left
        let s = unit
        // 屏幕“向下”在 CGContext Y-up 中对应 dy = -1；屏幕“向上”对应 dy = +1
        let dy: CGFloat = direction >= 0 ? -1 : 1
        let ox = point.x + 22 * s
        let oy = point.y - 6 * s

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(CGFloat(min(1, alpha)))

        switch style {
        case .glassPill:
            let pw = 14 * s, ph = 30 * s
            let rect = CGRect(x: ox - pw / 2, y: oy - ph / 2, width: pw, height: ph)
            let path = CGPath(roundedRect: rect, cornerWidth: pw / 2, cornerHeight: pw / 2, transform: nil)

            ctx.setShadow(offset: CGSize(width: 0, height: -2 * s), blur: 7 * s, color: CGColor(gray: 0, alpha: 0.28))
            ctx.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 0.82))
            ctx.addPath(path); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)

            ctx.setStrokeColor(cg(p.spec, alpha: 0.36))
            ctx.setLineWidth(1.1 * s)
            ctx.addPath(path); ctx.strokePath()

            // 上下方向微三角（顶在 maxY，底在 minY）
            ctx.setFillColor(cg(col, alpha: direction < 0 ? 0.96 : 0.26))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: ox, y: rect.maxY - 3.6 * s))
            ctx.addLine(to: CGPoint(x: ox - 2.6 * s, y: rect.maxY - 6.8 * s))
            ctx.addLine(to: CGPoint(x: ox + 2.6 * s, y: rect.maxY - 6.8 * s))
            ctx.closePath(); ctx.fillPath()

            ctx.setFillColor(cg(col, alpha: direction >= 0 ? 0.96 : 0.26))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: ox, y: rect.minY + 3.6 * s))
            ctx.addLine(to: CGPoint(x: ox - 2.6 * s, y: rect.minY + 6.8 * s))
            ctx.addLine(to: CGPoint(x: ox + 2.6 * s, y: rect.minY + 6.8 * s))
            ctx.closePath(); ctx.fillPath()

            // 发光滑珠随滚动方向轻推
            let beadShift = dy * CGFloat(3.2 + 2.2 * sin(t * 14)) * s
            let beadRect = CGRect(x: ox - 2.3 * s, y: oy + beadShift - 4.2 * s, width: 4.6 * s, height: 8.4 * s)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 5 * s, color: cg(col, alpha: 0.85))
            ctx.setFillColor(cg(col, alpha: 0.98))
            ctx.addPath(CGPath(roundedRect: beadRect, cornerWidth: 2.3 * s, cornerHeight: 2.3 * s, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()

        case .kineticChevron:
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let sz = 4.5 * s
            for i in 0..<3 {
                let raw = (t * 3.4 - Double(i) * 0.26)
                let wave = raw - floor(raw)
                let a = sin(wave * .pi)
                let cy = oy + dy * CGFloat((Double(i) - 1.0) * 7.0 + (wave - 0.5) * 4.0) * s
                let pth = CGMutablePath()
                pth.move(to: CGPoint(x: ox - sz, y: cy - dy * sz * 0.65))
                pth.addLine(to: CGPoint(x: ox, y: cy + dy * sz * 0.35))
                pth.addLine(to: CGPoint(x: ox + sz, y: cy - dy * sz * 0.65))

                ctx.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 0.24 * a))
                ctx.setLineWidth(3.0 * s)
                ctx.addPath(pth); ctx.strokePath()

                ctx.setStrokeColor(i == 1 ? cg(p.spec, alpha: 0.95 * a) : cg(col, alpha: 0.95 * a))
                ctx.setLineWidth(1.8 * s)
                ctx.addPath(pth); ctx.strokePath()
            }

        case .wheelTicks:
            let pw = 12 * s, ph = 32 * s
            let rect = CGRect(x: ox - pw / 2, y: oy - ph / 2, width: pw, height: ph)
            let path = CGPath(roundedRect: rect, cornerWidth: 4 * s, cornerHeight: 4 * s, transform: nil)

            ctx.setFillColor(CGColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 0.78))
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.20))
            ctx.setLineWidth(1.0 * s)
            ctx.addPath(path); ctx.strokePath()

            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1 * s, dy: 2 * s), cornerWidth: 3 * s, cornerHeight: 3 * s, transform: nil))
            ctx.clip()
            let step = 5 * s
            let rawOff = CGFloat(-accumulated * 0.45)
            let offset = ((rawOff.truncatingRemainder(dividingBy: step)) + step).truncatingRemainder(dividingBy: step)
            var yy = rect.minY - step + offset
            while yy <= rect.maxY + step {
                let dist = abs(yy - oy) / (ph * 0.5)
                let a = max(0, 1 - Double(dist) * 0.9)
                let isCenter = abs(yy - oy) < step * 0.55
                ctx.setStrokeColor(isCenter ? cg(col, alpha: 1) : CGColor(red: 0.89, green: 0.91, blue: 0.94, alpha: 0.65 * a))
                ctx.setLineWidth((isCenter ? 1.8 : 1.1) * s)
                let hw = (isCenter ? 3.8 : 2.6) * s
                ctx.beginPath()
                ctx.move(to: CGPoint(x: ox - hw, y: yy))
                ctx.addLine(to: CGPoint(x: ox + hw, y: yy))
                ctx.strokePath()
                yy += step
            }
            ctx.restoreGState()

        case .silkyStream:
            let lanes: [CGFloat] = [-5, 0, 5]
            for (idx, lx) in lanes.enumerated() {
                let raw = t * 2.8 + Double(idx) * 0.31
                let phase = raw - floor(raw)
                let env = sin(phase * .pi)
                let len = (idx == 1 ? 18 : 12) * s
                let cy = oy + dy * CGFloat(-8 + phase * 16) * s
                let y1 = cy - dy * len * 0.5
                let y2 = cy + dy * len * 0.5
                let seg = CGMutablePath()
                seg.move(to: CGPoint(x: ox + lx * s, y: y1))
                seg.addLine(to: CGPoint(x: ox + lx * s, y: y2))
                strokeGradient(
                    path: seg, lineWidth: (idx == 1 ? 1.8 : 1.2) * s, lineCap: .round,
                    start: CGPoint(x: ox + lx * s, y: y1), end: CGPoint(x: ox + lx * s, y: y2),
                    stops: [
                        (0, cg(col, alpha: 0)),
                        (0.55, cg(idx == 1 ? p.spec : col, alpha: 0.92 * env)),
                        (1, cg(col, alpha: 0)),
                    ],
                    in: ctx
                )
            }

        case .arcWave:
            let baseAngle: CGFloat = direction >= 0 ? -.pi / 2 : .pi / 2
            let spread: CGFloat = 0.62
            let center = CGPoint(x: point.x + 4 * s, y: point.y - 6 * s)
            ctx.setLineCap(.round)
            for i in 0..<2 {
                let raw = t * 2.3 + Double(i) * 0.5
                let phase = raw - floor(raw)
                let e = easeOutCubic(phase)
                let f = sin(phase * .pi)
                let r = CGFloat(12 + 15 * e) * s

                ctx.setStrokeColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 0.22 * f))
                ctx.setLineWidth(3.0 * s)
                ctx.addArc(center: center, radius: r, startAngle: baseAngle - spread, endAngle: baseAngle + spread, clockwise: false)
                ctx.strokePath()

                ctx.setStrokeColor(i == 0 ? cg(col, alpha: 0.95 * f) : cg(p.spec, alpha: 0.85 * f))
                ctx.setLineWidth(CGFloat(2.0 - 0.7 * e) * s)
                ctx.addArc(center: center, radius: r, startAngle: baseAngle - spread, endAngle: baseAngle + spread, clockwise: false)
                ctx.strokePath()
            }
        }
    }

    // MARK: - 绘图辅助

    private static func cg(_ color: RGBAColor, alpha: Double) -> CGColor {
        CGColor(red: color.red, green: color.green, blue: color.blue, alpha: min(1, max(0, alpha)))
    }

    private static func easeOutCubic(_ u: Double) -> Double {
        let clamped = max(0, min(1, u))
        return 1 - pow(1 - clamped, 3)
    }

    private static func strokeCircle(at center: CGPoint, radius: CGFloat, in ctx: CGContext) {
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func strokeCircleGradient(
        at center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        stops: [(CGFloat, CGColor)],
        in ctx: CGContext
    ) {
        let path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        strokeGradient(
            path: path, lineWidth: lineWidth,
            start: CGPoint(x: center.x - radius, y: center.y + radius),
            end: CGPoint(x: center.x + radius, y: center.y - radius),
            stops: stops, in: ctx
        )
    }

    private static func strokeGradient(
        path: CGPath,
        lineWidth: CGFloat,
        lineCap: CGLineCap = .butt,
        start: CGPoint,
        end: CGPoint,
        stops: [(CGFloat, CGColor)],
        in ctx: CGContext
    ) {
        let stroked = path.copy(strokingWithWidth: max(0.5, lineWidth), lineCap: lineCap, lineJoin: .round, miterLimit: 2)
        ctx.saveGState()
        ctx.addPath(stroked)
        ctx.clip()
        let colors = stops.map(\.1) as CFArray
        let locations = stops.map(\.0)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
            ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    private static func drawRadialFill(
        at startCenter: CGPoint,
        circleCenter: CGPoint? = nil,
        radius: CGFloat,
        stops: [(CGFloat, CGColor)],
        in ctx: CGContext
    ) {
        let center = circleCenter ?? startCenter
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.clip()
        let colors = stops.map(\.1) as CFArray
        let locations = stops.map(\.0)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
            ctx.drawRadialGradient(gradient, startCenter: startCenter, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        ctx.restoreGState()
    }

    private static func drawCenteredText(_ text: String, in box: CGRect, fontSize: CGFloat, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, fontSize, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.saveGState()
        ctx.textPosition = CGPoint(
            x: box.midX - bounds.width / 2 - bounds.minX,
            y: box.midY - bounds.height / 2 - bounds.minY
        )
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

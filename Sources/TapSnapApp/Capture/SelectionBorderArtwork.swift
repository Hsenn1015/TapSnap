import AppKit
import QuartzCore
import TapSnapConfig
import TapSnapCore

/// 共用于实际截图选区、录屏区域和设置页动态预览。
///
/// 所有 7 大风格 × 24 种动效 × 30 组配色均基于连续相位 `phase ∈ [0, 1)` 无缝循环渲染，
/// 光晕与外溢效果严格裁剪在选区外侧，绝不染色选区内部像素。
enum SelectionBorderArtwork {
    struct PaletteSpec {
        let primary: RGBAColor
        let secondary: RGBAColor
        let accent: RGBAColor
        let spec: RGBAColor
        let dark: RGBAColor
    }

    static func paletteSpec(for palette: SelectionBorderPalette) -> PaletteSpec {
        func rgb(_ hex: UInt32) -> RGBAColor { RGBAColor(rgb: hex, alpha: 1) }
        switch palette {
        // 液态玻璃
        case .glacier:
            return .init(primary: rgb(0xbae6fd), secondary: rgb(0x60a5fa), accent: rgb(0xe0f2fe), spec: rgb(0xffffff), dark: rgb(0x0f172a))
        case .seasalt:
            return .init(primary: rgb(0x5eead4), secondary: rgb(0x38bdf8), accent: rgb(0xccfbf1), spec: rgb(0xf8fffe), dark: rgb(0x0c222a))
        case .silverMist:
            return .init(primary: rgb(0xc4b5fd), secondary: rgb(0x818cf8), accent: rgb(0xbfdbfe), spec: rgb(0xffffff), dark: rgb(0x16182e))
        case .warmPearl:
            return .init(primary: rgb(0xfde08a), secondary: rgb(0xf9a8d4), accent: rgb(0xfef3c7), spec: rgb(0xfffdf6), dark: rgb(0x2c1e14))
        case .titaniumIce:
            return .init(primary: rgb(0x7dd3fc), secondary: rgb(0x6366f1), accent: rgb(0xbfdbfe), spec: rgb(0xf1f5f9), dark: rgb(0x0f172a))
        case .motherOfPearl:
            return .init(primary: rgb(0x7dd3fc), secondary: rgb(0xf0abfc), accent: rgb(0x5eead4), spec: rgb(0xffffff), dark: rgb(0x141826))
        // 光学取景器
        case .leica:
            return .init(primary: rgb(0xf8fafc), secondary: rgb(0xef4444), accent: rgb(0xef4444), spec: rgb(0xffffff), dark: rgb(0x0f172a))
        case .hasselblad:
            return .init(primary: rgb(0xe2e8f0), secondary: rgb(0xf59e0b), accent: rgb(0xf59e0b), spec: rgb(0xffffff), dark: rgb(0x0f172a))
        case .cinemaCyan:
            return .init(primary: rgb(0xcffafe), secondary: rgb(0x10b981), accent: rgb(0x34d399), spec: rgb(0xecfeff), dark: rgb(0x0a1923))
        case .nightAmber:
            return .init(primary: rgb(0xfde68a), secondary: rgb(0xf59e0b), accent: rgb(0xfbbf24), spec: rgb(0xfffbeb), dark: rgb(0x201408))
        // 瑞士极简线
        case .swissMono:
            return .init(primary: rgb(0xffffff), secondary: rgb(0xe2e8f0), accent: rgb(0xffffff), spec: rgb(0xffffff), dark: rgb(0x0f172a))
        case .linearIndigo:
            return .init(primary: rgb(0x818cf8), secondary: rgb(0xa5b4fc), accent: rgb(0xe0e7ff), spec: rgb(0xffffff), dark: rgb(0x141634))
        case .braunOrange:
            return .init(primary: rgb(0xe2e8f0), secondary: rgb(0xf97316), accent: rgb(0xf97316), spec: rgb(0xffffff), dark: rgb(0x18181b))
        case .emerald:
            return .init(primary: rgb(0x34d399), secondary: rgb(0xa7f3d0), accent: rgb(0xecfdf5), spec: rgb(0xffffff), dark: rgb(0x0a241c))
        // 精致像素工艺
        case .cyberPixel:
            return .init(primary: rgb(0x7dd3fc), secondary: rgb(0xc084fc), accent: rgb(0xc084fc), spec: rgb(0xffffff), dark: rgb(0x181634))
        case .gameboy:
            return .init(primary: rgb(0x4ade80), secondary: rgb(0xbbf7d0), accent: rgb(0xbbf7d0), spec: rgb(0xf0fdf4), dark: rgb(0x102618))
        case .amberTerminal:
            return .init(primary: rgb(0xfbbf24), secondary: rgb(0xfef3c7), accent: rgb(0xfde68a), spec: rgb(0xfffbeb), dark: rgb(0x2a1a0a))
        case .candyMint:
            return .init(primary: rgb(0x5eead4), secondary: rgb(0xfda4af), accent: rgb(0xfda4af), spec: rgb(0xffffff), dark: rgb(0x1c1c2c))
        // 阳极钛金属
        case .naturalTi:
            return .init(primary: rgb(0x94a3b8), secondary: rgb(0x64748b), accent: rgb(0xf8fafc), spec: rgb(0xffffff), dark: rgb(0x334155))
        case .desertTi:
            return .init(primary: rgb(0xc2a884), secondary: rgb(0x78654b), accent: rgb(0xfff8eb), spec: rgb(0xffffff), dark: rgb(0x443626))
        case .spaceBlack:
            return .init(primary: rgb(0x475569), secondary: rgb(0x1e293b), accent: rgb(0xe2e8f0), spec: rgb(0xf8fafc), dark: rgb(0x0f172a))
        case .cobaltTi:
            return .init(primary: rgb(0x6495d7), secondary: rgb(0x2563eb), accent: rgb(0xeff6ff), spec: rgb(0xffffff), dark: rgb(0x172554))
        // 匠心缝线
        case .saddle:
            return .init(primary: rgb(0x5c3018), secondary: rgb(0xfce2a6), accent: rgb(0xfbbf24), spec: rgb(0xfffbeb), dark: rgb(0x281308))
        case .denim:
            return .init(primary: rgb(0x1c3556), secondary: rgb(0xf3e8d0), accent: rgb(0xfb923c), spec: rgb(0xfff7ed), dark: rgb(0x0f1d30))
        case .forestCraft:
            return .init(primary: rgb(0x16402e), secondary: rgb(0xe8f0d2), accent: rgb(0xfacc15), spec: rgb(0xfefce8), dark: rgb(0x0b2419))
        case .linen:
            return .init(primary: rgb(0x2c323c), secondary: rgb(0xf4f4f5), accent: rgb(0x94a3b8), spec: rgb(0xffffff), dark: rgb(0x14171c))
        // 双翼锁角（精密仪表）
        case .teOrange:
            return .init(primary: rgb(0xe2e8f0), secondary: rgb(0xf97316), accent: rgb(0xf97316), spec: rgb(0xffffff), dark: rgb(0x0f172a))
        case .oscGreen:
            return .init(primary: rgb(0x34d399), secondary: rgb(0xa7f3d0), accent: rgb(0x6ee7b7), spec: rgb(0xecfdf5), dark: rgb(0x081c16))
        case .avionics:
            return .init(primary: rgb(0x38bdf8), secondary: rgb(0xe0f2fe), accent: rgb(0xbae6fd), spec: rgb(0xffffff), dark: rgb(0x0a182a))
        case .starship:
            return .init(primary: rgb(0xfbbf24), secondary: rgb(0xfffbeb), accent: rgb(0xfde68a), spec: rgb(0xffffff), dark: rgb(0x20180a))
        }
    }

    static func previewSwatches(for palette: SelectionBorderPalette) -> (RGBAColor, RGBAColor) {
        let p = paletteSpec(for: palette)
        return (p.primary, p.secondary)
    }

    // MARK: - 主动态边框绘制（坐标系：AppKit Y 轴向上，maxY 为顶边，minY 为底边）

    static func drawAnimatedBorder(
        _ config: SelectionBorderConfiguration,
        around rect: CGRect,
        in bounds: CGRect,
        phase: Double,
        context: CGContext
    ) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let wrapped = phase - floor(phase)
        let palette = paletteSpec(for: config.palette)
        context.saveGState()
        defer { context.restoreGState() }

        switch config.style {
        case .liquidGlass:
            drawLiquidGlass(motion: config.motion, palette: palette, rect: rect, bounds: bounds, phase: wrapped, in: context)
        case .viewfinder:
            drawViewfinder(motion: config.motion, palette: palette, rect: rect, phase: wrapped, in: context)
        case .editorial:
            drawEditorial(motion: config.motion, palette: palette, rect: rect, phase: wrapped, in: context)
        case .pixelSteps:
            drawPixelSteps(motion: config.motion, palette: palette, rect: rect, phase: wrapped, in: context)
        case .titanium:
            drawTitanium(motion: config.motion, palette: palette, rect: rect, phase: wrapped, in: context)
        case .fabricStitch:
            drawFabricStitch(motion: config.motion, palette: palette, rect: rect, phase: wrapped, in: context)
        case .dualWingHUD:
            drawDualWingHUD(motion: config.motion, palette: palette, rect: rect, phase: wrapped, in: context)
        }
    }

    // MARK: - 1. 液态玻璃 (Liquid Glass)

    private static func drawLiquidGlass(
        motion: SelectionBorderMotion,
        palette p: PaletteSpec,
        rect: CGRect,
        bounds: CGRect,
        phase: Double,
        in ctx: CGContext
    ) {
        let r: CGFloat = min(5, rect.width / 4, rect.height / 4)
        let bodyW: CGFloat = 2.6
        let activeW: CGFloat = 3.1

        func drawQuietGlassRim(alpha: Double) {
            let path = roundedPath(rect, radius: r)
            ctx.saveGState()
            ctx.setStrokeColor(cg(p.dark, alpha: 0.42))
            ctx.setLineWidth(bodyW + 1.4)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()

            strokeLinearGradient(
                path: path, lineWidth: bodyW,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                stops: [
                    (0.0, cg(p.primary, alpha: alpha + 0.08)),
                    (0.5, cg(p.spec, alpha: alpha)),
                    (1.0, cg(p.secondary, alpha: alpha + 0.08)),
                ],
                in: ctx
            )
        }

        switch motion {
        case .diagonalGlint:
            drawQuietGlassRim(alpha: 0.34)
            if phase < 0.60 {
                let u = phase / 0.60
                let ease = easeInOutQuad(u)
                let env = sin(u * .pi)
                let span = rect.width + rect.height
                let pos = -span * 0.28 + CGFloat(ease) * span * 1.56
                let bw = span * 0.22
                let path = roundedPath(rect, radius: r)

                // 外溢光学柔晕（严格裁剪在选区外侧）
                ctx.saveGState()
                clipOutside(bounds: bounds, opening: rect, radius: r, in: ctx)
                ctx.setShadow(offset: .zero, blur: 13, color: cg(p.primary, alpha: 0.72 * env))
                strokeLinearGradient(
                    path: path, lineWidth: bodyW + 4.2,
                    start: CGPoint(x: rect.minX + pos - bw, y: rect.maxY + bw * 0.3),
                    end: CGPoint(x: rect.minX + pos + bw, y: rect.maxY - bw * 0.72),
                    stops: [
                        (0.0, cg(p.primary, alpha: 0)),
                        (0.34, cg(p.primary, alpha: 0.56 * env)),
                        (0.50, cg(p.spec, alpha: 0.84 * env)),
                        (0.68, cg(p.secondary, alpha: 0.56 * env)),
                        (1.0, cg(p.secondary, alpha: 0)),
                    ],
                    in: ctx
                )
                ctx.restoreGState()

                // 边框上的锐利水晶折光
                strokeLinearGradient(
                    path: path, lineWidth: activeW,
                    start: CGPoint(x: rect.minX + pos - bw * 0.8, y: rect.maxY + bw * 0.25),
                    end: CGPoint(x: rect.minX + pos + bw * 0.8, y: rect.maxY - bw * 0.6),
                    stops: [
                        (0.0, cg(p.primary, alpha: 0)),
                        (0.28, cg(p.primary, alpha: 0.92 * env)),
                        (0.50, cg(p.spec, alpha: env)),
                        (0.74, cg(p.secondary, alpha: 0.92 * env)),
                        (1.0, cg(p.secondary, alpha: 0)),
                    ],
                    in: ctx
                )
            }

        case .dewdropPulse:
            let breath = 0.5 - 0.5 * cos(phase * 2 * .pi)
            let rip = (phase + 0.15) - floor(phase + 0.15)
            let easeOut = 1 - pow(1 - rip, 2.5)
            let expand = CGFloat(easeOut) * 14
            let ripAlpha = pow(1 - rip, 1.55) * 0.72
            if ripAlpha > 0.015 {
                let ripRect = rect.insetBy(dx: -expand, dy: -expand)
                let ripPath = roundedPath(ripRect, radius: r + expand * 0.45)
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 6, color: cg(p.primary, alpha: ripAlpha * 0.62))
                strokeLinearGradient(
                    path: ripPath, lineWidth: max(0.9, 2.2 * CGFloat(1 - easeOut * 0.5)),
                    start: CGPoint(x: ripRect.minX, y: ripRect.maxY),
                    end: CGPoint(x: ripRect.maxX, y: ripRect.minY),
                    stops: [
                        (0.0, cg(p.spec, alpha: ripAlpha)),
                        (0.5, cg(p.primary, alpha: ripAlpha * 0.9)),
                        (1.0, cg(p.secondary, alpha: ripAlpha * 0.85)),
                    ],
                    in: ctx
                )
                ctx.restoreGState()
            }

            drawQuietGlassRim(alpha: 0.26)
            let path = roundedPath(rect, radius: r)
            ctx.saveGState()
            clipOutside(bounds: bounds, opening: rect, radius: r, in: ctx)
            ctx.setShadow(offset: .zero, blur: 5 + 12 * CGFloat(breath), color: cg(p.primary, alpha: 0.16 + 0.62 * breath))
            ctx.setStrokeColor(cg(p.primary, alpha: 0.14 + 0.46 * breath))
            ctx.setLineWidth(bodyW + 3.2)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()

            strokeLinearGradient(
                path: path, lineWidth: bodyW + 0.5 * CGFloat(breath),
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                stops: [
                    (0.0, cg(p.spec, alpha: 0.24 + 0.76 * breath)),
                    (0.5, cg(p.primary, alpha: 0.22 + 0.72 * breath)),
                    (1.0, cg(p.secondary, alpha: 0.20 + 0.70 * breath)),
                ],
                in: ctx
            )

        case .dualSlide:
            drawQuietGlassRim(alpha: 0.28)
            let s = 0.5 + 0.36 * sin(phase * 2 * .pi)
            let topCx = rect.minX + rect.width * CGFloat(s)
            let botCx = rect.minX + rect.width * CGFloat(1 - s)
            let halfLen = rect.width * 0.27

            func drawSlide(cx: CGFloat, y: CGFloat, tint: RGBAColor) {
                let x1 = max(rect.minX + r, cx - halfLen)
                let x2 = min(rect.maxX - r, cx + halfLen)
                guard x2 > x1 + 4 else { return }
                let seg = CGMutablePath()
                seg.move(to: CGPoint(x: x1, y: y))
                seg.addLine(to: CGPoint(x: x2, y: y))

                ctx.saveGState()
                clipOutside(bounds: bounds, opening: rect, radius: r, in: ctx)
                ctx.setShadow(offset: .zero, blur: 13, color: cg(tint, alpha: 0.85))
                strokeLinearGradient(
                    path: seg, lineWidth: bodyW + 3.8, lineCap: .round,
                    start: CGPoint(x: x1, y: y), end: CGPoint(x: x2, y: y),
                    stops: [
                        (0.0, cg(tint, alpha: 0)),
                        (0.30, cg(tint, alpha: 0.65)),
                        (0.50, cg(p.spec, alpha: 0.92)),
                        (0.70, cg(tint, alpha: 0.65)),
                        (1.0, cg(tint, alpha: 0)),
                    ],
                    in: ctx
                )
                ctx.restoreGState()

                strokeLinearGradient(
                    path: seg, lineWidth: activeW + 0.3, lineCap: .round,
                    start: CGPoint(x: x1, y: y), end: CGPoint(x: x2, y: y),
                    stops: [
                        (0.0, cg(tint, alpha: 0)),
                        (0.22, cg(tint, alpha: 0.95)),
                        (0.50, cg(p.spec, alpha: 1.0)),
                        (0.78, cg(tint, alpha: 0.95)),
                        (1.0, cg(tint, alpha: 0)),
                    ],
                    in: ctx
                )
            }
            drawSlide(cx: topCx, y: rect.maxY, tint: p.primary)
            drawSlide(cx: botCx, y: rect.minY, tint: p.secondary)

        case .cornerBloom:
            drawQuietGlassRim(alpha: 0.26)
            let pA = 0.5 + 0.5 * sin(phase * 2 * .pi)
            let pB = 1 - pA
            let cA = pow(pA, 1.35)
            let cB = pow(pB, 1.35)
            let arm = min(50, rect.width * 0.36, rect.height * 0.38)
            let corners: [(CGPoint, CGFloat, CGFloat, Double, RGBAColor)] = [
                (CGPoint(x: rect.minX, y: rect.maxY), 1, -1, cA, p.primary),
                (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1, cB, p.secondary),
                (CGPoint(x: rect.maxX, y: rect.minY), -1, 1, cA, p.accent),
                (CGPoint(x: rect.minX, y: rect.minY), 1, 1, cB, p.primary),
            ]
            ctx.saveGState()
            clipOutside(bounds: bounds, opening: rect, radius: r, in: ctx)
            for (pt, _, _, v, tint) in corners {
                let a = 0.64 * v
                guard a > 0.03 else { continue }
                let rad = CGFloat(28 * (0.65 + 0.55 * v))
                drawRadialGlow(center: pt, radius: rad, inner: cg(p.spec, alpha: a), mid: cg(tint, alpha: a * 0.68), in: ctx)
            }
            ctx.restoreGState()

            for (pt, dx, dy, v, tint) in corners {
                let a = 0.14 + 0.86 * v
                let hPath = CGMutablePath()
                hPath.move(to: pt)
                hPath.addLine(to: CGPoint(x: pt.x + dx * arm, y: pt.y))
                let vPath = CGMutablePath()
                vPath.move(to: pt)
                vPath.addLine(to: CGPoint(x: pt.x, y: pt.y + dy * arm))

                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: CGFloat(9 * v), color: cg(tint, alpha: 0.82 * v))
                strokeLinearGradient(
                    path: hPath, lineWidth: activeW + 0.2, lineCap: .round,
                    start: pt, end: CGPoint(x: pt.x + dx * arm, y: pt.y),
                    stops: [(0, cg(p.spec, alpha: a)), (0.30, cg(tint, alpha: a * 0.92)), (1, cg(tint, alpha: 0))],
                    in: ctx
                )
                strokeLinearGradient(
                    path: vPath, lineWidth: activeW + 0.2, lineCap: .round,
                    start: pt, end: CGPoint(x: pt.x, y: pt.y + dy * arm),
                    stops: [(0, cg(p.spec, alpha: a)), (0.30, cg(tint, alpha: a * 0.92)), (1, cg(tint, alpha: 0))],
                    in: ctx
                )
                ctx.restoreGState()
            }

        case .refractionTurn:
            drawQuietGlassRim(alpha: 0.22)
            let ang = phase * 2 * .pi
            let cx = rect.midX, cy = rect.midY
            let rx = CGFloat(cos(ang)) * rect.width * 0.62
            let ry = CGFloat(sin(ang)) * rect.height * 0.72
            let start = CGPoint(x: cx - rx, y: cy + ry)
            let end = CGPoint(x: cx + rx, y: cy - ry)
            let path = roundedPath(rect, radius: r)

            ctx.saveGState()
            clipOutside(bounds: bounds, opening: rect, radius: r, in: ctx)
            ctx.setShadow(offset: .zero, blur: 13, color: cg(p.primary, alpha: 0.62))
            strokeLinearGradient(
                path: path, lineWidth: bodyW + 4.2, start: start, end: end,
                stops: [
                    (0.0, cg(p.spec, alpha: 0.78)),
                    (0.32, cg(p.primary, alpha: 0.60)),
                    (0.58, cg(p.secondary, alpha: 0.16)),
                    (1.0, cg(p.secondary, alpha: 0.02)),
                ],
                in: ctx
            )
            ctx.restoreGState()

            strokeLinearGradient(
                path: path, lineWidth: activeW, start: start, end: end,
                stops: [
                    (0.0, cg(p.spec, alpha: 1.0)),
                    (0.25, cg(p.primary, alpha: 0.92)),
                    (0.52, cg(p.secondary, alpha: 0.36)),
                    (0.82, cg(p.secondary, alpha: 0.12)),
                    (1.0, cg(p.accent, alpha: 0.25)),
                ],
                in: ctx
            )

        case .verticalTide:
            drawQuietGlassRim(alpha: 0.28)
            if phase < 0.72 {
                let u = phase / 0.72
                let ease = easeInOutQuad(u)
                let env = sin(u * .pi)
                let bandH = rect.height * 0.42
                // 自顶边 (maxY) 向下淌至底边 (minY)
                let yCenter = rect.maxY + bandH * 0.55 - CGFloat(ease) * (rect.height + bandH * 1.1)
                let path = roundedPath(rect, radius: r)

                ctx.saveGState()
                clipOutside(bounds: bounds, opening: rect, radius: r, in: ctx)
                ctx.setShadow(offset: .zero, blur: 13, color: cg(p.primary, alpha: 0.78 * env))
                strokeLinearGradient(
                    path: path, lineWidth: bodyW + 4.2,
                    start: CGPoint(x: rect.midX, y: yCenter + bandH),
                    end: CGPoint(x: rect.midX, y: yCenter - bandH),
                    stops: [
                        (0.0, cg(p.primary, alpha: 0)),
                        (0.32, cg(p.primary, alpha: 0.62 * env)),
                        (0.50, cg(p.spec, alpha: 0.88 * env)),
                        (0.68, cg(p.secondary, alpha: 0.62 * env)),
                        (1.0, cg(p.secondary, alpha: 0)),
                    ],
                    in: ctx
                )
                ctx.restoreGState()

                strokeLinearGradient(
                    path: path, lineWidth: activeW + 0.2,
                    start: CGPoint(x: rect.midX, y: yCenter + bandH * 0.85),
                    end: CGPoint(x: rect.midX, y: yCenter - bandH * 0.85),
                    stops: [
                        (0.0, cg(p.primary, alpha: 0)),
                        (0.28, cg(p.primary, alpha: 0.95 * env)),
                        (0.50, cg(p.spec, alpha: env)),
                        (0.72, cg(p.secondary, alpha: 0.95 * env)),
                        (1.0, cg(p.secondary, alpha: 0)),
                    ],
                    in: ctx
                )
            }

        default:
            drawQuietGlassRim(alpha: 0.65)
        }
    }

    // MARK: - 2. 光学取景器 (Optical Viewfinder)

    private static func drawViewfinder(
        motion: SelectionBorderMotion,
        palette p: PaletteSpec,
        rect: CGRect,
        phase: Double,
        in ctx: CGContext
    ) {
        let arm = min(22, rect.width * 0.32, rect.height * 0.32)
        var insetShift: CGFloat = 0
        var glowVal = 0.7
        var scanX: CGFloat?

        switch motion {
        case .focusLock:
            let snap = phase < 0.32 ? sin((phase / 0.32) * .pi) : 0
            insetShift = CGFloat(snap) * 3.4
            glowVal = 0.45 + 0.55 * snap
        case .rangeScan:
            if phase < 0.65 {
                let u = phase / 0.65
                scanX = rect.minX - 16 + CGFloat(u) * (rect.width + 32)
            }
            glowVal = 0.65
        default:
            glowVal = 0.35 + 0.65 * (0.5 + 0.5 * sin(phase * 2 * .pi))
        }

        // 细框底线
        ctx.setStrokeColor(cg(p.dark, alpha: 0.58))
        ctx.setLineWidth(2.6)
        ctx.stroke(rect)
        ctx.setStrokeColor(cg(p.primary, alpha: 0.50))
        ctx.setLineWidth(1.0)
        ctx.stroke(rect)

        // 四边中点微刻度
        let tick: CGFloat = 6.5
        let mids: [(CGPoint, CGPoint)] = [
            (CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY + tick)),
            (CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY - tick)),
            (CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.minX - tick, y: rect.midY)),
            (CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX + tick, y: rect.midY)),
        ]
        ctx.setLineWidth(1.4)
        for (a, b) in mids {
            let hit = scanX.map { abs(a.x - $0) < 30 } ?? false
            ctx.setStrokeColor(hit ? cg(p.accent, alpha: 1) : cg(p.primary, alpha: 0.38 + 0.52 * glowVal))
            ctx.beginPath()
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        }

        // 激光测距扫描高光
        if let sx = scanX {
            let sw: CGFloat = 42
            let x1 = max(rect.minX, sx - sw)
            let x2 = min(rect.maxX, sx + sw)
            if x2 > x1 {
                let seg = CGMutablePath()
                seg.move(to: CGPoint(x: x1, y: rect.maxY))
                seg.addLine(to: CGPoint(x: x2, y: rect.maxY))
                seg.move(to: CGPoint(x: x1, y: rect.minY))
                seg.addLine(to: CGPoint(x: x2, y: rect.minY))
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 7, color: cg(p.accent, alpha: 0.85))
                strokeLinearGradient(
                    path: seg, lineWidth: 2.2,
                    start: CGPoint(x: sx - sw, y: rect.midY), end: CGPoint(x: sx + sw, y: rect.midY),
                    stops: [(0, cg(p.accent, alpha: 0)), (0.5, cg(p.accent, alpha: 0.98)), (1, cg(p.accent, alpha: 0))],
                    in: ctx
                )
                ctx.restoreGState()
            }
        }

        // 四角精工 L 型对焦标
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX - insetShift, y: rect.maxY + insetShift), 1, -1),
            (CGPoint(x: rect.maxX + insetShift, y: rect.maxY + insetShift), -1, -1),
            (CGPoint(x: rect.maxX + insetShift, y: rect.minY - insetShift), -1, 1),
            (CGPoint(x: rect.minX - insetShift, y: rect.minY - insetShift), 1, 1),
        ]
        for (i, (pt, dx, dy)) in corners.enumerated() {
            let isAccent = i == 1 || (scanX.map { abs(pt.x - $0) < 34 } ?? false)
            let lPath = CGMutablePath()
            lPath.move(to: CGPoint(x: pt.x + dx * arm, y: pt.y))
            lPath.addLine(to: pt)
            lPath.addLine(to: CGPoint(x: pt.x, y: pt.y + dy * arm))

            ctx.setStrokeColor(cg(p.dark, alpha: 0.85))
            ctx.setLineWidth(4.2)
            ctx.addPath(lPath)
            ctx.strokePath()

            ctx.saveGState()
            if isAccent {
                ctx.setShadow(offset: .zero, blur: 6, color: cg(p.accent, alpha: 0.72 * glowVal))
            }
            ctx.setStrokeColor(isAccent ? cg(p.accent, alpha: 0.55 + 0.45 * glowVal) : cg(p.primary, alpha: 0.48 + 0.52 * glowVal))
            ctx.setLineWidth(2.2)
            ctx.addPath(lPath)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 右上角微焦提示灯（绘制在框角外侧微小偏移处，不遮挡选区内画面）
        if motion == .focusLock || motion == .apertureBreathe {
            let dotAlpha = 0.28 + 0.72 * glowVal
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 5, color: cg(p.accent, alpha: dotAlpha))
            ctx.setFillColor(cg(p.accent, alpha: dotAlpha))
            let dot = CGRect(x: rect.maxX + 6, y: rect.maxY + 4, width: 5.5, height: 5.5)
            ctx.fillEllipse(in: dot)
            ctx.restoreGState()
        }
    }

    // MARK: - 3. 瑞士极简线 (Swiss Editorial)

    private static func drawEditorial(
        motion: SelectionBorderMotion,
        palette p: PaletteSpec,
        rect: CGRect,
        phase: Double,
        in ctx: CGContext
    ) {
        switch motion {
        case .silkyDash:
            ctx.setStrokeColor(cg(p.dark, alpha: 0.68))
            ctx.setLineWidth(2.8)
            ctx.stroke(rect)

            ctx.saveGState()
            ctx.setLineCap(.round)
            // 整周期位移：4 * (7 + 6) = 52，确保 0 -> 1 无缝衔接
            ctx.setLineDash(phase: CGFloat(phase) * 52, lengths: [7, 6])
            ctx.setStrokeColor(cg(p.primary, alpha: 0.96))
            ctx.setLineWidth(1.5)
            ctx.stroke(rect)
            ctx.restoreGState()

        case .penGlider:
            ctx.setStrokeColor(cg(p.dark, alpha: 0.58))
            ctx.setLineWidth(2.4)
            ctx.stroke(rect)
            ctx.setStrokeColor(cg(p.primary, alpha: 0.54))
            ctx.setLineWidth(1.1)
            ctx.stroke(rect)

            let u = 0.5 + 0.40 * sin(phase * 2 * .pi)
            let span = rect.width * 0.30
            func glide(cx: CGFloat, y: CGFloat) {
                let x1 = max(rect.minX, cx - span / 2)
                let x2 = min(rect.maxX, cx + span / 2)
                guard x2 > x1 + 2 else { return }
                let seg = CGMutablePath()
                seg.move(to: CGPoint(x: x1, y: y))
                seg.addLine(to: CGPoint(x: x2, y: y))
                strokeLinearGradient(
                    path: seg, lineWidth: 2.3, lineCap: .round,
                    start: CGPoint(x: x1, y: y), end: CGPoint(x: x2, y: y),
                    stops: [(0, cg(p.accent, alpha: 0)), (0.5, cg(p.accent, alpha: 1)), (1, cg(p.accent, alpha: 0))],
                    in: ctx
                )
            }
            glide(cx: rect.minX + rect.width * CGFloat(u), y: rect.maxY)
            glide(cx: rect.minX + rect.width * CGFloat(1 - u), y: rect.minY)

        default: // .cornerNodes
            let pulse = 0.35 + 0.65 * (0.5 + 0.5 * sin(phase * 2 * .pi))
            ctx.setStrokeColor(cg(p.dark, alpha: 0.60))
            ctx.setLineWidth(2.2)
            ctx.stroke(rect)
            ctx.setStrokeColor(cg(p.primary, alpha: 0.85))
            ctx.setLineWidth(1.1)
            ctx.stroke(rect)

            let ch: CGFloat = 7.5
            let pts = [
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY),
            ]
            for pt in pts {
                let cross = CGMutablePath()
                cross.move(to: CGPoint(x: pt.x - ch, y: pt.y))
                cross.addLine(to: CGPoint(x: pt.x + ch, y: pt.y))
                cross.move(to: CGPoint(x: pt.x, y: pt.y - ch))
                cross.addLine(to: CGPoint(x: pt.x, y: pt.y + ch))
                ctx.setStrokeColor(cg(p.dark, alpha: 0.85))
                ctx.setLineWidth(3.2)
                ctx.addPath(cross)
                ctx.strokePath()
                ctx.setStrokeColor(cg(p.accent, alpha: pulse))
                ctx.setLineWidth(1.6)
                ctx.addPath(cross)
                ctx.strokePath()
            }
        }
    }

    // MARK: - 4. 精致像素工艺 (Retro Pixel Craft)

    private static func drawPixelSteps(
        motion: SelectionBorderMotion,
        palette p: PaletteSpec,
        rect: CGRect,
        phase: Double,
        in ctx: CGContext
    ) {
        ctx.setStrokeColor(cg(p.dark, alpha: 0.86))
        ctx.setLineWidth(3.5)
        ctx.stroke(rect)

        switch motion {
        case .pixelMarch:
            ctx.setStrokeColor(cg(p.primary, alpha: 0.36))
            ctx.setLineWidth(1.4)
            ctx.stroke(rect)

            let stepIndex = Int(floor(phase * 16))
            let perim = 2 * (rect.width + rect.height)
            let count = max(12, Int(perim / 11) / 4 * 4)
            for i in 0..<count {
                let shifted = (i - stepIndex % 4 + 4) % 4
                guard shifted % 2 == 0 else { continue }
                let pt = perimeterPoint(around: rect, fraction: Double(i) / Double(count))
                ctx.setFillColor(shifted == 0 ? cg(p.accent, alpha: 0.98) : cg(p.primary, alpha: 0.92))
                ctx.fill(CGRect(x: round(pt.x - 2), y: round(pt.y - 2), width: 4, height: 4))
            }

        case .crtScan:
            ctx.setStrokeColor(cg(p.primary, alpha: 0.46))
            ctx.setLineWidth(1.5)
            ctx.stroke(rect)

            let scanY = round((rect.maxY - CGFloat(phase) * rect.height) / 4) * 4
            for dy in stride(from: CGFloat(-12), through: 12, by: 4) {
                let yy = scanY + dy
                guard yy >= rect.minY, yy <= rect.maxY else { continue }
                let a = Double(1 - abs(dy) / 16)
                ctx.setFillColor(dy == 0 ? cg(p.accent, alpha: 1) : cg(p.primary, alpha: a))
                ctx.fill(CGRect(x: rect.minX - 2.5, y: yy - 1.75, width: 5, height: 3.5))
                ctx.fill(CGRect(x: rect.maxX - 2.5, y: yy - 1.75, width: 5, height: 3.5))
            }
            if scanY >= rect.maxY - 8 || scanY <= rect.minY + 8 {
                let yEdge = scanY >= rect.maxY - 8 ? rect.maxY : rect.minY
                ctx.setFillColor(cg(p.accent, alpha: 0.95))
                for x in stride(from: rect.minX, through: rect.maxX, by: 6) {
                    ctx.fill(CGRect(x: x - 2, y: yEdge - 2, width: 4, height: 4))
                }
            }

        default: // .pixelCorners
            ctx.setStrokeColor(cg(p.primary, alpha: 0.82))
            ctx.setLineWidth(1.5)
            ctx.stroke(rect)
        }

        // 8-bit 阶梯像素顶角
        let tick = Int(floor(phase * 4)) % 2
        let pA = motion == .pixelCorners ? (tick == 0 ? 1.0 : 0.35) : 1.0
        let pB = motion == .pixelCorners ? (tick == 1 ? 1.0 : 0.35) : 1.0
        let corners: [(CGPoint, CGFloat, CGFloat, Double, RGBAColor)] = [
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1, pA, p.primary),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1, pB, p.accent),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1, pA, p.primary),
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1, pB, p.accent),
        ]
        let sz: CGFloat = 4.2
        let blocks: [(CGFloat, CGFloat)] = [(0, 0), (1, 0), (2, 0), (0, 1), (0, 2), (1, 1)]
        for (pt, dx, dy, alpha, col) in corners {
            ctx.setFillColor(cg(p.dark, alpha: 0.90))
            for (bx, by) in blocks {
                let px = pt.x + dx * bx * sz - sz / 2
                let py = pt.y + dy * by * sz - sz / 2
                ctx.fill(CGRect(x: px - 1, y: py - 1, width: sz + 2, height: sz + 2))
            }
            ctx.setFillColor(cg(col, alpha: alpha))
            for (bx, by) in blocks {
                let px = pt.x + dx * bx * sz - sz / 2
                let py = pt.y + dy * by * sz - sz / 2
                ctx.fill(CGRect(x: px, y: py, width: sz, height: sz))
            }
        }
    }

    // MARK: - 5. 阳极钛金属 (Anodized Titanium)

    private static func drawTitanium(
        motion: SelectionBorderMotion,
        palette p: PaletteSpec,
        rect: CGRect,
        phase: Double,
        in ctx: CGContext
    ) {
        let r: CGFloat = min(4, rect.width / 4, rect.height / 4)
        let path = roundedPath(rect, radius: r)

        // 深邃阳极金属外倒角
        ctx.setStrokeColor(cg(p.dark, alpha: 0.88))
        ctx.setLineWidth(4.6)
        ctx.addPath(path)
        ctx.strokePath()

        // 哑光拉丝金属主体渐变
        strokeLinearGradient(
            path: path, lineWidth: 2.8,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            stops: [
                (0.0, cg(p.primary, alpha: 0.96)),
                (0.35, cg(p.dark, alpha: 0.92)),
                (0.65, cg(p.primary, alpha: 0.96)),
                (1.0, cg(p.dark, alpha: 0.94)),
            ],
            in: ctx
        )

        switch motion {
        case .brushedSheen:
            if phase < 0.58 {
                let u = phase / 0.58
                let ease = easeInOutQuad(u)
                let env = sin(u * .pi)
                let span = rect.width + rect.height
                let pos = -span * 0.2 + CGFloat(ease) * span * 1.4
                let bw = span * 0.13
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 6, color: cg(p.accent, alpha: 0.65 * env))
                strokeLinearGradient(
                    path: path, lineWidth: 2.6,
                    start: CGPoint(x: rect.minX + pos - bw, y: rect.maxY + bw * 0.3),
                    end: CGPoint(x: rect.minX + pos + bw, y: rect.maxY - bw * 0.65),
                    stops: [
                        (0.0, cg(p.accent, alpha: 0)),
                        (0.42, cg(p.accent, alpha: 0.92 * env)),
                        (0.50, cg(p.spec, alpha: env)),
                        (0.58, cg(p.accent, alpha: 0.92 * env)),
                        (1.0, cg(p.accent, alpha: 0)),
                    ],
                    in: ctx
                )
                ctx.restoreGState()
            }

        case .chromeEdge:
            let s = 0.5 + 0.36 * sin(phase * 2 * .pi)
            let half = rect.width * 0.26
            for (cx, y) in [(rect.minX + rect.width * CGFloat(s), rect.maxY),
                            (rect.minX + rect.width * CGFloat(1 - s), rect.minY)] {
                let x1 = max(rect.minX + r, cx - half)
                let x2 = min(rect.maxX - r, cx + half)
                guard x2 > x1 + 4 else { continue }
                let seg = CGMutablePath()
                seg.move(to: CGPoint(x: x1, y: y))
                seg.addLine(to: CGPoint(x: x2, y: y))
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 5, color: cg(p.accent, alpha: 0.55))
                strokeLinearGradient(
                    path: seg, lineWidth: 2.1, lineCap: .round,
                    start: CGPoint(x: x1, y: y), end: CGPoint(x: x2, y: y),
                    stops: [
                        (0.0, cg(p.accent, alpha: 0)),
                        (0.45, cg(p.accent, alpha: 0.95)),
                        (0.50, cg(p.spec, alpha: 1)),
                        (0.55, cg(p.accent, alpha: 0.95)),
                        (1.0, cg(p.accent, alpha: 0)),
                    ],
                    in: ctx
                )
                ctx.restoreGState()
            }

        default: // .titaniumBreathe
            let br = 0.5 + 0.5 * sin(phase * 2 * .pi)
            let inner = roundedPath(rect.insetBy(dx: 0.5, dy: 0.5), radius: max(1, r - 0.5))
            strokeLinearGradient(
                path: inner, lineWidth: 1.6,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                stops: [
                    (0.0, cg(p.accent, alpha: 0.25 + 0.72 * br)),
                    (0.45, cg(p.primary, alpha: 0.18 + 0.35 * br)),
                    (1.0, cg(p.accent, alpha: 0.20 + 0.65 * br)),
                ],
                in: ctx
            )
        }
    }

    // MARK: - 6. 匠心缝线 (Artisan Leather Stitch)

    private static func drawFabricStitch(
        motion: SelectionBorderMotion,
        palette p: PaletteSpec,
        rect: CGRect,
        phase: Double,
        in ctx: CGContext
    ) {
        let r: CGFloat = min(3, rect.width / 4, rect.height / 4)
        let path = roundedPath(rect, radius: r)

        // 精致皮革细滚边
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.42))
        ctx.setLineWidth(6.2)
        ctx.addPath(path)
        ctx.strokePath()

        ctx.setStrokeColor(cg(p.primary, alpha: 0.96))
        ctx.setLineWidth(4.6)
        ctx.addPath(path)
        ctx.strokePath()

        // 马鞍针法短针脚
        ctx.saveGState()
        ctx.setLineCap(.round)
        // 4 * (4.5 + 4.0) = 34，严格整周期无缝循环
        let dashPhase: CGFloat = motion == .runningStitch ? CGFloat(phase) * 34 : 0
        ctx.setLineDash(phase: dashPhase, lengths: [4.5, 4.0])
        ctx.setStrokeColor(cg(p.secondary, alpha: 0.92))
        ctx.setLineWidth(1.4)
        ctx.addPath(path)
        ctx.strokePath()

        if motion == .threadSheen, phase < 0.62 {
            let u = phase / 0.62
            let span = rect.width + rect.height
            let pos = -span * 0.22 + CGFloat(u) * span * 1.44
            let bw: CGFloat = 56
            let dashed = path.copy(dashingWithPhase: 0, lengths: [4.5, 4.0])
            strokeLinearGradient(
                path: dashed, lineWidth: 1.8, lineCap: .round,
                start: CGPoint(x: rect.minX + pos - bw, y: rect.maxY + bw * 0.4),
                end: CGPoint(x: rect.minX + pos + bw, y: rect.maxY - bw * 0.8),
                stops: [(0, cg(p.accent, alpha: 0)), (0.5, cg(p.spec, alpha: 0.95)), (1, cg(p.accent, alpha: 0))],
                in: ctx
            )
        }
        ctx.restoreGState()

        // 四角手工 X 锁针结
        let s = sin(phase * 2 * .pi)
        let pA = motion == .cornerKnots ? (0.35 + 0.65 * (0.5 + 0.5 * s)) : 0.95
        let pB = motion == .cornerKnots ? (0.35 + 0.65 * (0.5 - 0.5 * s)) : 0.95
        let knots: [(CGPoint, Double)] = [
            (CGPoint(x: rect.minX, y: rect.maxY), pA),
            (CGPoint(x: rect.maxX, y: rect.maxY), pB),
            (CGPoint(x: rect.maxX, y: rect.minY), pA),
            (CGPoint(x: rect.minX, y: rect.minY), pB),
        ]
        for (pt, alpha) in knots {
            ctx.setFillColor(cg(p.primary, alpha: 1))
            ctx.fill(CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8))
            ctx.setStrokeColor(cg(p.accent, alpha: alpha))
            ctx.setLineWidth(1.45)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: pt.x - 2.6, y: pt.y - 2.6))
            ctx.addLine(to: CGPoint(x: pt.x + 2.6, y: pt.y + 2.6))
            ctx.move(to: CGPoint(x: pt.x + 2.6, y: pt.y - 2.6))
            ctx.addLine(to: CGPoint(x: pt.x - 2.6, y: pt.y + 2.6))
            ctx.strokePath()
        }
    }

    // MARK: - 7. 双翼锁角 / 精密仪表 (Precision HUD)

    private static func drawDualWingHUD(
        motion: SelectionBorderMotion,
        palette p: PaletteSpec,
        rect: CGRect,
        phase: Double,
        in ctx: CGContext
    ) {
        ctx.setStrokeColor(cg(p.dark, alpha: 0.62))
        ctx.setLineWidth(2.4)
        ctx.stroke(rect)

        switch motion {
        case .hudBrackets:
            // 细虚线轨道 + 航电双翼几何锁角利落微扣
            ctx.saveGState()
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.setStrokeColor(cg(p.primary, alpha: 0.54))
            ctx.setLineWidth(1.1)
            ctx.stroke(rect)
            ctx.restoreGState()

            let snap = phase < 0.30 ? sin((phase / 0.30) * .pi) : 0
            let shift = CGFloat(snap) * 3.0
            let arm = min(20, rect.width * 0.30, rect.height * 0.30)
            let wings: [(CGPoint, CGFloat, CGFloat)] = [
                (CGPoint(x: rect.minX - shift, y: rect.maxY + shift), 1, -1),
                (CGPoint(x: rect.maxX + shift, y: rect.maxY + shift), -1, -1),
                (CGPoint(x: rect.maxX + shift, y: rect.minY - shift), -1, 1),
                (CGPoint(x: rect.minX - shift, y: rect.minY - shift), 1, 1),
            ]
            for (pt, dx, dy) in wings {
                let outer = CGMutablePath()
                outer.move(to: CGPoint(x: pt.x + dx * arm, y: pt.y))
                outer.addLine(to: pt)
                outer.addLine(to: CGPoint(x: pt.x, y: pt.y + dy * arm))

                ctx.setStrokeColor(cg(p.dark, alpha: 0.85))
                ctx.setLineWidth(3.8)
                ctx.addPath(outer)
                ctx.strokePath()

                ctx.setStrokeColor(snap > 0.1 ? cg(p.accent, alpha: 0.98) : cg(p.primary, alpha: 0.92))
                ctx.setLineWidth(2.0)
                ctx.addPath(outer)
                ctx.strokePath()

                // 内翼平行折角
                let innerPt = CGPoint(x: pt.x + dx * 4, y: pt.y + dy * 4)
                let inner = CGMutablePath()
                inner.move(to: CGPoint(x: innerPt.x + dx * (arm * 0.45), y: innerPt.y))
                inner.addLine(to: innerPt)
                inner.addLine(to: CGPoint(x: innerPt.x, y: innerPt.y + dy * (arm * 0.45)))
                ctx.setStrokeColor(cg(p.accent, alpha: 0.35 + 0.65 * snap))
                ctx.setLineWidth(1.2)
                ctx.addPath(inner)
                ctx.strokePath()
            }

        case .tickWave:
            let step: CGFloat = 9
            var pts: [(CGPoint, CGFloat, CGFloat)] = []
            var x = rect.minX
            while x <= rect.maxX { pts.append((CGPoint(x: x, y: rect.maxY), 0, 1)); x += step }
            var y = rect.maxY - step
            while y >= rect.minY { pts.append((CGPoint(x: rect.maxX, y: y), 1, 0)); y -= step }
            x = rect.maxX - step
            while x >= rect.minX { pts.append((CGPoint(x: x, y: rect.minY), 0, -1)); x -= step }
            y = rect.minY + step
            while y < rect.maxY { pts.append((CGPoint(x: rect.minX, y: y), -1, 0)); y += step }

            let n = pts.count
            guard n > 0 else { return }
            let waveHead = phase * Double(n)
            for i in 0..<n {
                var dist = waveHead - Double(i)
                while dist < 0 { dist += Double(n) }
                let active = dist < 10 ? (1 - dist / 10) : 0
                let (pt, nx, ny) = pts[i]
                let len = CGFloat(3.0 + active * 3.4)
                ctx.setStrokeColor(active > 0.2 ? cg(p.accent, alpha: 0.45 + 0.55 * active) : cg(p.primary, alpha: 0.42))
                ctx.setLineWidth(active > 0.2 ? 1.8 : 1.1)
                ctx.beginPath()
                ctx.move(to: pt)
                ctx.addLine(to: CGPoint(x: pt.x + nx * len, y: pt.y + ny * len))
                ctx.strokePath()
            }

        default: // .pingDot
            ctx.setStrokeColor(cg(p.primary, alpha: 0.52))
            ctx.setLineWidth(1.1)
            ctx.stroke(rect)

            let s = 0.5 + 0.44 * sin(phase * 2 * .pi)
            let dirTop: CGFloat = cos(phase * 2 * .pi) >= 0 ? -1 : 1
            let beacons: [(CGFloat, CGFloat, CGFloat)] = [
                (rect.minX + rect.width * CGFloat(s), rect.maxY, dirTop),
                (rect.minX + rect.width * CGFloat(1 - s), rect.minY, -dirTop),
            ]
            for (bx, by, dir) in beacons {
                let trail: CGFloat = 26
                let tx = max(rect.minX, min(rect.maxX, bx + dir * trail))
                let seg = CGMutablePath()
                seg.move(to: CGPoint(x: bx, y: by))
                seg.addLine(to: CGPoint(x: tx, y: by))
                strokeLinearGradient(
                    path: seg, lineWidth: 2.0,
                    start: CGPoint(x: bx, y: by), end: CGPoint(x: tx, y: by),
                    stops: [(0, cg(p.accent, alpha: 0.95)), (1, cg(p.accent, alpha: 0))],
                    in: ctx
                )
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 5, color: cg(p.accent, alpha: 0.85))
                ctx.setFillColor(cg(p.accent, alpha: 1))
                ctx.fill(CGRect(x: bx - 2.2, y: by - 2.2, width: 4.4, height: 4.4))
                ctx.restoreGState()
            }
        }
    }

    // MARK: - 缩放手柄绘制

    static func drawHandles(
        _ config: SelectionBorderConfiguration,
        around rect: CGRect,
        size: CGFloat,
        showsResizeHandles: Bool,
        in context: CGContext
    ) {
        guard showsResizeHandles else { return }
        let p = paletteSpec(for: config.palette)
        context.saveGState()
        defer { context.restoreGState() }

        let isGlassOrMetal = config.style == .liquidGlass || config.style == .titanium || config.style == .editorial
        let points = [
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY),
        ]

        for point in points {
            let side = isGlassOrMetal ? size + 1 : size
            let box = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
            let radius: CGFloat = isGlassOrMetal ? side / 2 : 1.5
            let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: CGColor(gray: 0, alpha: 0.30))
            context.setFillColor(config.style == .liquidGlass ? cg(p.spec, alpha: 0.96) : CGColor(gray: 1, alpha: 1))
            context.setStrokeColor(cg(p.dark, alpha: 0.55))
            context.setLineWidth(1.25)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        }
    }

    // MARK: - 绘图辅助工具

    private static func cg(_ color: RGBAColor, alpha: Double) -> CGColor {
        CGColor(red: color.red, green: color.green, blue: color.blue, alpha: min(1, max(0, alpha)))
    }

    private static func easeInOutQuad(_ u: Double) -> Double {
        u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func clipOutside(bounds: CGRect, opening: CGRect, radius: CGFloat, in ctx: CGContext) {
        ctx.addRect(bounds)
        ctx.addPath(roundedPath(opening, radius: radius))
        ctx.clip(using: .evenOdd)
    }

    private static func strokeLinearGradient(
        path: CGPath,
        lineWidth: CGFloat,
        lineCap: CGLineCap = .butt,
        start: CGPoint,
        end: CGPoint,
        stops: [(CGFloat, CGColor)],
        in ctx: CGContext
    ) {
        let stroked = path.copy(strokingWithWidth: lineWidth, lineCap: lineCap, lineJoin: .round, miterLimit: 2)
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

    private static func drawRadialGlow(center: CGPoint, radius: CGFloat, inner: CGColor, mid: CGColor, in ctx: CGContext) {
        let transparent = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        let colors = [inner, mid, transparent] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.36, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }

    private static func perimeterPoint(around rect: CGRect, fraction: Double) -> CGPoint {
        let perim = 2 * (rect.width + rect.height)
        var d = CGFloat(fraction - floor(fraction)) * perim
        if d < rect.width { return CGPoint(x: rect.minX + d, y: rect.maxY) }
        d -= rect.width
        if d < rect.height { return CGPoint(x: rect.maxX, y: rect.maxY - d) }
        d -= rect.height
        if d < rect.width { return CGPoint(x: rect.maxX - d, y: rect.minY) }
        d -= rect.width
        return CGPoint(x: rect.minX, y: rect.minY + d)
    }
}

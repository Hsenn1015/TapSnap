import AppKit
import QuartzCore
import TapSnapConfig
import TapSnapCore

/// 只负责选区提示；颜色动画由 Core Animation 合成，不重复抓屏或重绘背景。
final class SelectionBorderView: NSView {
    static let handleSize: CGFloat = 7

    /// 外框留出呼吸间距；屏幕边缘处收紧，保持边线可见。
    static func outlineRect(for selection: CGRect, in bounds: CGRect) -> CGRect {
        selection.insetBy(dx: -8, dy: -8).intersection(bounds.insetBy(dx: 5, dy: 5))
    }

    var selectionRect: CGRect? { didSet { updateBorder() } }
    var style: SelectionBorderStyle = .aurora {
        didSet {
            guard style != oldValue else { return }
            sweepPeriod = 0
            updateBorder()
        }
    }
    var showsResizeHandles = false { didSet { updateHandles() } }
    var isPaused = false { didSet { updateAnimation() } }

    private let rim = CAGradientLayer()
    private let halo = CAGradientLayer()
    private let iceMintRim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let haloMask = CAShapeLayer()
    private let iceMintMask = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let sweepGlow = CAShapeLayer()
    private let sweepTrail = CAShapeLayer()
    private let sweepHead = CAShapeLayer()
    private let handlesView = SelectionBorderHandlesView(frame: .zero)
    private var sweeps: [CAShapeLayer] { [sweepGlow, sweepTrail, sweepHead] }
    private var borderRect: CGRect = .null
    private var sweepPeriod: CGFloat = 0
    private var stopped = false
    private let palette = [
        NSColor(srgbRed: 0.12, green: 0.88, blue: 1, alpha: 1).cgColor,
        NSColor(srgbRed: 0.52, green: 0.36, blue: 1, alpha: 1).cgColor,
        NSColor(srgbRed: 1, green: 0.32, blue: 0.80, alpha: 1).cgColor,
        NSColor(srgbRed: 0.38, green: 0.65, blue: 1, alpha: 1).cgColor,
        NSColor(srgbRed: 0.28, green: 1, blue: 0.81, alpha: 1).cgColor,
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for (gradient, mask, width) in [(halo, haloMask, CGFloat(12)), (rim, rimMask, 2.5),
                                       (iceMintRim, iceMintMask, 2)] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradient.colors = palette + [palette[0]]
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = width
            gradient.mask = mask
        }
        iceMintRim.colors = [0x68e1f7, 0x93acff, 0xb49bff, 0x6cebc2, 0x68e1f7].map { RGBAColor(rgb: $0).cgColor }
        iceMintRim.locations = [0, 0.28, 0.51, 0.78, 1]
        halo.opacity = 0.26
        outline.fillColor = nil
        outline.strokeColor = NSColor.black.withAlphaComponent(0.20).cgColor
        outline.lineWidth = 4
        glow.fillColor = nil
        glow.strokeColor = palette[1]
        glow.lineWidth = 3
        glow.shadowColor = palette[1]
        glow.shadowOpacity = 0.85
        glow.shadowRadius = 11
        glow.shadowOffset = .zero
        for sweep in sweeps {
            sweep.fillColor = nil
            sweep.lineCap = .round
            sweep.lineJoin = .round
        }
        sweepGlow.shadowOpacity = 1
        sweepGlow.shadowOffset = .zero
        sweepHead.strokeColor = NSColor.white.cgColor
        ([glow, halo, outline, rim, iceMintRim] + sweeps).forEach { layer?.addSublayer($0) }
        handlesView.border = self
        handlesView.frame = bounds
        handlesView.autoresizingMask = [.width, .height]
        handlesView.wantsLayer = true
        handlesView.layer?.zPosition = 1
        addSubview(handlesView)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateAnimation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func layout() {
        super.layout()
        updateBorder()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !borderRect.isEmpty, style != .aurora, let context = NSGraphicsContext.current?.cgContext else { return }
        SelectionBorderArtwork.drawRim(style, around: borderRect, in: context)
    }

    fileprivate func drawHandles(in context: CGContext) {
        guard !borderRect.isEmpty else { return }
        SelectionBorderArtwork.drawHandles(style, around: borderRect, size: Self.handleSize,
                                           showsResizeHandles: showsResizeHandles, in: context)
    }

    func stopAnimating() {
        stopped = true
        updateAnimation()
    }

    private func updateBorder() {
        if let selectionRect, selectionRect.width >= 1, selectionRect.height >= 1 {
            borderRect = Self.outlineRect(for: selectionRect, in: bounds)
        } else {
            borderRect = .null
        }
        needsDisplay = true
        updateHandles()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.isHidden = borderRect.isEmpty
        let isAurora = style == .aurora
        for layer in [glow, halo, outline, rim] { layer.isHidden = !isAurora }
        iceMintRim.isHidden = style != .iceMint
        if !borderRect.isEmpty {
            switch style {
            case .aurora, .coolWhiteSweep: updateAnimatedPaths()
            case .iceMint:
                iceMintRim.frame = bounds
                iceMintMask.frame = bounds
                iceMintMask.contentsScale = window?.backingScaleFactor ?? 2
                iceMintMask.path = CGPath(roundedRect: borderRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
                let center = CGPoint(x: borderRect.midX / bounds.width, y: borderRect.midY / bounds.height)
                iceMintRim.startPoint = center
                iceMintRim.endPoint = CGPoint(x: center.x - 0.3, y: center.y + 0.4)
            default: break
            }
        }
        CATransaction.commit()
        updateAnimation()
    }

    private func updateHandles() {
        handlesView.isHidden = borderRect.isEmpty || (!showsResizeHandles && style == .aurora)
        if !handlesView.isHidden { handlesView.needsDisplay = true }
    }

    private func updateAnimatedPaths() {
        let path = CGPath(roundedRect: borderRect,
                          cornerWidth: 2, cornerHeight: 2, transform: nil)
        let isAurora = style == .aurora
        for shape in isAurora ? [rimMask, haloMask, outline, glow] + sweeps : sweeps {
            shape.frame = bounds
            shape.path = path
            shape.contentsScale = window?.backingScaleFactor ?? 2
        }
        // 让渐变中心跟着选区走，矩形移动时颜色不会留在屏幕原位置。
        if isAurora, let rect = selectionRect {
            let center = CGPoint(x: rect.midX / bounds.width, y: rect.midY / bounds.height)
            for gradient in [rim, halo] {
                gradient.frame = bounds
                gradient.startPoint = center
                gradient.endPoint = CGPoint(x: center.x, y: center.y + 0.5)
            }
            glow.shadowPath = path.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
        // 极光每半圈重复一次，冷白追光走完整圈后才重复。
        let radius = min(2, borderRect.width / 2, borderRect.height / 2)
        let halfPerimeter = borderRect.width + borderRect.height - 4 * radius + .pi * radius
        let period = isAurora ? halfPerimeter : 2 * halfPerimeter
        if abs(period - sweepPeriod) > 0.5 {
            sweepPeriod = period
            sweepGlow.strokeColor = RGBAColor(rgb: isAurora ? 0x73f2ff : 0x5cbced, alpha: 0.6).cgColor
            sweepGlow.lineWidth = isAurora ? 5 : 2.6
            sweepGlow.shadowColor = isAurora ? palette[0] : RGBAColor(rgb: 0x5cbced).cgColor
            sweepGlow.shadowRadius = isAurora ? 9 : 3
            sweepTrail.strokeColor = RGBAColor(rgb: isAurora ? 0xc4deff : 0xb3edff, alpha: 0.8).cgColor
            sweepTrail.lineWidth = isAurora ? 3 : 1.8
            sweepHead.lineWidth = isAurora ? 2 : 1.4
            let length = min(isAurora ? 80 : 76, period * (isAurora ? 0.22 : 0.17))
            for (sweep, fraction) in [(sweepGlow, CGFloat(1)), (sweepTrail, 0.6), (sweepHead, 0.2)] {
                sweep.lineDashPattern = [NSNumber(value: Double(length * fraction)),
                                         NSNumber(value: Double(period - length * fraction))]
                sweep.removeAnimation(forKey: "borderSweep")
            }
        }
    }

    @objc private func updateAnimation() {
        let moving = !borderRect.isEmpty && window != nil && !stopped && !isPaused
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animateAurora = moving && style == .aurora
        let animateSweep = moving && (style == .aurora || style == .coolWhiteSweep) && sweepPeriod > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = isPaused ? 0.65 : 1
        for gradient in [rim, halo] {
            if animateAurora {
                guard gradient.animation(forKey: "auroraFlow") == nil else { continue }
                let flow = CAKeyframeAnimation(keyPath: "colors")
                flow.values = (0...palette.count).map { offset in
                    (0...palette.count).map { palette[($0 + offset) % palette.count] }
                }
                flow.duration = 4.8
                flow.repeatCount = .infinity
                flow.calculationMode = .linear
                gradient.add(flow, forKey: "auroraFlow")
            } else {
                gradient.removeAnimation(forKey: "auroraFlow")
            }
        }
        for sweep in sweeps {
            sweep.isHidden = !animateSweep
            if animateSweep {
                guard sweep.animation(forKey: "borderSweep") == nil else { continue }
                let chase = CABasicAnimation(keyPath: "lineDashPhase")
                chase.fromValue = 0
                chase.toValue = sweepPeriod
                chase.duration = style == .aurora ? 2.8 : 4.5
                chase.repeatCount = .infinity
                chase.timingFunction = CAMediaTimingFunction(name: .linear)
                sweep.add(chase, forKey: "borderSweep")
            } else {
                sweep.removeAnimation(forKey: "borderSweep")
            }
        }
        if animateAurora {
            if halo.animation(forKey: "auroraBreath") == nil {
                let breath = CABasicAnimation(keyPath: "opacity")
                breath.fromValue = 0.18
                breath.toValue = 0.34
                breath.duration = 1.8
                breath.autoreverses = true
                breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                halo.add(breath, forKey: "auroraBreath")
            }
        } else {
            halo.removeAnimation(forKey: "auroraBreath")
        }
        CATransaction.commit()
    }
}

private final class SelectionBorderHandlesView: NSView {
    weak var border: SelectionBorderView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        border?.drawHandles(in: context)
    }
}

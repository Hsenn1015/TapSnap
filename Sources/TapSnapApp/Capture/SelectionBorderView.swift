import AppKit
import QuartzCore
import TapSnapConfig
import TapSnapCore

/// 只负责选区提示；通过局部 CoreAnimation 可动画图层驱动 7 大风格 × 24 种动效，
/// 仅在选区外框周边 24pt 区域内异步绘制，不重复抓屏或重绘全屏背景。
final class SelectionBorderView: NSView {
    static let handleSize: CGFloat = 7
    private static let renderPadding: CGFloat = 24
    private static let motionAnimationKey = "borderMotion"

    /// 外框留出呼吸间距；屏幕边缘处收紧，保持边线可见。
    static func outlineRect(for selection: CGRect, in bounds: CGRect) -> CGRect {
        let outline = selection.insetBy(dx: -8, dy: -8)
        return bounds.contains(selection) ? outline.intersection(bounds.insetBy(dx: 5, dy: 5)) : outline
    }

    var selectionRect: CGRect? { didSet { updateBorder() } }

    var configuration = SelectionBorderConfiguration() {
        didSet {
            guard configuration != oldValue else { return }
            updateBorder()
        }
    }

    var style: SelectionBorderStyle {
        get { configuration.style }
        set {
            guard newValue != configuration.style else { return }
            configuration = SelectionBorderConfiguration(style: newValue)
        }
    }

    var showsResizeHandles = false { didSet { updateHandles() } }
    var isPaused = false { didSet { updateAnimation() } }

    private let renderLayer = SelectionBorderRenderLayer()
    private let handlesView = SelectionBorderHandlesView(frame: .zero)
    private var borderRect: CGRect = .null
    private var stopped = false
    private var activeMotionDuration: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        renderLayer.borderInset = Self.renderPadding
        renderLayer.animationPhase = 0.26
        layer?.addSublayer(renderLayer)

        handlesView.border = self
        handlesView.frame = bounds
        handlesView.autoresizingMask = [.width, .height]
        handlesView.wantsLayer = true
        handlesView.layer?.zPosition = 1
        addSubview(handlesView)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateAnimation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }

    override func layout() {
        super.layout()
        updateBorder()
    }

    fileprivate func drawHandles(in context: CGContext) {
        guard !borderRect.isEmpty else { return }
        SelectionBorderArtwork.drawHandles(
            configuration,
            around: borderRect,
            size: Self.handleSize,
            showsResizeHandles: showsResizeHandles,
            in: context
        )
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
        updateHandles()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.isHidden = borderRect.isEmpty
        if !borderRect.isEmpty {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            renderLayer.contentsScale = scale
            renderLayer.configuration = configuration
            renderLayer.frame = borderRect.insetBy(dx: -Self.renderPadding, dy: -Self.renderPadding)
            renderLayer.setNeedsDisplay()
        }
        CATransaction.commit()
        updateAnimation()
    }

    private func updateHandles() {
        handlesView.isHidden = borderRect.isEmpty || !showsResizeHandles
        if !handlesView.isHidden { handlesView.needsDisplay = true }
    }

    @objc private func updateAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = isPaused ? 0.55 : 1
        CATransaction.commit()

        let shouldAnimate = !stopped && !isPaused && window != nil && !borderRect.isEmpty
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            renderLayer.removeAnimation(forKey: Self.motionAnimationKey)
            activeMotionDuration = 0
            renderLayer.setNeedsDisplay()
            return
        }

        let duration = configuration.motion.cycleDuration
        if renderLayer.animation(forKey: Self.motionAnimationKey) == nil
            || abs(activeMotionDuration - duration) > 0.01 {
            let animation = CABasicAnimation(keyPath: "animationPhase")
            animation.fromValue = CGFloat(0)
            animation.toValue = CGFloat(1)
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            renderLayer.removeAnimation(forKey: Self.motionAnimationKey)
            renderLayer.add(animation, forKey: Self.motionAnimationKey)
            activeMotionDuration = duration
        }
    }
}

private final class SelectionBorderRenderLayer: CALayer {
    @NSManaged var animationPhase: CGFloat
    var configuration = SelectionBorderConfiguration()
    var borderInset: CGFloat = 24

    override init() {
        super.init()
        isOpaque = false
        drawsAsynchronously = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? SelectionBorderRenderLayer {
            animationPhase = other.animationPhase
            configuration = other.configuration
            borderInset = other.borderInset
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override class func needsDisplay(forKey key: String) -> Bool {
        key == "animationPhase" || super.needsDisplay(forKey: key)
    }

    override func draw(in ctx: CGContext) {
        let rect = bounds.insetBy(dx: borderInset, dy: borderInset)
        guard rect.width >= 1, rect.height >= 1 else { return }
        SelectionBorderArtwork.drawAnimatedBorder(
            configuration,
            around: rect,
            in: bounds,
            phase: Double(animationPhase),
            context: ctx
        )
    }
}

private final class SelectionBorderHandlesView: NSView {
    weak var border: SelectionBorderView?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        border?.drawHandles(in: context)
    }
}

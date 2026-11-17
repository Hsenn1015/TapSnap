import AppKit
import QuartzCore

/// Visual feedback stays in the small toolbar layers. It does not redraw the frozen desktop.
final class SelectionActionBar: NSView {
    typealias Action = SelectionOverlayView.BarButton

    private let backdrop = CALayer()
    private let tip = CALayer()
    private let tipLabel = CATextLayer()
    private var buttons: [Action: CALayer] = [:]
    private var confirmationTitle = "确认 ⏎"
    private var primaryAction: Action = .confirm

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.isGeometryFlipped = false
        backdrop.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        backdrop.cornerRadius = 9
        backdrop.shadowColor = NSColor.black.cgColor
        backdrop.shadowOpacity = 0.27
        backdrop.shadowRadius = 7
        backdrop.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(backdrop)
        tip.backgroundColor = NSColor(white: 0.10, alpha: 0.97).cgColor
        tip.cornerRadius = 5
        tip.isHidden = true
        tip.addSublayer(tipLabel)
        layer?.addSublayer(tip)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(frame: CGRect, buttons layout: [(action: Action, rect: CGRect)], primaryAction: Action,
                confirmationTitle: String) {
        if self.frame != frame { hideTip() }
        self.frame = frame
        self.primaryAction = primaryAction
        self.confirmationTitle = confirmationTitle
        let available = Set(layout.map(\.action))
        for action in Array(buttons.keys) where !available.contains(action) {
            buttons.removeValue(forKey: action)?.removeFromSuperlayer()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        backdrop.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
        for (action, rect) in layout {
            let button = buttons[action] ?? CALayer()
            if button.superlayer == nil {
                button.addSublayer(CATextLayer())
                layer?.insertSublayer(button, below: tip)
                buttons[action] = button
            }
            let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
            button.bounds = CGRect(origin: .zero, size: local.size)
            button.position = CGPoint(x: local.midX, y: local.midY)
            button.cornerRadius = 6
            if let label = button.sublayers?.first as? CATextLayer {
                configureLabel(label, in: button.bounds, title: title(for: action), size: 12)
            }
        }
        CATransaction.commit()
    }

    func updateFeedback(hovered: Action?, pressed: Action?, pending: Action?) {
        let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (action, button) in buttons {
            let isPressed = action == pressed && action == hovered
            let isHovered = action == hovered && pending == nil
            let isPending = action == pending
            let color: NSColor
            if action == primaryAction || isPending {
                color = isPressed ? (accent.blended(withFraction: 0.22, of: .black) ?? accent)
                    : (isHovered ? (accent.blended(withFraction: 0.14, of: .white) ?? accent) : accent)
            } else {
                color = .white.withAlphaComponent(isPressed ? 0.26 : (isHovered ? 0.14 : 0))
            }
            let background = color.cgColor
            if button.backgroundColor != background {
                animate(button, key: "backgroundColor", from: button.presentation()?.backgroundColor ?? button.backgroundColor,
                        to: background, duration: 0.10)
                button.backgroundColor = background
            }

            let scale: CGFloat = isPressed && !reduced ? 0.94 : 1
            let transform = CATransform3DMakeScale(scale, scale, 1)
            if !CATransform3DEqualToTransform(button.transform, transform) {
                animate(button, key: "transform", from: NSValue(caTransform3D: button.presentation()?.transform ?? button.transform),
                        to: NSValue(caTransform3D: transform), duration: isPressed ? 0.07 : 0.13)
                button.transform = transform
            }
            button.opacity = pending == nil || isPending ? 1 : 0.45
            if let label = button.sublayers?.first as? CATextLayer {
                configureLabel(label, in: button.bounds, title: isPending ? "处理中…" : title(for: action), size: 12)
            }
        }
        CATransaction.commit()
    }

    func showTip(for action: Action, at button: CGRect, within screen: CGRect) {
        let title: String
        switch action {
        case .confirm: title = confirmationTitle
        case .cancel: title = "取消框选 Esc"
        case .copy: title = "复制当前选区 ⌘C"
        case .longShot: title = "用当前选区开始长截图"
        case .record: title = "用当前选区开始录屏"
        }
        let width = min(screen.width - 12, action == .confirm || action == .cancel ? 104 : 140)
        let height: CGFloat = 25
        let x = min(max(screen.minX + 6, button.midX - width / 2), screen.maxX - width - 6)
        let below = frame.minY - height - 6
        let y = below >= screen.minY + 6 ? below : frame.maxY + 6
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tip.frame = CGRect(x: x - frame.minX, y: min(y, screen.maxY - height - 6) - frame.minY,
                           width: width, height: height)
        configureLabel(tipLabel, in: tip.bounds, title: title, size: 11)
        tip.isHidden = false
        animate(tip, key: "opacity", from: 0, to: 1, duration: 0.12)
        CATransaction.commit()
    }

    func hideTip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tip.isHidden = true
        tip.removeAnimation(forKey: "opacity")
        CATransaction.commit()
    }

    private func title(for action: Action) -> String {
        switch action {
        case .confirm: return confirmationTitle
        case .cancel: return "取消 ⎋"
        case .copy: return "复制 ⌘C"
        case .longShot: return "长截图"
        case .record: return "录屏"
        }
    }

    private func configureLabel(_ layer: CATextLayer, in bounds: CGRect, title: String, size: CGFloat) {
        let scale = window?.backingScaleFactor ?? 1
        let height = ceil(size * 1.45)
        layer.frame = CGRect(x: 0, y: ((bounds.height - height) * scale / 2).rounded() / scale,
                             width: bounds.width, height: height)
        layer.contentsScale = scale
        if (layer.string as? NSAttributedString)?.string != title {
            layer.string = AnnotateDrawing.attributedText(title, fontSize: size, color: NSColor.white.cgColor)
        }
        layer.alignmentMode = .center
        layer.isWrapped = false
    }

    private func animate(_ layer: CALayer, key: String, from: Any?, to: Any, duration: CFTimeInterval) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: key)
    }
}

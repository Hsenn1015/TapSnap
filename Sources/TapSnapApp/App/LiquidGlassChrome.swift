import AppKit
import TapSnapTheme
import UniformTypeIdentifiers

/// 液态玻璃工作台的柔和光晕画布背景，彻底消除大黑边与死板纯灰底。
final class LiquidGlassBackdropView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let glowLayer = CAGradientLayer()
    private var isDark: Bool

    init(isDark: Bool) {
        self.isDark = isDark
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        gradientLayer.startPoint = CGPoint(x: 0.0, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.0)
        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.18, y: 0.92)
        glowLayer.endPoint = CGPoint(x: 0.85, y: 0.12)
        layer?.addSublayer(gradientLayer)
        layer?.addSublayer(glowLayer)
        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDark(_ dark: Bool) {
        guard isDark != dark else { return }
        isDark = dark
        applyPalette()
    }

    private func applyPalette() {
        if isDark {
            gradientLayer.colors = [
                NSColor(srgbRed: 0.085, green: 0.105, blue: 0.165, alpha: 1).cgColor,
                NSColor(srgbRed: 0.068, green: 0.080, blue: 0.122, alpha: 1).cgColor,
                NSColor(srgbRed: 0.055, green: 0.064, blue: 0.098, alpha: 1).cgColor,
            ]
            glowLayer.colors = [
                NSColor(srgbRed: 0.24, green: 0.44, blue: 0.86, alpha: 0.22).cgColor,
                NSColor(srgbRed: 0.16, green: 0.24, blue: 0.48, alpha: 0.08).cgColor,
                NSColor.clear.cgColor,
            ]
        } else {
            gradientLayer.colors = [
                NSColor(srgbRed: 0.945, green: 0.960, blue: 0.992, alpha: 1).cgColor,
                NSColor(srgbRed: 0.916, green: 0.933, blue: 0.965, alpha: 1).cgColor,
                NSColor(srgbRed: 0.892, green: 0.912, blue: 0.948, alpha: 1).cgColor,
            ]
            glowLayer.colors = [
                NSColor(srgbRed: 0.56, green: 0.72, blue: 1.0, alpha: 0.18).cgColor,
                NSColor(srgbRed: 0.78, green: 0.86, blue: 1.0, alpha: 0.07).cgColor,
                NSColor.clear.cgColor,
            ]
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        glowLayer.frame = bounds
        CATransaction.commit()
    }
}

/// 通透毛玻璃浮岛容器（带镜面高光内描边与柔和悬浮阴影）。
final class LiquidGlassIslandView: NSView {
    private let shadowHost = NSView()
    private let effectView = NSVisualEffectView()
    private let tintLayer = CAGradientLayer()
    private let rimLayer = CAShapeLayer()
    private var isDark: Bool
    private let cornerRadiusValue: CGFloat?
    let contentContainer = NSView()

    init(isDark: Bool, cornerRadius: CGFloat? = nil) {
        self.isDark = isDark
        self.cornerRadiusValue = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        shadowHost.wantsLayer = true
        shadowHost.layer?.masksToBounds = false
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shadowHost)

        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.material = isDark ? .hudWindow : .popover
        effectView.wantsLayer = true
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.addSubview(effectView)

        tintLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        tintLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        effectView.layer?.addSublayer(tintLayer)

        rimLayer.fillColor = NSColor.clear.cgColor
        rimLayer.lineWidth = 1.0
        effectView.layer?.addSublayer(rimLayer)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            shadowHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            shadowHost.topAnchor.constraint(equalTo: topAnchor),
            shadowHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: effectView.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDark(_ dark: Bool) {
        guard isDark != dark else { return }
        isDark = dark
        effectView.material = dark ? .hudWindow : .popover
        applyAppearance()
    }

    private func applyAppearance() {
        if isDark {
            tintLayer.colors = [
                NSColor(srgbRed: 0.22, green: 0.27, blue: 0.38, alpha: 0.44).cgColor,
                NSColor(srgbRed: 0.13, green: 0.16, blue: 0.24, alpha: 0.50).cgColor,
            ]
            rimLayer.strokeColor = NSColor.white.withAlphaComponent(0.20).cgColor
            shadowHost.layer?.shadowColor = NSColor.black.cgColor
            shadowHost.layer?.shadowOpacity = 0.45
            shadowHost.layer?.shadowRadius = 16
            shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -5)
        } else {
            tintLayer.colors = [
                NSColor.white.withAlphaComponent(0.76).cgColor,
                NSColor(srgbRed: 0.96, green: 0.975, blue: 1.0, alpha: 0.58).cgColor,
            ]
            rimLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
            shadowHost.layer?.shadowColor = NSColor(srgbRed: 0.08, green: 0.14, blue: 0.26, alpha: 1).cgColor
            shadowHost.layer?.shadowOpacity = 0.12
            shadowHost.layer?.shadowRadius = 14
            shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -4)
        }
    }

    override func layout() {
        super.layout()
        let radius = cornerRadiusValue ?? (bounds.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectView.layer?.cornerRadius = radius
        shadowHost.layer?.cornerRadius = radius
        tintLayer.frame = effectView.bounds
        rimLayer.frame = effectView.bounds
        let inset = effectView.bounds.insetBy(dx: 0.5, dy: 0.5)
        rimLayer.path = CGPath(roundedRect: inset, cornerWidth: max(0, radius - 0.5),
                               cornerHeight: max(0, radius - 0.5), transform: nil)
        CATransaction.commit()
    }
}

/// 液态玻璃药丸按钮：支持丝滑悬停、高光渐变、快捷键角标，以及原地绿色「✓ 已复制」变形反馈。
final class LiquidGlassPillButton: NSButton {
    override class var cellClass: AnyClass? {
        get { PillButtonCell.self }
        set {}
    }

    enum Tone {
        case ghost
        case subtle
        case accent
        case accentSoft
        case success
    }

    private let gradientLayer = CAGradientLayer()
    private let highlightLayer = CALayer()
    private let rimLayer = CAShapeLayer()
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var isDark = true
    private var baseTone: Tone = .subtle
    private var activeTone: Tone = .subtle
    private var shortcutHint: String?
    private var horizontalPadding: CGFloat = 12
    private var buttonHeight: CGFloat = 30
    private var isCapsule = true
    private var isHovering = false
    private var isPressing = false
    private var successTimer: Timer?
    private var savedTitle: String?
    private var savedSymbol: String?
    private var currentSymbol: String?

    func configure(
        title: String,
        symbol: String? = nil,
        shortcut: String? = nil,
        tone: Tone = .subtle,
        isDark: Bool,
        height: CGFloat = 30,
        horizontalPadding: CGFloat = 12,
        capsule: Bool = true
    ) {
        self.isDark = isDark
        self.baseTone = tone
        self.activeTone = tone
        self.shortcutHint = shortcut
        self.buttonHeight = height
        self.horizontalPadding = horizontalPadding
        self.isCapsule = capsule
        self.currentSymbol = symbol
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 12, weight: tone == .accent || tone == .success ? .semibold : .medium)
        wantsLayer = true
        layer?.masksToBounds = false

        if gradientLayer.superlayer == nil {
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
            layer?.addSublayer(gradientLayer)
        }
        if highlightLayer.superlayer == nil {
            highlightLayer.opacity = 0
            layer?.addSublayer(highlightLayer)
        }
        if rimLayer.superlayer == nil {
            rimLayer.fillColor = NSColor.clear.cgColor
            rimLayer.lineWidth = 0.75
            layer?.addSublayer(rimLayer)
        }
        if shortcutLabel.superview == nil {
            shortcutLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
            shortcutLabel.alignment = .center
            shortcutLabel.isSelectable = false
            shortcutLabel.isEditable = false
            shortcutLabel.drawsBackground = false
            shortcutLabel.wantsLayer = true
            shortcutLabel.layer?.cornerRadius = 5
            addSubview(shortcutLabel)
        }

        applySymbol(symbol)
        applyToneVisuals()
        rebuildTrackingArea()
        invalidateIntrinsicContentSize()
    }

    func updateContent(title: String, symbol: String? = nil, shortcut: String? = nil) {
        cancelSuccessFlash()
        self.title = title
        self.currentSymbol = symbol
        self.shortcutHint = shortcut
        applySymbol(symbol)
        applyToneVisuals()
        invalidateIntrinsicContentSize()
    }

    func setTone(_ tone: Tone) {
        baseTone = tone
        if successTimer == nil {
            activeTone = tone
            applyToneVisuals()
        }
    }

    func setDark(_ dark: Bool) {
        isDark = dark
        applyToneVisuals()
    }

    /// 原地绿色「✓ 已复制 / 已保存」丝滑变形反馈，1.5 秒后自动还原。
    func flashSuccess(_ feedbackTitle: String, duration: TimeInterval = 1.5) {
        if savedTitle == nil {
            savedTitle = title
            savedSymbol = currentSymbol
        }
        successTimer?.invalidate()
        activeTone = .success
        title = feedbackTitle
        applySymbol("checkmark")
        applyToneVisuals(hideShortcut: true)
        invalidateIntrinsicContentSize()
        successTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restoreAfterSuccess()
            }
        }
    }

    private func cancelSuccessFlash() {
        successTimer?.invalidate()
        successTimer = nil
        savedTitle = nil
        savedSymbol = nil
        activeTone = baseTone
    }

    private func restoreAfterSuccess() {
        successTimer?.invalidate()
        successTimer = nil
        guard let originalTitle = savedTitle else { return }
        let originalSymbol = savedSymbol
        savedTitle = nil
        savedSymbol = nil
        activeTone = baseTone
        title = originalTitle
        currentSymbol = originalSymbol
        applySymbol(originalSymbol)
        applyToneVisuals()
        invalidateIntrinsicContentSize()
    }

    private func applySymbol(_ symbol: String?) {
        guard let symbol, !symbol.isEmpty else {
            image = nil
            imagePosition = .noImage
            return
        }
        let weight: NSFont.Weight = (activeTone == .accent || activeTone == .success) ? .semibold : .medium
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: weight))
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageHugsTitle = true
    }

    private func applyToneVisuals(hideShortcut: Bool = false) {
        let foreground: NSColor
        let topColor: NSColor
        let bottomColor: NSColor
        let rimColor: NSColor
        let hoverColor: NSColor

        switch activeTone {
        case .accent:
            foreground = .white
            topColor = NSColor(srgbRed: 0.25, green: 0.56, blue: 1.0, alpha: 1)
            bottomColor = NSColor(srgbRed: 0.14, green: 0.39, blue: 0.92, alpha: 1)
            rimColor = NSColor.white.withAlphaComponent(0.32)
            hoverColor = NSColor.white.withAlphaComponent(0.18)
            layer?.shadowColor = NSColor(srgbRed: 0.15, green: 0.42, blue: 0.95, alpha: 1).cgColor
            layer?.shadowOpacity = isDark ? 0.42 : 0.28
            layer?.shadowRadius = 8
            layer?.shadowOffset = CGSize(width: 0, height: -2)
        case .success:
            foreground = .white
            topColor = NSColor(srgbRed: 0.13, green: 0.78, blue: 0.54, alpha: 1)
            bottomColor = NSColor(srgbRed: 0.04, green: 0.60, blue: 0.42, alpha: 1)
            rimColor = NSColor.white.withAlphaComponent(0.30)
            hoverColor = NSColor.white.withAlphaComponent(0.16)
            layer?.shadowColor = NSColor(srgbRed: 0.06, green: 0.68, blue: 0.46, alpha: 1).cgColor
            layer?.shadowOpacity = 0.36
            layer?.shadowRadius = 8
            layer?.shadowOffset = CGSize(width: 0, height: -2)
        case .accentSoft:
            foreground = isDark
                ? NSColor(srgbRed: 0.46, green: 0.72, blue: 1.0, alpha: 1)
                : NSColor(srgbRed: 0.14, green: 0.39, blue: 0.92, alpha: 1)
            let fill = NSColor(srgbRed: 0.22, green: 0.51, blue: 0.97, alpha: isDark ? 0.22 : 0.12)
            topColor = fill
            bottomColor = fill
            rimColor = foreground.withAlphaComponent(0.22)
            hoverColor = foreground.withAlphaComponent(0.14)
            layer?.shadowOpacity = 0
        case .subtle:
            foreground = isDark ? NSColor(white: 0.94, alpha: 1) : NSColor(srgbRed: 0.08, green: 0.11, blue: 0.18, alpha: 1)
            let fill = isDark ? NSColor.white.withAlphaComponent(0.085) : NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.065)
            topColor = fill
            bottomColor = fill
            rimColor = isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.07)
            hoverColor = isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)
            layer?.shadowOpacity = 0
        case .ghost:
            foreground = isDark ? NSColor(white: 0.88, alpha: 1) : NSColor(srgbRed: 0.14, green: 0.18, blue: 0.26, alpha: 1)
            topColor = .clear
            bottomColor = .clear
            rimColor = .clear
            hoverColor = isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.07)
            layer?.shadowOpacity = 0
        }

        contentTintColor = foreground
        gradientLayer.colors = [topColor.cgColor, bottomColor.cgColor]
        rimLayer.strokeColor = rimColor.cgColor
        highlightLayer.backgroundColor = hoverColor.cgColor

        if !title.isEmpty {
            let weight: NSFont.Weight = (activeTone == .accent || activeTone == .success) ? .semibold : .medium
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: weight),
                .foregroundColor: foreground,
            ])
        }
        let showShortcut = !hideShortcut && shortcutHint != nil && !(shortcutHint?.isEmpty ?? true)
        shortcutLabel.isHidden = !showShortcut
        (cell as? PillButtonCell)?.trailingReserve = showShortcut ? 28 : 0
        if showShortcut, let hint = shortcutHint {
            shortcutLabel.stringValue = hint
            shortcutLabel.textColor = foreground.withAlphaComponent(0.85)
            shortcutLabel.layer?.backgroundColor = foreground.withAlphaComponent(0.16).cgColor
        }
        needsLayout = true
    }

    private func rebuildTrackingArea() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        if title.isEmpty {
            return CGSize(width: max(buttonHeight, base.width), height: buttonHeight)
        }
        let extraShortcut: CGFloat = shortcutLabel.isHidden ? 0 : 28
        return CGSize(width: ceil(base.width) + horizontalPadding * 2 + extraShortcut, height: buttonHeight)
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.42
            updateHighlight()
        }
    }

    override func layout() {
        super.layout()
        let radius = isCapsule ? bounds.height / 2 : 9
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        gradientLayer.cornerRadius = radius
        highlightLayer.frame = bounds
        highlightLayer.cornerRadius = radius
        rimLayer.frame = bounds
        rimLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: max(0, radius - 0.5), cornerHeight: max(0, radius - 0.5), transform: nil)
        CATransaction.commit()
        if !shortcutLabel.isHidden {
            let badgeW: CGFloat = 24
            let badgeH: CGFloat = 15
            shortcutLabel.frame = CGRect(x: bounds.width - badgeW - 7, y: (bounds.height - badgeH) / 2,
                                         width: badgeW, height: badgeH)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        updateHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        updateHighlight()
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        updateHighlight()
        defer {
            isPressing = false
            updateHighlight()
        }
        super.mouseDown(with: event)
    }

    private func updateHighlight() {
        let target: Float = !isEnabled ? 0 : isPressing ? 1 : isHovering ? 0.65 : 0
        guard highlightLayer.opacity != target else { return }
        let previous = highlightLayer.presentation()?.opacity ?? highlightLayer.opacity
        highlightLayer.removeAnimation(forKey: "opacity")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.opacity = target
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = previous
        anim.toValue = target
        anim.duration = isPressing ? 0.06 : 0.14
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        highlightLayer.add(anim, forKey: "opacity")
    }
}

private final class PillButtonCell: NSButtonCell {
    var trailingReserve: CGFloat = 0

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var r = super.drawingRect(forBounds: rect)
        if trailingReserve > 0, r.width > trailingReserve + 24 {
            r.size.width -= trailingReserve
        }
        return r
    }
}

/// 液态玻璃分段胶囊（例如 `[ MP4 | GIF ]` 或 `[ 适合宽度 | 1:1 像素 ]`）。
final class LiquidGlassSegmentPill: NSView {
    struct Option {
        let title: String
        let symbol: String?
    }

    var selectedIndex: Int = 0 {
        didSet {
            if selectedIndex != oldValue {
                updateSelection(animated: true)
            }
        }
    }
    var isEnabled: Bool = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.45
            buttons.forEach { $0.isEnabled = isEnabled }
        }
    }
    var onSelect: ((Int) -> Void)?

    private var isDark: Bool
    private let thumbLayer = CALayer()
    private let stack = NSStackView()
    private var buttons: [NSButton] = []

    init(options: [Option], isDark: Bool, height: CGFloat = 28) {
        self.isDark = isDark
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.masksToBounds = false

        thumbLayer.cornerRadius = (height - 4) / 2
        thumbLayer.shadowColor = NSColor.black.cgColor
        thumbLayer.shadowOpacity = isDark ? 0.35 : 0.12
        thumbLayer.shadowRadius = 4
        thumbLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(thumbLayer)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])

        for (idx, option) in options.enumerated() {
            let btn = NSButton(title: option.title, target: self, action: #selector(didTap(_:)))
            btn.tag = idx
            btn.isBordered = false
            btn.bezelStyle = .regularSquare
            btn.setContentHuggingPriority(.required, for: .horizontal)
            if let symbol = option.symbol {
                btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: option.title)?
                    .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
                btn.imagePosition = .imageLeading
                btn.imageHugsTitle = true
            }
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
            btn.heightAnchor.constraint(equalToConstant: height - 4).isActive = true
            buttons.append(btn)
            stack.addArrangedSubview(btn)
        }
        applyPalette()
        updateSelection(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDark(_ dark: Bool) {
        isDark = dark
        applyPalette()
        updateSelection(animated: false)
    }

    private func applyPalette() {
        layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor(srgbRed: 0.06, green: 0.09, blue: 0.16, alpha: 0.065)).cgColor
        thumbLayer.backgroundColor = (isDark
            ? NSColor(srgbRed: 0.23, green: 0.27, blue: 0.37, alpha: 0.96)
            : NSColor.white).cgColor
    }

    @objc private func didTap(_ sender: NSButton) {
        guard isEnabled, sender.tag != selectedIndex else { return }
        selectedIndex = sender.tag
        onSelect?(selectedIndex)
    }

    private func updateSelection(animated: Bool) {
        let activeColor = isDark ? NSColor.white : NSColor(srgbRed: 0.07, green: 0.10, blue: 0.18, alpha: 1)
        let mutedColor = isDark ? NSColor(white: 0.72, alpha: 1) : NSColor(srgbRed: 0.38, green: 0.44, blue: 0.54, alpha: 1)
        for (idx, btn) in buttons.enumerated() {
            let active = idx == selectedIndex
            let fg = active ? activeColor : mutedColor
            btn.contentTintColor = fg
            btn.attributedTitle = NSAttributedString(string: btn.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: active ? .semibold : .medium),
                .foregroundColor: fg,
            ])
        }
        positionThumb(animated: animated)
    }

    private func positionThumb(animated: Bool) {
        guard buttons.indices.contains(selectedIndex) else { return }
        let frame = buttons[selectedIndex].convert(buttons[selectedIndex].bounds, to: self)
        guard frame.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        thumbLayer.frame = frame
        thumbLayer.cornerRadius = frame.height / 2
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        positionThumb(animated: false)
    }
}

/// 原生 macOS 拖拽直发胶囊：按住直接拖到微信、飞书、Slack、浏览器或访达里发送文件。
final class LiquidGlassDragOutChip: NSView, NSDraggingSource {
    struct DragPayload {
        let fileType: UTType
        let fileName: String
        let previewImage: NSImage
        let writeFile: @Sendable (URL) async throws -> Void
    }

    var isEnabled: Bool = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.42
            window?.invalidateCursorRects(for: self)
        }
    }
    var payloadProvider: (() -> DragPayload?)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "拖出发送")
    private var isDark: Bool
    private var isHovering = false
    private var mouseDownPoint: CGPoint?
    private var didStartDrag = false
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.tapsnap.dragout.promise"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var activePromiseDelegate: PromiseWriter?

    init(title: String = "拖出发送", isDark: Bool) {
        self.isDark = isDark
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 15
        toolTip = "按住拖到微信、Slack、飞书或访达，直接发送当前文件"
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        iconView.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setDark(_ dark: Bool) {
        isDark = dark
        applyColors()
    }

    private func applyColors() {
        let fg = isDark ? NSColor(white: 0.78, alpha: 1) : NSColor(srgbRed: 0.34, green: 0.40, blue: 0.50, alpha: 1)
        iconView.contentTintColor = fg
        label.textColor = fg
        layer?.backgroundColor = (isHovering
            ? (isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.065))
            : NSColor.clear).cgColor
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        applyColors()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, !didStartDrag, let origin = mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - origin.x, current.y - origin.y) >= 4 else { return }
        guard let payload = payloadProvider?() else { return }
        didStartDrag = true

        let writer = PromiseWriter(fileName: payload.fileName, queue: promiseQueue, writeFile: payload.writeFile)
        activePromiseDelegate = writer
        let provider = NSFilePromiseProvider(fileType: payload.fileType.identifier, delegate: writer)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let previewSize = CGSize(width: 68, height: 48)
        let dragOrigin = CGPoint(x: current.x - previewSize.width / 2, y: current.y - previewSize.height / 2)
        item.setDraggingFrame(CGRect(origin: dragOrigin, size: previewSize), contents: payload.previewImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        didStartDrag = false
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    private final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
        let fileName: String
        let queue: OperationQueue
        let writeFile: @Sendable (URL) async throws -> Void

        init(fileName: String, queue: OperationQueue, writeFile: @escaping @Sendable (URL) async throws -> Void) {
            self.fileName = fileName
            self.queue = queue
            self.writeFile = writeFile
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            fileName
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            queue
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            let taskWrite = writeFile
            Task.detached(priority: .userInitiated) {
                do {
                    try await taskWrite(url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }
}

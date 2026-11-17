import AppKit

/// Canvas-native text input: NSTextView owns selection, IME composition, paste and text undo.
final class InlineTextEditorView: NSTextView, NSTextViewDelegate {
    var onTextChanged: ((String) -> Void)?
    var onFinish: ((Bool) -> Void)?
    private var applyingModel = false
    private var appliedStyle: EditItemStyle?
    private var appliedScale: CGFloat?
    private weak var item: TextItem?
    private var displayScale: CGFloat = 1

    convenience init() {
        self.init(frame: .zero)
        delegate = self
        isRichText = false
        importsGraphics = false
        isEditable = true
        isSelectable = true
        drawsBackground = false
        allowsUndo = true
        usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 2
        setAccessibilityLabel("文字标注输入框")
        toolTip = "直接输入文字；回车换行，⌘ 回车完成，Esc 取消"
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: .NSUndoManagerDidUndoChange, object: nil)
        center.removeObserver(self, name: .NSUndoManagerDidRedoChange, object: nil)
        guard window != nil else { return }
        // Native undo can edit text storage without sending textDidChange to the delegate.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.addObserver(self, selector: #selector(textUndoDidFinish(_:)), name: name, object: nil)
        }
    }

    @objc private func textUndoDidFinish(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager, manager === undoManager else { return }
        if !applyingModel { onTextChanged?(string) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(item: TextItem, displayScale: CGFloat, initial: Bool) {
        let scale = max(0.01, displayScale)
        self.item = item
        self.displayScale = scale
        needsDisplay = true
        let cap = item.textContainerWidth ?? item.bounds.width
        frame = CGRect(x: item.bounds.minX * scale, y: item.bounds.minY * scale,
                       width: max(24, cap) * scale, height: max(20, item.bounds.height) * scale)
        textContainerInset = CGSize(width: TextItem.textInset.width * scale,
                                   height: TextItem.textInset.height * scale)
        textContainer?.containerSize = CGSize(width: max(1, frame.width - textContainerInset.width * 2),
                                               height: .greatestFiniteMagnitude)
        // Marked text belongs to the input method. Do not replace its storage or range mid-composition.
        guard !hasMarkedText() else { return }
        let replacesText = initial || string != item.text
        guard replacesText || appliedStyle != item.style || appliedScale != scale else { return }
        applyingModel = true
        defer { applyingModel = false }
        let selection = selectedRange()
        if replacesText { string = item.text }
        appliedStyle = item.style
        appliedScale = scale
        let attributes = item.textAttributes(scale: scale)
        if let font = attributes[.font] as? NSFont { self.font = font }
        if let color = attributes[.foregroundColor] as? NSColor {
            textColor = color
            insertionPointColor = color
        }
        defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        typingAttributes = attributes
        if let textStorage, textStorage.length > 0 {
            textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
        }
        if initial { setSelectedRange(NSRange(location: (string as NSString).length, length: 0)) }
        else if selection.location <= (string as NSString).length {
            setSelectedRange(NSRange(location: selection.location,
                                     length: min(selection.length, (string as NSString).length - selection.location)))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let item, !item.text.isEmpty, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.scaleBy(x: displayScale, y: displayScale)
            item.drawBackground(in: context, bounds: CGRect(origin: .zero, size: item.bounds.size))
            context.restoreGState()
        }
        super.draw(dirtyRect)
    }

    func textDidChange(_ notification: Notification) {
        if !applyingModel { onTextChanged?(string) }
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 53 { onFinish?(false); return }
            if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command) {
                onFinish?(true)
                return
            }
        }
        super.keyDown(with: event)
    }

    func finalizeComposition(commit: Bool) {
        if commit { unmarkText() }
        inputContext?.discardMarkedText()
        if commit { onTextChanged?(string) }
    }
}

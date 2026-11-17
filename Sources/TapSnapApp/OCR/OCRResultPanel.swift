import AppKit
import TapSnapOCR
import TapSnapTheme
import SwiftUI

/// 文字识别结果面板。支持按段阅读、按原图行核对和 Markdown 预览。
final class OCRResultPanel {
    private let theme: () -> Theme
    private var window: NSWindow?

    init(theme: @escaping () -> Theme) {
        self.theme = theme
    }

    func show(document: OCRDocument, markdownSource: (() async -> String)? = nil, onCopy: @escaping (String) -> Void) {
        close()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = makeWindow(
            document: document, frame: Self.panelFrame(near: mouse, in: visible),
            markdownSource: markdownSource, onCopy: onCopy
        )
        panel.orderFrontRegardless()
        panel.makeKey()
        window = panel
    }

    func makeWindow(
        document: OCRDocument, frame: CGRect, markdownSource: (() async -> String)? = nil,
        onCopy: @escaping (String) -> Void
    ) -> NSPanel {
        let view = OCRResultView(
            document: document,
            theme: theme(),
            makeMarkdownSource: markdownSource,
            onCopy: onCopy,
            onClose: { [weak self] in self?.close() }
        )
        let panel = OCRResultWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        panel.title = "识别结果"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.contentViewController = hosting
        panel.contentMinSize = CGSize(width: min(360, frame.width), height: min(250, frame.height))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.appearance = NSAppearance(named: view.theme.isDark ? .darkAqua : .aqua)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.setFrame(frame, display: false)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        return panel
    }

    static func panelFrame(near mouse: CGPoint, in visible: CGRect) -> CGRect {
        let available = visible.insetBy(dx: 12, dy: 12)
        let width = min(456, available.width)
        let height = min(486, available.height)
        return CGRect(
            x: min(max(available.minX, mouse.x - width / 2), available.maxX - width),
            y: min(max(available.minY, mouse.y - height - 12), available.maxY - height),
            width: width, height: height
        )
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class OCRResultWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum OCRResultDisplayMode: Hashable {
    case paragraphs
    case originalLines
    case markdownPreview
    case markdownSource

    var isMarkdown: Bool { self == .markdownPreview || self == .markdownSource }

    func copyText(in document: OCRDocument, markdownSource: String? = nil) -> String {
        switch self {
        case .paragraphs: return document.paragraphText
        case .originalLines: return document.originalLinesText
        case .markdownPreview, .markdownSource: return markdownSource ?? OCRMarkdown.source(from: document)
        }
    }
}

private struct OCRResultView: View {
    let document: OCRDocument
    let theme: Theme
    let makeMarkdownSource: (() async -> String)?
    let onCopy: (String) -> Void
    let onClose: () -> Void
    @State private var mode: OCRResultDisplayMode = .paragraphs
    @State private var markdownSource: String?
    @State private var isLoadingMarkdown = false

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            header
            modeBar
            Group {
                if mode.isMarkdown && markdownSource == nil {
                    ProgressView("正在整理 Markdown…")
                        .controlSize(.small)
                } else {
                    reader
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.token(.card))
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.token(.border), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .padding([.horizontal, .bottom], 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.token(.foreground))
        .background(theme.token(.muted))
        .clipShape(outline)
        .overlay {
            outline.strokeBorder(theme.token(.foreground).opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onExitCommand(perform: onClose)
    }

    @ViewBuilder
    private var reader: some View {
        switch mode {
        case .markdownPreview:
            OCRMarkdownPreview(source: markdownSource ?? "", theme: theme)
        case .markdownSource:
            OCRMarkdownSourceEditor(source: Binding(
                get: { markdownSource ?? "" },
                set: { markdownSource = $0 }
            ))
        case .paragraphs, .originalLines:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if mode == .paragraphs {
                        ForEach(document.blocks) { block in
                            textRow(block.paragraphText, copyLabel: "复制此段", separated: block.id != document.blocks.first?.id)
                        }
                    } else {
                        let lines = document.originalLines
                        ForEach(lines) { line in
                            textRow(line.text, copyLabel: "复制此行", separated: line.id != lines.first?.id)
                        }
                    }
                }
            }
            .id(mode)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.token(.primary))
                    .frame(width: 30, height: 30)
                    .background(theme.token(.muted), in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text("识别结果")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { WindowDragArea().accessibilityHidden(true) }
            .help("拖动标题栏移动窗口")

            Button { onCopy(mode.copyText(in: document, markdownSource: markdownSource)) } label: {
                Label(mode.isMarkdown ? "复制 Markdown" : "复制全部", systemImage: "document.on.document")
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
                    .foregroundStyle(theme.token(.primaryForeground))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(theme.token(.primary), in: .rect(cornerRadius: 8))
            }
            .buttonStyle(SnapPressStyle())
            .disabled(mode.isMarkdown && markdownSource == nil)
            .opacity(mode.isMarkdown && markdownSource == nil ? 0.48 : 1)
            .help(mode.isMarkdown ? "复制当前 Markdown 源码" : "复制当前模式的全部文字")
            iconButton("关闭识别结果", icon: "xmark", action: onClose)
        }
        .padding(.horizontal, 13)
        .frame(height: 52)
        .background(theme.token(.popover))
        .overlay(alignment: .bottom) {
            Divider().allowsHitTesting(false)
        }
    }

    private var modeBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                modeButton("按段", selected: mode == .paragraphs) { mode = .paragraphs }
                modeButton("按原图行", selected: mode == .originalLines) { mode = .originalLines }
                modeButton("Markdown", selected: mode.isMarkdown) {
                    guard !mode.isMarkdown else { return }
                    mode = .markdownPreview
                    loadMarkdown()
                }
            }
            .padding(2)
            .background(theme.token(.background).opacity(0.7), in: .rect(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("识别结果显示方式")
            Spacer(minLength: 0)
            if mode.isMarkdown {
                HStack(spacing: 2) {
                    modeButton("预览", selected: mode == .markdownPreview) { mode = .markdownPreview }
                    modeButton("源码", selected: mode == .markdownSource) { mode = .markdownSource }
                }
                .padding(2)
                .background(theme.token(.background).opacity(0.7), in: .rect(cornerRadius: 8))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Markdown 显示方式")
            } else {
                Text(mode == .paragraphs ? "\(document.blocks.count) 段" : "\(document.originalLines.count) 行")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.token(.mutedForeground))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
    }

    private func loadMarkdown() {
        guard markdownSource == nil, !isLoadingMarkdown else { return }
        guard let makeMarkdownSource else {
            markdownSource = OCRMarkdown.source(from: document)
            return
        }
        isLoadingMarkdown = true
        Task { @MainActor in
            markdownSource = await makeMarkdownSource()
            isLoadingMarkdown = false
        }
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(theme.token(selected ? .foreground : .mutedForeground))
                .padding(.horizontal, 10)
                .frame(height: 25)
                .background(selected ? theme.token(.popover) : .clear, in: .rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? theme.token(.border) : .clear, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .contentShape(.rect)
        }
        .buttonStyle(SnapPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func textRow(_ text: String, copyLabel: String, separated: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            iconButton(copyLabel, icon: "document.on.document") { onCopy(text) }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            if separated {
                Divider().padding(.horizontal, 13).allowsHitTesting(false)
            }
        }
    }

    private func iconButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.token(.mutedForeground))
                .frame(width: 28, height: 28)
                .background(theme.token(.muted), in: .rect(cornerRadius: 7))
        }
        .buttonStyle(SnapPressStyle(scale: 0.94))
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct OCRMarkdownSourceEditor: NSViewRepresentable {
    @Binding var source: String

    func makeCoordinator() -> Coordinator { Coordinator(source: $source) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let editor = scrollView.documentView as? NSTextView else { return scrollView }
        context.coordinator.editor = editor
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 9, height: 10)
        editor.setAccessibilityLabel("Markdown 源码")
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? NSTextView, !editor.hasMarkedText(), editor.string != source else { return }
        editor.string = source
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var editor: NSTextView?
        @Binding private var source: String

        init(source: Binding<String>) {
            _source = source
            super.init()
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoDidFinish(_:)), name: name, object: nil)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func textDidChange(_ notification: Notification) {
            synchronizeSource()
        }

        @objc private func undoDidFinish(_ notification: Notification) {
            // Native text undo does not always send textDidChange to the delegate.
            guard let manager = notification.object as? UndoManager, manager === editor?.undoManager else { return }
            synchronizeSource()
        }

        private func synchronizeSource() {
            guard let editor, !editor.hasMarkedText(), source != editor.string else { return }
            source = editor.string
        }
    }
}

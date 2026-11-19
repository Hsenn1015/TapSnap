import AppKit
import TapSnapOCR
import TapSnapTheme
import SwiftUI

/// 并排显示 OCR 原图和结果，支持按段、按原图行和 Markdown。
final class OCRResultPanel {
    private let theme: () -> Theme
    private var window: NSWindow?

    init(theme: @escaping () -> Theme) {
        self.theme = theme
    }

    func show(document: OCRDocument, image: CGImage, markdownSource: (() async -> String)? = nil,
              onCopy: @escaping (String) -> Void) {
        close()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = makeWindow(
            document: document, image: image, frame: Self.panelFrame(near: mouse, in: visible),
            markdownSource: markdownSource, onCopy: onCopy
        )
        panel.orderFrontRegardless()
        panel.makeKey()
        window = panel
    }

    func makeWindow(
        document: OCRDocument, image: CGImage, frame: CGRect, markdownSource: (() async -> String)? = nil,
        onCopy: @escaping (String) -> Void
    ) -> NSPanel {
        let view = OCRResultView(
            document: document,
            image: image,
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
        panel.contentMinSize = CGSize(width: min(660, frame.width), height: min(310, frame.height))
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
        let width = min(860, available.width)
        let height = min(540, available.height)
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

    func reviewRows(in document: OCRDocument, matching query: String) -> [OCRReviewRow] {
        let rows: [OCRReviewRow]
        switch self {
        case .paragraphs:
            rows = document.blocks.map { OCRReviewRow(id: $0.id, text: $0.paragraphText, bounds: $0.normalizedBounds) }
        case .originalLines:
            rows = document.originalLines.map { OCRReviewRow(id: $0.id, text: $0.text, bounds: $0.normalizedBounds) }
        case .markdownPreview, .markdownSource:
            return []
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? rows : rows.filter { $0.text.localizedStandardContains(term) }
    }
}

struct OCRReviewRow: Identifiable {
    let id: UUID
    let text: String
    let bounds: CGRect
}

private struct OCRResultView: View {
    let document: OCRDocument
    let image: CGImage
    let theme: Theme
    let makeMarkdownSource: (() async -> String)?
    let onCopy: (String) -> Void
    let onClose: () -> Void
    @State private var mode: OCRResultDisplayMode = .paragraphs
    @State private var markdownSource: String?
    @State private var isLoadingMarkdown = false
    @State private var query = ""
    @State private var location: OCRSourceLocation?
    @State private var imageZoom: CGFloat = 1

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                HStack(spacing: 10) {
                    imagePane
                        .frame(width: (proxy.size.width - 10) * 0.44)
                    resultPane
                }
            }
            .padding(10)
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

    private var imagePane: some View {
        card {
            HStack(spacing: 5) {
                Text("原图").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                iconButton("缩小原图", icon: "minus") { imageZoom = max(0.5, imageZoom / 1.5) }
                    .disabled(imageZoom <= 0.5)
                modeButton("适合宽度", selected: imageZoom == 1) { imageZoom = 1 }
                iconButton("放大原图", icon: "plus") { imageZoom = min(4, imageZoom * 1.5) }
                    .disabled(imageZoom >= 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 43)
            Divider()
            OCRSourcePreview(image: image, zoom: imageZoom, location: location)
        }
    }

    private var resultPane: some View {
        card {
            modeBar
            if !mode.isMarkdown {
                TextField("搜索识别结果", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索识别结果")
                    .padding([.horizontal, .bottom], 10)
            }
            Divider()
            Group {
                if mode.isMarkdown && markdownSource == nil {
                    ProgressView("正在整理 Markdown…")
                        .controlSize(.small)
                } else {
                    reader
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: query) { _, _ in location = nil }
        .onChange(of: mode) { _, _ in location = nil }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.token(.card))
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.token(.border), lineWidth: 1)
                    .allowsHitTesting(false)
            }
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
            let rows = mode.reviewRows(in: document, matching: query)
            if rows.isEmpty && !document.isEmpty {
                Text("没有匹配的文字")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.token(.mutedForeground))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            textRow(row, separated: row.id != rows.first?.id)
                        }
                    }
                }
                .id(mode)
                .scrollBounceBehavior(.basedOnSize)
            }
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

    private func textRow(_ row: OCRReviewRow, separated: Bool) -> some View {
        let unit = mode == .paragraphs ? "段" : "行"
        return HStack(alignment: .top, spacing: 6) {
            Text(row.text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            iconButton("在原图定位此\(unit)", icon: "scope") {
                location = OCRSourceLocation(rowID: row.id, bounds: row.bounds)
            }
            iconButton("复制此\(unit)", icon: "document.on.document") { onCopy(row.text) }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(location?.rowID == row.id ? theme.token(.primary).opacity(0.08) : .clear)
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

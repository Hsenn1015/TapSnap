import AppKit
import AVKit
import SwiftUI
import TapSnapActionsBar
import TapSnapMedia
import TapSnapSystem
import TapSnapTheme
import UniformTypeIdentifiers

struct RecordingPreviewEdits {
    var trimRange: RecordingTimeRange?
    var annotations: [RecordingAnnotation] = []
    var toolStyles: [RecordingAnnotation.Kind: RecordingAnnotation.Style] = [:]
}

/// 播放、标注和导出共用录制文件的时间轴。
@MainActor
final class RecordingPreviewPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSPopoverDelegate {
    private let videoURL: URL
    private let asset: AVURLAsset
    private let theme: Theme
    private let pasteboard: NSPasteboard
    private let window = RecordingPreviewWindow(
        contentRect: CGRect(x: 0, y: 0, width: 800, height: 620),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    private let player: AVPlayer
    private let timeline = RecordingTrimTimeline()
    private let annotationTimeline = RecordingAnnotationTimeline()
    private let annotationCanvas = RecordingAnnotationCanvas()
    private let annotationInspector = NSStackView()
    private let annotationTitle = NSTextField(labelWithString: "")
    private let annotationStart = NSTextField()
    private let annotationEnd = NSTextField()
    private let annotationUndo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    private let toolsState = RecordingAnnotationToolbarState()
    private var stepButtons: [NSButton] = []
    private lazy var singleFrameButton = footerButton("仅此帧", action: #selector(useSingleFrame))
    private lazy var editTextButton = editingIcon("pencil", title: "修改文字", action: #selector(editAnnotationText))
    private lazy var styleButton = footerButton("样式", action: #selector(showAnnotationStyle(_:)),
                                                symbol: "slider.horizontal.3")
    private struct StyleEdit {
        let annotationID: UUID?
        let kind: RecordingAnnotation.Kind
        let original: RecordingAnnotation.Style
        let draft: RecordingAnnotationStyleDraft
    }
    private(set) var stylePopover: NSPopover?
    private var styleEdit: StyleEdit?
    private var selectedAnnotationID: UUID?
    private var activeTool: RecordingAnnotation.Kind?
    private var frameTiming: RecordingFrameTiming?
    private var displayedFrame: RecordingTimeRange?
    private(set) var edits: RecordingPreviewEdits
    private let timeLabel = NSTextField(labelWithString: "00:00.00")
    private let formatLabel = NSTextField(labelWithString: "MP4")
    private let rangeLabel = NSTextField(labelWithString: "全段")
    private let status = NSTextField(wrappingLabelWithString: "正在读取视频…")
    private let progress = NSProgressIndicator()
    private lazy var playButton = editingIcon("play.fill", title: "播放或暂停（空格）", action: #selector(togglePlayback))
    private let startField = NSTextField()
    private let endField = NSTextField()
    private let gifMenu = NSMenu()
    private lazy var cancelButton = footerButton("取消导出", action: #selector(cancelExport))
    private var outputControls: [NSControl] = []
    private var resetButton: NSButton!
    private struct SeekRequest: Equatable {
        let time: TimeInterval
        let interactive: Bool
    }
    private var playerStatus: NSKeyValueObservation?
    private var playerItemStatus: NSKeyValueObservation?
    private var timeObserver: Any?
    private var seekInProgress: SeekRequest?
    private var queuedSeek: SeekRequest?
    private var trackingScrub = false
    private var playAfterSeek = false
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportID: UUID?
    private var isSaving = false
    private var gifURL: URL?
    private var trimmedURL: URL?
    private var gifFPS = 15
    private var gifSize = 1280
    private var duration: TimeInterval = 0
    private var closed = false
    var onClose: (() -> Void)?

    init(videoURL: URL, theme: Theme, pasteboard: NSPasteboard = .general, edits: RecordingPreviewEdits = .init()) {
        self.videoURL = videoURL
        self.theme = theme
        self.pasteboard = pasteboard
        self.edits = edits
        let asset = AVURLAsset(url: videoURL)
        self.asset = asset
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        super.init()

        window.title = "录屏预览"
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        ScreenCaptureProtection.apply(to: window)
        window.delegate = self
        window.contentMinSize = NSSize(width: 550, height: 490)
        window.onCopyVideo = { [weak self] in self?.prepareVideo(save: false) }
        window.onTogglePlayback = { [weak self] in self?.togglePlayback() }
        window.onStepFrame = { [weak self] in self?.stepFrame(by: $0) }
        window.onUndoEdit = { [weak self] redo in
            if redo { self?.redoAnnotation() }
            else { self?.undoAnnotation() }
        }
        window.onCancelTool = { [weak self] in
            guard let self else { return false }
            if stylePopover != nil {
                dismissStyleEditor()
                return true
            }
            guard activeTool != nil else { return false }
            selectTool(nil)
            return true
        }

        window.contentView = makeContent()
        connectAnnotationInput()
        timeline.onScrub = { [weak self] target, time, interactive in
            guard let self, window.makeFirstResponder(nil) else { return }
            scrub(target, to: time, interactive: interactive)
        }
        player.actionAtItemEnd = .pause
        updatePlaybackButton()
        playerStatus = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updatePlaybackButton() }
        }
        playerItemStatus = player.currentItem?.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.performQueuedSeek() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.syncPlaybackTime() }
        }
        setExporting(false)

        loadTask = Task { @MainActor [weak self] in
            do {
                let length = try await asset.load(.duration).seconds
                guard let track = try await asset.loadTracks(withMediaType: .video).first,
                      let range = try? RecordingTimeRange(start: 0, end: length)
                else { throw VideoTrimError.unavailable }
                let timing = try? await RecordingFrameTiming(asset: asset)
                try Task.checkCancellation()
                guard let self, !closed else { return }
                frameTiming = timing
                duration = length
                timeline.duration = length
                annotationTimeline.duration = length
                let trim = edits.trimRange.flatMap { $0.end <= length ? $0 : nil } ?? range
                setRange(trim)
                seek(to: trim.start)
                refreshAnnotations()
                setExporting(false)
                if let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                    let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
                    if !closed, bounds.width.isFinite, bounds.height.isFinite {
                        annotationCanvas.videoSize = bounds.size
                        formatLabel.stringValue = "MP4  ·  \(Int(bounds.width.rounded())) × \(Int(bounds.height.rounded()))"
                    }
                }
                await loadThumbnails(asset)
            } catch {
                guard let self, !closed else { return }
                status.stringValue = "无法读取视频：\(error.localizedDescription)"
            }
        }
    }

    private func makeContent() -> NSView {
        let content = NSView()
        let playback = AVPlayerView()
        playback.player = player
        playback.controlsStyle = .none
        playback.videoGravity = .resizeAspect
        playback.wantsLayer = true
        playback.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        playback.layer?.cornerRadius = 10
        playback.layer?.masksToBounds = true
        let canvas = NSView()
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 144).isActive = true
        for layer in [playback as NSView, annotationCanvas] {
            layer.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(layer)
            NSLayoutConstraint.activate([
                layer.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
                layer.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
                layer.topAnchor.constraint(equalTo: canvas.topAnchor),
                layer.bottomAnchor.constraint(equalTo: canvas.bottomAnchor)
            ])
        }

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        formatLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        formatLabel.textColor = .secondaryLabelColor
        let previousFrame = editingIcon("backward.frame", title: "上一帧", action: #selector(stepFrame(_:)))
        previousFrame.tag = -1
        previousFrame.toolTip = "上一帧 ←"
        let nextFrame = editingIcon("forward.frame", title: "下一帧", action: #selector(stepFrame(_:)))
        nextFrame.tag = 1
        nextFrame.toolTip = "下一帧 →"
        stepButtons = [previousFrame, nextFrame]
        let transport = row([playButton, previousFrame, nextFrame, timeLabel, NSView(), formatLabel])
        timeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        formatLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let trimTitle = NSTextField(labelWithString: "裁剪")
        trimTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        trimTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        resetButton = footerButton("恢复全段", action: #selector(resetRange), tone: .ghost)
        let trimHeader = row([trimTitle, rangeLabel, NSView(), resetButton])
        timeline.setAccessibilityRole(.image)
        timeline.setAccessibilityLabel("录屏时间轴。也可以用下方的开始和结束秒数裁剪。")
        timeline.toolTip = "拖动两端裁剪，点击时间轴预览"
        timeline.accentColor = NSColor(theme.highlight)
        annotationTimeline.accentColor = timeline.accentColor
        timeline.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let fields = row([timeField("开始", field: startField), NSView(), timeField("结束", field: endField)])
        let trim = column([trimHeader, timeline, fields], spacing: 4)

        configureGIFMenu()
        let copyGIF = footerButton("复制 GIF", action: #selector(copyGIFToClipboard))
        copyGIF.toolTip = "将当前片段复制为 GIF"
        let gifOptions = footerButton("", action: #selector(showGIFOptions(_:)), symbol: "chevron.down")
        gifOptions.imagePosition = .imageOnly
        gifOptions.setAccessibilityRole(.menuButton)
        gifOptions.setAccessibilityLabel("GIF 导出选项")
        gifOptions.toolTip = "保存 GIF、调整帧率和尺寸"
        gifOptions.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let gifActions = row([copyGIF, gifOptions])
        gifActions.spacing = 3
        let saveVideo = footerButton("保存视频…", action: #selector(saveVideoFile), symbol: "arrow.down.to.line")
        let copyVideo = footerButton("复制视频", action: #selector(copyVideoFile), symbol: "doc.on.doc", tone: .primary)
        copyVideo.setAccessibilityLabel("复制视频")
        copyVideo.toolTip = "将当前片段作为 MP4 文件复制（⌘C）"
        let copyForeground = NSColor(theme.token(.primaryForeground))
        let copyTitle = NSMutableAttributedString(string: copyVideo.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: copyForeground,
        ])
        copyTitle.append(NSAttributedString(string: "  ⌘C", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: copyForeground.withAlphaComponent(0.72),
        ]))
        copyVideo.attributedTitle = copyTitle
        let actionDivider = NSBox()
        actionDivider.boxType = .separator
        actionDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        actionDivider.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let actions = row([gifActions, saveVideo, actionDivider, copyVideo])
        outputControls = [startField, endField, copyGIF, gifOptions, saveVideo, copyVideo]

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        let feedback = NSStackView(views: [status, progress])
        feedback.orientation = .vertical
        feedback.alignment = .leading
        feedback.spacing = 3
        progress.widthAnchor.constraint(equalToConstant: 72).isActive = true
        feedback.setContentHuggingPriority(.defaultLow, for: .horizontal)
        feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = row([feedback, NSView(), cancelButton, actions])
        footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        let separator = NSBox()
        separator.boxType = .separator

        let annotationControls = makeAnnotationControls()
        annotationTimeline.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let layout = column([canvas, transport, annotationControls.toolbar, trim, annotationTimeline,
                             annotationControls.inspectorSlot, separator, footer], spacing: 8)
        layout.setCustomSpacing(6, after: canvas)
        layout.setCustomSpacing(5, after: annotationTimeline)
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        return content
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = spacing
        for view in views {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return column
    }

    private func timeField(_ title: String, field: NSTextField, scope: String = "裁剪") -> NSStackView {
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.drawsBackground = true
        field.delegate = self
        field.setAccessibilityLabel("\(scope)\(title)秒数")
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = scope == "裁剪" ? 2 : 3
        field.formatter = formatter
        field.doubleValue = 0
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let label = NSTextField(labelWithString: title)
        let unit = NSTextField(labelWithString: "秒")
        for label in [label, unit] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let stack = row([label, field, unit])
        stack.spacing = 5
        return stack
    }

    private func footerButton(_ title: String, action: Selector, symbol: String? = nil,
                              tone: RecordingFooterButton.Tone = .secondary) -> NSButton {
        let button = RecordingFooterButton(title: title, target: self, action: action)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.heightAnchor.constraint(equalToConstant: ActionsBarLayout.buttonSize).isActive = true
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        button.prepareFeedback(theme: theme, tone: tone)
        return button
    }

    private func editingIcon(_ symbol: String, title: String, action: Selector) -> NSButton {
        let button = footerButton("", action: action, symbol: symbol, tone: .ghost)
        button.imagePosition = .imageOnly
        button.widthAnchor.constraint(equalToConstant: ActionsBarLayout.buttonSize).isActive = true
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    private func makeAnnotationControls() -> (toolbar: NSView, inspectorSlot: NSView) {
        let toolbar = NSHostingView(rootView: RecordingAnnotationToolbar(
            state: toolsState, theme: theme, select: { [weak self] in self?.toggleAnnotationTool($0) },
            undo: { [weak self] in self?.undoAnnotation() }, redo: { [weak self] in self?.redoAnnotation() }
        ))
        toolbar.sizingOptions = []
        toolbar.heightAnchor.constraint(equalToConstant: theme.metrics.toolbarHeight).isActive = true
        styleButton.toolTip = "调整所选标注或当前工具的样式"
        styleButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        annotationTitle.font = .systemFont(ofSize: 12, weight: .medium)
        annotationTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        annotationInspector.orientation = .horizontal
        annotationInspector.alignment = .centerY
        annotationInspector.spacing = 8
        annotationInspector.setAccessibilityLabel("所选标注")
        singleFrameButton.toolTip = "所选标注只在播放头所在的那一帧显示"
        let deleteButton = editingIcon("trash", title: "删除标注", action: #selector(deleteAnnotation))
        for view in [
            annotationTitle, NSView(),
            timeField("开始", field: annotationStart, scope: "标注"),
            timeField("结束", field: annotationEnd, scope: "标注"),
            singleFrameButton, editTextButton, deleteButton
        ] {
            annotationInspector.addArrangedSubview(view)
        }
        annotationInspector.isHidden = true
        // 选择和编辑标注时保持画布高度，鼠标下的画面不会跟着跳。
        let inspectorSlot = NSView()
        inspectorSlot.heightAnchor.constraint(equalToConstant: 30).isActive = true
        annotationInspector.translatesAutoresizingMaskIntoConstraints = false
        inspectorSlot.addSubview(annotationInspector)
        NSLayoutConstraint.activate([
            annotationInspector.leadingAnchor.constraint(equalTo: inspectorSlot.leadingAnchor),
            annotationInspector.trailingAnchor.constraint(equalTo: inspectorSlot.trailingAnchor),
            annotationInspector.centerYAnchor.constraint(equalTo: inspectorSlot.centerYAnchor)
        ])
        return (row([toolbar, styleButton]), inspectorSlot)
    }

    private func connectAnnotationInput() {
        annotationCanvas.onCreate = { [weak self] kind, start, end in self?.addAnnotation(kind, start: start, end: end) }
        annotationCanvas.onCreatePath = { [weak self] kind, points in
            guard let start = points.first, let end = points.last else { return }
            self?.addAnnotation(kind, start: start, end: end, points: points)
        }
        annotationCanvas.onChangeGeometry = { [weak self] id, start, end, points in
            guard let self else { return }
            dismissStyleEditor()
            changeAnnotation(id) {
                $0.startPoint = start
                $0.endPoint = end
                $0.points = points
            }
        }
        annotationCanvas.onSelect = { [weak self] id in self?.selectAnnotation(id, seek: false) }
        annotationCanvas.onEditText = { [weak self] id in
            self?.selectAnnotation(id, seek: false)
            self?.editAnnotationText()
        }
        annotationTimeline.onSelect = { [weak self] id in self?.selectAnnotation(id, seek: true) }
        annotationTimeline.onSeek = { [weak self] time, interactive in
            self?.scrub(.playhead, to: time, interactive: interactive)
        }
        annotationTimeline.onPreviewRange = { [weak self] id, range in
            guard let self, selectedAnnotationID == id else { return }
            annotationStart.doubleValue = range.start
            annotationEnd.doubleValue = range.end
        }
        annotationTimeline.onChangeRange = { [weak self] id, range in self?.setAnnotationRange(range, for: id) }
    }

    private var annotationEditingAvailable: Bool {
        duration > 0 && !closed && exportTask == nil && !isSaving
    }

    private var canEditAnnotations: Bool { annotationEditingAvailable && window.attachedSheet == nil }

    private var selectedAnnotation: RecordingAnnotation? {
        edits.annotations.first { $0.id == selectedAnnotationID }
    }

    func toggleAnnotationTool(_ kind: RecordingAnnotation.Kind) {
        guard canEditAnnotations, window.makeFirstResponder(nil) else { return }
        dismissStyleEditor()
        selectTool(kind == activeTool ? nil : kind)
    }

    private func selectTool(_ kind: RecordingAnnotation.Kind?) {
        activeTool = kind
        annotationCanvas.tool = kind
        toolsState.selectedTool = kind
        updateToolStyle()
        guard let kind else {
            updateAnnotationAvailability(enabled: annotationEditingAvailable)
            return
        }
        pausePlayback()
        selectedAnnotationID = nil
        refreshAnnotations()
        status.stringValue = kind == .text ? "在画面上点击文字位置" : "在画面上拖动绘制\(kind.title)"
    }

    private func selectAnnotation(_ id: UUID, seek: Bool) {
        guard canEditAnnotations,
              window.makeFirstResponder(nil), let annotation = edits.annotations.first(where: { $0.id == id }) else { return }
        if !seek { pausePlayback() }
        if selectedAnnotationID != id {
            dismissStyleEditor()
            if seek { selectTool(nil) }
            selectedAnnotationID = id
            refreshAnnotations()
        }
        if seek { revealAnnotation(in: annotation.range, near: annotation.range.start) }
    }

    private func addAnnotation(_ kind: RecordingAnnotation.Kind, start: CGPoint, end: CGPoint, points: [CGPoint] = []) {
        guard canEditAnnotations, let trim = timeline.range else { return }
        dismissStyleEditor()
        let style = toolStyle(for: kind)
        if kind == .mask, let range = try? RecordingTimeRange(start: 0, end: duration) {
            insertAnnotation(.init(kind: kind, startPoint: start, endPoint: end, range: range, style: style))
            return
        }
        let anchor = min(max(timeline.playhead, trim.start), trim.end - min(0.0001, trim.duration / 2))
        let frame = try? frameTiming?.range(at: anchor)
        let rangeEnd = min(trim.end, max(frame?.end ?? anchor, anchor + 2))
        guard let range = try? RecordingTimeRange(start: frame?.start ?? anchor, end: rangeEnd) else { return }
        if kind == .text {
            requestAnnotationText { [weak self] text in
                self?.insertAnnotation(.init(kind: kind, startPoint: start, endPoint: end,
                                             text: text, range: range, style: style))
            }
        } else {
            insertAnnotation(.init(kind: kind, startPoint: start, endPoint: end, range: range, style: style, points: points))
        }
    }

    private func insertAnnotation(_ annotation: RecordingAnnotation) {
        applyAnnotations(edits.annotations + [annotation], selectedID: annotation.id)
    }

    private func toolStyle(for kind: RecordingAnnotation.Kind) -> RecordingAnnotation.Style {
        edits.toolStyles[kind] ?? .defaults(for: kind)
    }

    private func updateToolStyle() {
        annotationCanvas.style = activeTool.map { kind in
            if let edit = styleEdit, edit.kind == kind { return edit.draft.style }
            return toolStyle(for: kind)
        }
    }

    @objc private func showAnnotationStyle(_ sender: NSButton) {
        guard canEditAnnotations, window.makeFirstResponder(nil) else { return }
        if stylePopover != nil {
            dismissStyleEditor()
            return
        }
        let annotation = selectedAnnotation
        guard let kind = annotation?.kind ?? activeTool else { return }
        pausePlayback()
        let original = annotation?.style ?? toolStyle(for: kind)
        let draft = RecordingAnnotationStyleDraft(original)
        styleEdit = StyleEdit(annotationID: annotation?.id, kind: kind, original: original, draft: draft)
        let host = NSHostingController(rootView: RecordingAnnotationStylePanel(draft: draft, kind: kind, theme: theme) {
            [weak self] in
            self?.updateToolStyle()
            self?.refreshAnnotationSelectionOutline()
        })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = host
        popover.contentSize = host.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        stylePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func popoverWillClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === stylePopover else { return }
        commitStyleEdit()
    }

    private func dismissStyleEditor() {
        stylePopover?.close()
        if styleEdit != nil { commitStyleEdit() }
    }

    private func commitStyleEdit() {
        stylePopover = nil
        guard let edit = styleEdit else { return }
        styleEdit = nil
        let style = edit.draft.style
        if style != edit.original {
            edits.toolStyles[edit.kind] = style
            if let id = edit.annotationID {
                changeAnnotation(id) { $0.style = style }
            }
        }
        updateToolStyle()
        refreshAnnotationSelectionOutline()
    }

    private func requestAnnotationText(_ initial: String = "", completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = initial.isEmpty ? "添加文字标注" : "修改文字标注"
        alert.addButton(withTitle: "完成")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        field.placeholderString = "输入要显示在画面上的文字"
        field.setAccessibilityLabel("标注文字")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, !closed, response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { completion(text) }
        }
    }

    @objc private func editAnnotationText() {
        guard canEditAnnotations, let annotation = selectedAnnotation, annotation.kind == .text else { return }
        requestAnnotationText(annotation.text) { [weak self] text in
            self?.changeAnnotation(annotation.id) { $0.text = text }
        }
    }

    @objc private func deleteAnnotation() {
        guard canEditAnnotations, let id = selectedAnnotationID else { return }
        applyAnnotations(edits.annotations.filter { $0.id != id }, selectedID: nil)
    }

    private func changeAnnotation(_ id: UUID, _ change: (inout RecordingAnnotation) -> Void) {
        guard let index = edits.annotations.firstIndex(where: { $0.id == id }) else { return }
        var annotations = edits.annotations
        change(&annotations[index])
        applyAnnotations(annotations, selectedID: id)
    }

    private func setAnnotationRange(_ range: RecordingTimeRange, for id: UUID) {
        guard canEditAnnotations, let annotation = edits.annotations.first(where: { $0.id == id }),
              annotation.range != range else { return }
        changeAnnotation(id) { $0.range = range }
        let position = displayedFrame?.start ?? timeline.playhead
        if position < range.start || position >= range.end {
            revealAnnotation(in: range, near: timeline.playhead)
        }
    }

    private func revealAnnotation(in range: RecordingTimeRange, near time: TimeInterval) {
        guard let trim = timeline.range else { return }
        let start = max(trim.start, range.start)
        let end = min(trim.end, range.end)
        guard start < end else { return }
        let desired = min(max(start, time), end - min(0.0001, (end - start) / 2))
        if let frame = try? frameTiming?.range(at: desired), frame.start < range.start, frame.end < end {
            // 求取首个实际含有该标注的源帧，避免跳到标注刚开始但上一帧还在停留的位置。
            scrub(.playhead, to: frame.end)
        } else {
            scrub(.playhead, to: desired)
        }
    }

    private func applyAnnotations(_ annotations: [RecordingAnnotation], selectedID: UUID?) {
        guard annotations != edits.annotations else { return }
        let before = edits.annotations
        let oldSelection = selectedAnnotationID
        let startsGroup = !annotationUndo.isUndoing && !annotationUndo.isRedoing
        if startsGroup { annotationUndo.beginUndoGrouping() }
        annotationUndo.registerUndo(withTarget: self) {
            $0.applyAnnotations(before, selectedID: oldSelection)
        }
        if startsGroup { annotationUndo.endUndoGrouping() }
        edits.annotations = annotations
        selectedAnnotationID = selectedID
        gifURL = nil
        trimmedURL = nil
        refreshAnnotations()
        updateEditsStatus()
    }

    func undoAnnotation() {
        guard canEditAnnotations else { return }
        dismissStyleEditor()
        guard annotationUndo.canUndo else { return }
        selectTool(nil)
        annotationUndo.undo()
        updateAnnotationAvailability(enabled: true)
    }

    func redoAnnotation() {
        guard canEditAnnotations else { return }
        dismissStyleEditor()
        guard annotationUndo.canRedo else { return }
        selectTool(nil)
        annotationUndo.redo()
        updateAnnotationAvailability(enabled: true)
    }

    private func refreshAnnotations() {
        annotationTimeline.annotations = edits.annotations
        annotationTimeline.selectedID = selectedAnnotationID
        let current = selectedAnnotation
        annotationInspector.isHidden = current == nil
        if let current {
            annotationTitle.stringValue = current.kind.title
            annotationStart.doubleValue = current.range.start
            annotationEnd.doubleValue = current.range.end
            editTextButton.isHidden = current.kind != .text
        }
        refreshAnnotationSelectionOutline()
        // 文字弹窗的结束回调可能先于窗口脱离，弹窗期间的事件由 AppKit 拦截。
        updateAnnotationAvailability(enabled: annotationEditingAvailable)
    }

    private func refreshAnnotationSelectionOutline() {
        guard !edits.annotations.isEmpty else {
            annotationCanvas.visibleAnnotations = []
            annotationCanvas.selectedAnnotation = nil
            return
        }
        let time = min(timeline.playhead, duration - min(0.001, duration / 2))
        if displayedFrame.map({ $0.start <= time && time < $0.end }) != true {
            displayedFrame = try? frameTiming?.range(at: time)
        }
        let frameTime = displayedFrame?.start ?? time
        var visible = edits.annotations.filter { $0.range.start <= frameTime && frameTime < $0.range.end }
        if let edit = styleEdit, let index = visible.firstIndex(where: { $0.id == edit.annotationID }) {
            visible[index].style = edit.draft.style
        }
        annotationCanvas.visibleAnnotations = visible
        annotationCanvas.selectedAnnotation = player.timeControlStatus == .paused
            ? visible.first { $0.id == selectedAnnotationID } : nil
    }

    private func updateAnnotationAvailability(enabled: Bool) {
        for button in stepButtons { button.isEnabled = enabled && frameTiming != nil }
        for control in annotationInspector.arrangedSubviews.compactMap({ $0 as? NSControl }) {
            control.isEnabled = enabled
        }
        annotationStart.isEnabled = enabled
        annotationEnd.isEnabled = enabled
        singleFrameButton.isEnabled = enabled && frameTiming != nil
        annotationTimeline.isEnabled = enabled
        annotationCanvas.isInteractionEnabled = enabled
        toolsState.isEnabled = enabled
        toolsState.canUndo = annotationUndo.canUndo
        toolsState.canRedo = annotationUndo.canRedo
        styleButton.isEnabled = enabled && (selectedAnnotationID != nil || activeTool != nil)
    }

    private func updateEditsStatus() {
        guard let trim = timeline.range else { return }
        let count = edits.annotations.count
        if count > 0 {
            status.stringValue = "\(count) 处标注"
        } else if trim.start == 0, trim.end == duration {
            status.stringValue = "可粘贴为 MP4 文件"
        } else {
            status.stringValue = "复制和导出将使用所选片段"
        }
    }

    @objc private func stepFrame(_ sender: NSButton) {
        stepFrame(by: sender.tag)
    }

    private func stepFrame(by delta: Int) {
        guard canEditAnnotations, window.makeFirstResponder(nil), let trim = timeline.range, let frameTiming else { return }
        pausePlayback()
        let time = min(timeline.playhead, trim.end - min(0.0001, trim.duration / 2))
        do {
            let frame = try frameTiming.range(at: time)
            if delta > 0 {
                if frame.end < trim.end { seek(to: frame.end) }
            } else if timeline.playhead >= trim.end {
                seek(to: max(trim.start, frame.start))
            } else if frame.start > trim.start {
                let previous = try frameTiming.range(at: max(trim.start, frame.start - 0.0001))
                seek(to: max(trim.start, previous.start))
            }
        } catch {
            status.stringValue = "无法定位当前帧：\(error.localizedDescription)"
        }
    }

    @objc private func useSingleFrame() {
        guard canEditAnnotations, window.makeFirstResponder(nil), let annotation = selectedAnnotation,
              let frameTiming else { return }
        pausePlayback()
        do {
            let range = try frameTiming.range(at: timeline.playhead)
            setAnnotationRange(range, for: annotation.id)
        } catch {
            status.stringValue = "无法定位当前帧：\(error.localizedDescription)"
        }
    }

    private func configureGIFMenu() {
        gifMenu.addItem(withTitle: "保存 GIF…", action: #selector(saveGIFFile), keyEquivalent: "").target = self
        gifMenu.addItem(.separator())
        let fpsMenu = NSMenu()
        for fps in [10, 15, 24, 30] {
            let item = fpsMenu.addItem(withTitle: "\(fps) FPS", action: #selector(changeGIFFPS(_:)), keyEquivalent: "")
            item.target = self
            item.tag = fps
            item.state = fps == gifFPS ? .on : .off
        }
        gifMenu.addItem(withTitle: "帧率", action: nil, keyEquivalent: "").submenu = fpsMenu
        let sizeMenu = NSMenu()
        for size in [640, 960, 1280, 1920, 0] {
            let item = sizeMenu.addItem(withTitle: size == 0 ? "原始尺寸" : "最长边 \(size) 像素",
                                        action: #selector(changeGIFSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = size
            item.state = size == gifSize ? .on : .off
        }
        gifMenu.addItem(withTitle: "尺寸", action: nil, keyEquivalent: "").submenu = sizeMenu
    }

    @objc private func showGIFOptions(_ sender: NSButton) {
        gifMenu.popUp(positioning: nil, at: CGPoint(x: sender.bounds.minX, y: sender.bounds.minY - 3), in: sender)
    }

    private func loadThumbnails(_ asset: AVURLAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 224, height: 128)
        let count = timeline.thumbnails.count
        // 少量小图，允许就近取帧，避免长录屏打开时大量解码。
        let tolerance = CMTime(seconds: duration / Double(count * 4), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        await withTaskCancellationHandler {
            for index in 0..<count {
                guard !Task.isCancelled else { return }
                let time = duration * (Double(index) + 0.5) / Double(count)
                if let result = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000)),
                   !closed, !Task.isCancelled {
                    timeline.thumbnails[index] = result.image
                }
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    func show(on screen: NSScreen? = nil) {
        let opening = !window.isVisible
        if opening {
            let visible = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
            let size = CGSize(width: min(window.frame.width, visible.width - 24),
                              height: min(window.frame.height, visible.height - 24))
            window.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
        }
        window.makeKeyAndOrderFront(nil)
        if opening { window.makeFirstResponder(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard !closed else { return }
        dismissStyleEditor()
        closed = true
        loadTask?.cancel()
        loadTask = nil
        annotationUndo.removeAllActions()
        exportTask?.cancel()
        exportTask = nil
        exportID = nil
        playerStatus?.invalidate()
        playerStatus = nil
        playerItemStatus?.invalidate()
        playerItemStatus = nil
        queuedSeek = nil
        player.currentItem?.cancelPendingSeeks()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        window.delegate = nil
        window.orderOut(nil)
        onClose?()
        onClose = nil
        // 复制后的文件仍由接收应用按 URL 读取，关闭预览时保留。
    }

    func windowWillClose(_ notification: Notification) { close() }

    @objc private func togglePlayback() {
        guard !closed, window.attachedSheet == nil, let range = timeline.range else { return }
        dismissStyleEditor()
        if playAfterSeek || player.timeControlStatus != .paused {
            pausePlayback()
        } else {
            selectTool(nil)
            let time = timeline.playhead
            if !time.isFinite || time < range.start || time >= range.end - min(0.002, range.duration / 2) {
                seek(to: range.start)
            } else if trackingScrub {
                seek(to: time)
            }
            if seekInProgress != nil || queuedSeek != nil { playAfterSeek = true }
            else { player.play() }
        }
        updatePlaybackButton()
    }

    private func pausePlayback() {
        guard playAfterSeek || player.timeControlStatus != .paused else { return }
        playAfterSeek = false
        player.pause()
        updatePlaybackButton()
    }

    private func updatePlaybackButton() {
        guard !closed else { return }
        let playing = playAfterSeek || player.timeControlStatus != .paused
        let label = playing ? "暂停" : "播放"
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: label)
        playButton.setAccessibilityLabel(label)
        refreshAnnotationSelectionOutline()
    }

    private func updatePlaybackTime(_ time: TimeInterval) {
        guard !closed, time.isFinite else { return }
        timeline.playhead = time
        annotationTimeline.playhead = time
        timeLabel.stringValue = "\(timestamp(time))  /  \(timestamp(duration))"
        refreshAnnotationSelectionOutline()
    }

    private func syncPlaybackTime() {
        guard !trackingScrub, seekInProgress == nil, queuedSeek == nil else { return }
        // 周期回调可能是在旧的播放位置排入队列，执行时读取当前时间。
        updatePlaybackTime(player.currentTime().seconds)
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let centiseconds = Int((max(0, seconds) * 100).rounded())
        return String(format: "%02d:%02d.%02d", centiseconds / 6000, centiseconds / 100 % 60, centiseconds % 100)
    }

    private func seek(to time: TimeInterval, interactive: Bool = false) {
        guard !closed, duration > 0, time.isFinite else { return }
        let time = min(max(time, 0), duration)
        let request = SeekRequest(time: time, interactive: interactive)
        let released = trackingScrub && !interactive
        trackingScrub = interactive
        updatePlaybackTime(time)
        queuedSeek = request == seekInProgress ? nil : request
        if released, seekInProgress != nil, queuedSeek != nil {
            // 松手后可以立即切到精确定位，跳过正在解码的拖动预览。
            player.currentItem?.cancelPendingSeeks()
        }
        performQueuedSeek()
    }

    private func performQueuedSeek() {
        guard !closed, seekInProgress == nil, let request = queuedSeek,
              let item = player.currentItem else { return }
        if item.status == .failed {
            queuedSeek = nil
            playAfterSeek = false
            updatePlaybackButton()
            return
        }
        guard item.status == .readyToPlay else { return }
        queuedSeek = nil
        seekInProgress = request
        let displayTime = min(request.time, duration - min(0.001, duration / 2))
        let tolerance = request.interactive ? CMTime(value: 1, timescale: 24) : .zero
        player.seek(to: CMTime(seconds: displayTime, preferredTimescale: 60_000),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, !closed else { return }
                seekInProgress = nil
                if queuedSeek != nil {
                    performQueuedSeek()
                } else {
                    if !finished { syncPlaybackTime() }
                    if playAfterSeek {
                        playAfterSeek = false
                        player.play()
                        updatePlaybackButton()
                    }
                }
            }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === annotationStart || field === annotationEnd {
            applyAnnotationTimeField(field)
            return
        }
        guard field === startField || field === endField, let range = timeline.range else { return }
        let value = field === startField ? range.start : range.end
        // 单纯切走焦点不能把更精确的裁剪值舍入成输入框里显示的两位小数。
        if (field.formatter as? NumberFormatter)?.string(from: NSNumber(value: value)) == field.stringValue { return }
        scrub(field === startField ? .start : .end, to: field.doubleValue)
        if let range = timeline.range {
            startField.doubleValue = range.start
            endField.doubleValue = range.end
        }
    }

    private func applyAnnotationTimeField(_ field: NSTextField) {
        guard let annotation = selectedAnnotation else { return }
        let starting = field === annotationStart
        let previous = starting ? annotation.range.start : annotation.range.end
        if (field.formatter as? NumberFormatter)?.string(from: NSNumber(value: previous)) == field.stringValue { return }
        let value = field.doubleValue
        let minimum = min(annotation.range.duration, 0.001)
        let start = starting ? min(max(value, 0), annotation.range.end - minimum) : annotation.range.start
        let end = starting ? annotation.range.end : max(min(value, duration), annotation.range.start + minimum)
        if let range = try? RecordingTimeRange(start: start, end: end) {
            setAnnotationRange(range, for: annotation.id)
        }
        field.doubleValue = starting ? selectedAnnotation?.range.start ?? previous : selectedAnnotation?.range.end ?? previous
    }

    private func scrub(_ target: RecordingTrimTimeline.Target, to time: TimeInterval, interactive: Bool = false) {
        guard !closed, exportTask == nil, !isSaving, let range = timeline.range, time.isFinite else { return }
        let minimumSpan = min(duration, 1.0 / 60.0)
        var position = time
        switch target {
        case .start:
            position = min(max(0, time), max(0, range.end - minimumSpan))
            if let newRange = try? RecordingTimeRange(start: position, end: range.end) { setRange(newRange) }
        case .end:
            position = max(min(duration, time), min(duration, range.start + minimumSpan))
            if let newRange = try? RecordingTimeRange(start: range.start, end: position) { setRange(newRange) }
        case .playhead:
            position = min(max(range.start, time), range.end)
        }
        pausePlayback()
        seek(to: position, interactive: interactive)
    }

    @objc private func resetRange() {
        guard let range = try? RecordingTimeRange(start: 0, end: duration) else { return }
        setRange(range)
        pausePlayback()
        seek(to: 0)
    }

    private func setRange(_ range: RecordingTimeRange) {
        guard timeline.range != range else { return }
        timeline.range = range
        edits.trimRange = range
        annotationTimeline.trimRange = range
        window.invalidateCursorRects(for: timeline)
        startField.doubleValue = range.start
        endField.doubleValue = range.end
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 60_000)
        let isFull = range.start == 0 && range.end == duration
        rangeLabel.stringValue = isFull ? "全段" : "选中 \(timestamp(range.duration))"
        resetButton.isEnabled = !isFull
        gifURL = nil
        trimmedURL = nil
        updateEditsStatus()
    }

    @objc private func changeGIFFPS(_ sender: NSMenuItem) {
        gifFPS = sender.tag
        updateGIFOptions(sender)
    }

    @objc private func changeGIFSize(_ sender: NSMenuItem) {
        gifSize = sender.tag
        updateGIFOptions(sender)
    }

    private func updateGIFOptions(_ sender: NSMenuItem) {
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        gifURL = nil
    }

    @objc private func cancelExport() { exportTask?.cancel() }
    @objc private func copyVideoFile() { prepareVideo(save: false) }
    @objc private func saveVideoFile() { prepareVideo(save: true) }
    @objc private func copyGIFToClipboard() { prepareGIF(save: false) }
    @objc private func saveGIFFile() { prepareGIF(save: true) }

    private var canOutput: Bool {
        !closed && exportTask == nil && !isSaving && window.attachedSheet == nil
    }

    private func annotations(in range: RecordingTimeRange) -> [RecordingAnnotation] {
        edits.annotations.filter { $0.range.start < range.end && $0.range.end > range.start }
    }

    private func prepareVideo(save: Bool) {
        guard canOutput, window.makeFirstResponder(nil), let range = timeline.range else { return }
        dismissStyleEditor()
        let annotations = annotations(in: range)
        if annotations.isEmpty, range.start == 0, range.end == duration {
            useFile(videoURL, type: .mpeg4Movie, save: save)
            return
        }
        if let trimmedURL, FileManager.default.fileExists(atPath: trimmedURL.path) {
            useFile(trimmedURL, type: .mpeg4Movie, save: save)
            return
        }
        let destination = exportURL(extension: "mp4")
        let current = UUID()
        exportID = current
        setExporting(true, indeterminate: true)
        status.stringValue = "正在生成视频片段…"
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await VideoTrimmer.export(videoURL: videoURL, to: destination, range: range, annotations: annotations)
                try Task.checkCancellation()
                guard !closed, exportID == current else { return }
                trimmedURL = destination
                finishExport()
                useFile(destination, type: .mpeg4Movie, save: save)
            } catch { exportFailed(error, id: current, destination: destination) }
        }
    }

    private func prepareGIF(save: Bool) {
        guard canOutput, window.makeFirstResponder(nil), let range = timeline.range else { return }
        dismissStyleEditor()
        let annotations = annotations(in: range)
        if let gifURL, FileManager.default.fileExists(atPath: gifURL.path) {
            useFile(gifURL, type: .gif, save: save)
            return
        }
        let destination = exportURL(extension: "gif")
        let fps = gifFPS, size = gifSize
        let current = UUID()
        exportID = current
        setExporting(true)
        status.stringValue = "正在生成 GIF…"
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await GifExporter.export(videoURL: videoURL, to: destination,
                                             sampleInterval: 1 / Double(fps), maximumPixelDimension: size == 0 ? nil : size,
                                             timeRange: range, annotations: annotations, progress: { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.exportID == current, !self.closed else { return }
                        self.progress.doubleValue = value
                        self.status.stringValue = "正在生成 GIF… \(Int(value * 100))%"
                    }
                })
                try Task.checkCancellation()
                guard !closed, exportID == current else { return }
                gifURL = destination
                finishExport()
                useFile(destination, type: .gif, save: save)
            } catch { exportFailed(error, id: current, destination: destination) }
        }
    }

    private func exportURL(extension suffix: String) -> URL {
        videoURL.deletingLastPathComponent().appendingPathComponent("export-\(UUID().uuidString).\(suffix)")
    }

    private func finishExport() {
        exportTask = nil
        exportID = nil
        setExporting(false)
    }

    private func exportFailed(_ error: Error, id: UUID, destination: URL) {
        try? FileManager.default.removeItem(at: destination)
        guard !closed, exportID == id else { return }
        finishExport()
        status.stringValue = error is CancellationError ? "已取消导出" : "导出失败：\(error.localizedDescription)"
    }

    private func setExporting(_ exporting: Bool, indeterminate: Bool = false) {
        outputControls.forEach { $0.isEnabled = !exporting && duration > 0 }
        playButton.isEnabled = duration > 0
        resetButton.isEnabled = !exporting && (timeline.range.map { $0.start > 0 || $0.end < duration } ?? false)
        timeline.isEnabled = !exporting && duration > 0
        updateAnnotationAvailability(enabled: !exporting && duration > 0)
        cancelButton.isHidden = !exporting || isSaving
        progress.isHidden = !exporting
        progress.isIndeterminate = indeterminate
        progress.doubleValue = 0
        if exporting && indeterminate { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
    }

    private func useFile(_ url: URL, type: UTType, save: Bool) {
        if save {
            saveFile(url, type: type)
        } else {
            do {
                if type == .gif {
                    try RecordingClipboard.copyGIF(at: url, to: pasteboard)
                    status.stringValue = "GIF 已复制 · 不含声音"
                } else {
                    try RecordingClipboard.copyVideo(at: url, to: pasteboard)
                    status.stringValue = "视频已复制 · 可粘贴为 MP4 文件"
                }
            } catch { status.stringValue = "复制失败：\(error.localizedDescription)" }
        }
    }

    private func saveFile(_ source: URL, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "TapSnap-录屏.\(source.pathExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url, let self, !self.closed else { return }
            self.isSaving = true
            self.setExporting(true, indeterminate: true)
            self.status.stringValue = "正在保存…"
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let data = try Data(contentsOf: source, options: .mappedIfSafe)
                        try data.write(to: target, options: .atomic)
                    }.value
                    self.status.stringValue = "已保存：\(target.lastPathComponent)"
                } catch { self.status.stringValue = "保存失败：\(error.localizedDescription)" }
                self.isSaving = false
                if !self.closed { self.setExporting(false) }
            }
        }
    }
}

/// AppKit 按钮沿用 TapSnap 的主题和尺寸，保留原生键盘焦点。
private final class RecordingFooterButton: NSButton {
    enum Tone { case ghost, secondary, primary }

    private let highlightLayer = CALayer()
    private var isHovering = false
    private var isPressing = false

    func prepareFeedback(theme: Theme, tone: Tone) {
        isBordered = false
        let foreground = NSColor(theme.token(tone == .primary ? .primaryForeground : .foreground))
        contentTintColor = foreground
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: foreground
        ])
        let surface: NSColor
        switch tone {
        case .ghost: surface = .clear
        case .secondary: surface = NSColor(theme.token(.secondary))
        case .primary: surface = NSColor(theme.token(.primary))
        }
        wantsLayer = true
        layer?.cornerRadius = theme.metrics.radiusMD
        layer?.backgroundColor = surface.cgColor
        highlightLayer.cornerRadius = theme.metrics.radiusMD
        highlightLayer.backgroundColor = (tone == .primary
            ? foreground.withAlphaComponent(0.16) : NSColor(theme.token(.accent))).cgColor
        highlightLayer.opacity = 0
        layer?.addSublayer(highlightLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + (imagePosition == .imageOnly ? 0 : 16), height: ActionsBarLayout.buttonSize)
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.4
            updateFeedback()
        }
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        updateFeedback()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        updateFeedback()
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        updateFeedback()
        defer {
            isPressing = false
            updateFeedback()
        }
        super.mouseDown(with: event)
    }

    private func updateFeedback() {
        let opacity: Float = !isEnabled ? 0 : isPressing ? 1 : isHovering ? 0.56 : 0
        guard highlightLayer.opacity != opacity else { return }
        let previous = highlightLayer.presentation()?.opacity ?? highlightLayer.opacity
        highlightLayer.removeAnimation(forKey: "opacity")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.opacity = opacity
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = previous
        fade.toValue = opacity
        fade.duration = isPressing ? 0.06 : 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        highlightLayer.add(fade, forKey: "opacity")
    }
}

private final class RecordingPreviewWindow: NSPanel {
    var onCopyVideo: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onStepFrame: ((Int) -> Void)?
    var onUndoEdit: ((Bool) -> Void)?
    var onCancelTool: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if attachedSheet == nil, modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            if let editor = firstResponder as? NSTextView, editor.isFieldEditor {
                editor.copy(nil)
            } else if !event.isARepeat {
                onCopyVideo?()
            }
            return true
        }
        if attachedSheet == nil, (modifiers == .command || modifiers == [.command, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "z", !(firstResponder is NSTextView) {
            if !event.isARepeat { onUndoEdit?(modifiers.contains(.shift)) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if attachedSheet == nil, modifiers.isEmpty {
            if !(firstResponder is NSTextView), event.keyCode == 123 || event.keyCode == 124 {
                onStepFrame?(event.keyCode == 123 ? -1 : 1)
                return
            }
            switch event.charactersIgnoringModifiers {
            case " ":
                if !event.isARepeat { onTogglePlayback?() }
                return
            case "\u{1b}":
                if onCancelTool?() != true { performClose(nil) }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

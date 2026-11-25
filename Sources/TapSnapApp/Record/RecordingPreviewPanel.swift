import AppKit
import AVKit
import SwiftUI
import TapSnapActionsBar
import TapSnapCore
import TapSnapMedia
import TapSnapSystem
import TapSnapTheme
import UniformTypeIdentifiers

struct RecordingPreviewEdits {
    var trimRange: RecordingTimeRange?
    var annotations: [RecordingAnnotation] = []
    var toolStyles: [RecordingAnnotation.Kind: RecordingAnnotation.Style] = [:]
}

/// 液态玻璃浮岛录屏工作台：支持自适应画幅、裁剪、按时段标注、GIF 倍速导出与原生拖出发送。
@MainActor
final class RecordingPreviewPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSPopoverDelegate {
    enum ExportFormat: Int {
        case mp4 = 0
        case gif = 1
    }

    private let videoURL: URL
    private let asset: AVURLAsset
    private let theme: Theme
    private let pasteboard: NSPasteboard
    private let window = RecordingPreviewWindow(
        contentRect: CGRect(x: 0, y: 0, width: 820, height: 630),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    private let player: AVPlayer
    private let timeline = RecordingTrimTimeline()
    private let annotationTimeline = RecordingAnnotationTimeline()
    private let annotationCanvas = RecordingAnnotationCanvas()
    private let annotationInspector = NSStackView()
    private lazy var annotationInspectorIsland = LiquidGlassIslandView(isDark: theme.isDark, cornerRadius: nil)
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

    private lazy var singleFrameButton = pillButton("仅此帧", action: #selector(useSingleFrame), tone: .subtle, height: 24, pad: 8)
    private lazy var editTextButton = iconPillButton("pencil", title: "修改文字", action: #selector(editAnnotationText), size: 24)
    private lazy var styleButton = pillButton("样式", action: #selector(showAnnotationStyle(_:)),
                                              symbol: "slider.horizontal.3", tone: .ghost, height: 28, pad: 9)

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

    private let timeLabel = NSTextField(labelWithString: "00:00.00 / 00:00.00")
    private let formatLabel = NSTextField(labelWithString: "MP4")
    private let rangeLabel = NSTextField(labelWithString: "全段")
    private let status = NSTextField(labelWithString: "正在读取视频…")
    private let progress = NSProgressIndicator()
    private let statusBar = NSStackView()

    private lazy var playButton = iconPillButton("play.fill", title: "播放或暂停（空格）",
                                                 action: #selector(togglePlayback), tone: .accent, size: 28)
    private let gifMenu = NSMenu()
    private lazy var cancelButton = pillButton("取消导出", action: #selector(cancelExport), tone: .subtle, height: 24, pad: 9)
    private lazy var resetButton = pillButton("恢复全段", action: #selector(resetRange), tone: .accentSoft, height: 24, pad: 9)
    private lazy var formatPill = LiquidGlassSegmentPill(
        options: [.init(title: "MP4", symbol: "film"), .init(title: "GIF", symbol: "sparkles.rectangle.stack")],
        isDark: theme.isDark, height: 30
    )
    private lazy var gifSpecButton = pillButton("15fps · 1×", action: #selector(showGIFOptions(_:)),
                                                symbol: "gauge.with.dots.needle.67percent", tone: .accentSoft, height: 28, pad: 9)
    private lazy var dragOutChip = LiquidGlassDragOutChip(title: "拖出发送", isDark: theme.isDark)
    private lazy var saveButton = pillButton("保存 MP4", action: #selector(saveCurrentFormat),
                                             symbol: "arrow.down.to.line", tone: .subtle, height: 32, pad: 12)
    private lazy var primaryCopyButton = pillButton("复制视频", action: #selector(copyCurrentFormat),
                                                    symbol: "doc.on.doc", shortcut: "⌘C", tone: .accent, height: 32, pad: 15)

    private var outputControls: [NSControl] = []
    private(set) var exportFormat: ExportFormat = .mp4
    private var videoResolutionText: String?
    private var didAdaptInitialWindowSize = false

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
    private(set) var gifFPS = 15
    private(set) var gifSize = 1280
    private(set) var gifSpeed: Double = 1.0
    private var duration: TimeInterval = 0
    private var closed = false
    var onClose: (() -> Void)?

    private static let gifSpeedOptions: [(speed: Double, label: String)] = [
        (0.5, "0.5×（慢放）"),
        (0.75, "0.75×"),
        (1.0, "1×（原速）"),
        (1.25, "1.25×"),
        (1.5, "1.5×"),
        (2.0, "2×（快放）"),
    ]

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
        window.contentMinSize = NSSize(width: 580, height: 500)
        window.onCopyCurrent = { [weak self] in self?.copyCurrentFormat() }
        window.onSaveCurrent = { [weak self] in self?.saveCurrentFormat() }
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
        configureDragOutChip()
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
                    if !closed, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 {
                        annotationCanvas.videoSize = bounds.size
                        videoResolutionText = "\(Int(bounds.width.rounded())) × \(Int(bounds.height.rounded()))"
                        updateFormatBadge()
                        adaptWindowAspectRatioIfNeeded(for: bounds.size)
                    }
                }
                await loadThumbnails(asset)
            } catch {
                guard let self, !closed else { return }
                status.stringValue = "无法读取视频：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 液态玻璃浮岛布局

    private func makeContent() -> NSView {
        let backdrop = LiquidGlassBackdropView(isDark: theme.isDark)

        // 1. 顶部悬浮行：左侧格式规格徽章 + 右侧居中感标注浮岛
        let badgeIsland = LiquidGlassIslandView(isDark: theme.isDark, cornerRadius: nil)
        formatLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        formatLabel.textColor = theme.isDark ? NSColor(white: 0.84, alpha: 1) : NSColor(srgbRed: 0.24, green: 0.30, blue: 0.40, alpha: 1)
        formatLabel.setContentHuggingPriority(.required, for: .horizontal)
        formatLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeIsland.contentContainer.addSubview(formatLabel)
        NSLayoutConstraint.activate([
            badgeIsland.heightAnchor.constraint(equalToConstant: 30),
            formatLabel.leadingAnchor.constraint(equalTo: badgeIsland.contentContainer.leadingAnchor, constant: 12),
            formatLabel.trailingAnchor.constraint(equalTo: badgeIsland.contentContainer.trailingAnchor, constant: -12),
            formatLabel.centerYAnchor.constraint(equalTo: badgeIsland.contentContainer.centerYAnchor),
        ])

        let annotationIsland = makeAnnotationIsland()
        let topBar = NSStackView(views: [badgeIsland, NSView(), annotationIsland])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 10

        // 2. 柔和画布舞台（消除生硬黑底与巨型黑门柱）
        let playback = AVPlayerView()
        playback.player = player
        playback.controlsStyle = .none
        playback.videoGravity = .resizeAspect
        playback.wantsLayer = true
        playback.layer?.backgroundColor = NSColor.clear.cgColor
        playback.layer?.cornerRadius = 12
        playback.layer?.masksToBounds = true

        let canvas = NSView()
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 12
        canvas.layer?.masksToBounds = false
        canvas.layer?.backgroundColor = (theme.isDark
            ? NSColor(srgbRed: 0.08, green: 0.10, blue: 0.15, alpha: 0.65)
            : NSColor.white.withAlphaComponent(0.55)).cgColor
        canvas.layer?.borderWidth = 1
        canvas.layer?.borderColor = (theme.isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.07)).cgColor
        canvas.layer?.shadowColor = NSColor.black.cgColor
        canvas.layer?.shadowOpacity = theme.isDark ? 0.36 : 0.10
        canvas.layer?.shadowRadius = 18
        canvas.layer?.shadowOffset = CGSize(width: 0, height: -6)
        canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        for layerView in [playback as NSView, annotationCanvas] {
            layerView.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(layerView)
            NSLayoutConstraint.activate([
                layerView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
                layerView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
                layerView.topAnchor.constraint(equalTo: canvas.topAnchor),
                layerView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            ])
        }

        // 选中标注时悬浮在画布下沿的独立液态玻璃属性胶囊（绝不推动 canvas.frame！）
        setupAnnotationInspectorOverlay(on: backdrop, anchoredTo: canvas)

        // 3. 液态玻璃时间轴浮岛（播放头 + 胶片裁剪轨 + 按需透明标注轨 + 导出进度）
        let timelineIsland = makeTimelineIsland()

        // 4. 底部居中悬浮液态玻璃操作胶囊（格式切换 + GIF 规格/倍速 + 拖出发送 + 保存 + 复制主按钮）
        let dockRow = makeBottomDockRow()

        let layout = NSStackView(views: [topBar, canvas, timelineIsland, dockRow])
        layout.orientation = .vertical
        layout.alignment = .centerX
        layout.spacing = 10
        layout.setCustomSpacing(12, after: timelineIsland)
        for view in [topBar, canvas, timelineIsland, dockRow] {
            view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        layout.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 12),
            layout.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 14),
            layout.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -14),
            layout.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -14),
        ])

        // 确保悬浮标注检查胶囊始终在最顶层
        backdrop.addSubview(annotationInspectorIsland, positioned: .above, relativeTo: layout)
        NSLayoutConstraint.activate([
            annotationInspectorIsland.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            annotationInspectorIsland.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -10),
            annotationInspectorIsland.leadingAnchor.constraint(greaterThanOrEqualTo: backdrop.leadingAnchor, constant: 16),
            annotationInspectorIsland.trailingAnchor.constraint(lessThanOrEqualTo: backdrop.trailingAnchor, constant: -16),
        ])

        return backdrop
    }

    private func makeAnnotationIsland() -> NSView {
        let island = LiquidGlassIslandView(isDark: theme.isDark, cornerRadius: nil)
        let toolbar = NSHostingView(rootView: RecordingAnnotationToolbar(
            state: toolsState,
            theme: theme,
            select: { [weak self] in self?.toggleAnnotationTool($0) },
            undo: { [weak self] in self?.undoAnnotation() },
            redo: { [weak self] in self?.redoAnnotation() },
            selectQuickColor: { [weak self] in self?.applyQuickColor($0) }
        ))
        toolbar.sizingOptions = [.intrinsicContentSize]
        styleButton.toolTip = "调整所选标注或当前工具的详细样式"
        styleButton.setContentHuggingPriority(.required, for: .horizontal)

        let divider = hairlineDivider(height: 16)
        let stack = NSStackView(views: [toolbar, divider, styleButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        island.contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            island.heightAnchor.constraint(equalToConstant: 38),
            stack.leadingAnchor.constraint(equalTo: island.contentContainer.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: island.contentContainer.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: island.contentContainer.centerYAnchor),
        ])
        return island
    }

    private func setupAnnotationInspectorOverlay(on _: NSView, anchoredTo _: NSView) {
        annotationTitle.font = .systemFont(ofSize: 11.5, weight: .semibold)
        annotationTitle.setContentHuggingPriority(.required, for: .horizontal)
        annotationInspector.orientation = .horizontal
        annotationInspector.alignment = .centerY
        annotationInspector.spacing = 6
        annotationInspector.setAccessibilityLabel("所选标注")
        singleFrameButton.toolTip = "所选标注只在播放头所在的那一帧显示"
        let deleteButton = iconPillButton("trash", title: "删除标注", action: #selector(deleteAnnotation), size: 24)
        for view in [
            annotationTitle,
            hairlineDivider(height: 14),
            compactTimeField("起", field: annotationStart, scope: "标注开始"),
            compactTimeField("止", field: annotationEnd, scope: "标注结束"),
            singleFrameButton,
            editTextButton,
            deleteButton,
        ] {
            annotationInspector.addArrangedSubview(view)
        }
        annotationInspector.translatesAutoresizingMaskIntoConstraints = false
        annotationInspectorIsland.contentContainer.addSubview(annotationInspector)
        annotationInspectorIsland.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            annotationInspectorIsland.heightAnchor.constraint(equalToConstant: 36),
            annotationInspector.leadingAnchor.constraint(equalTo: annotationInspectorIsland.contentContainer.leadingAnchor, constant: 10),
            annotationInspector.trailingAnchor.constraint(equalTo: annotationInspectorIsland.contentContainer.trailingAnchor, constant: -8),
            annotationInspector.centerYAnchor.constraint(equalTo: annotationInspectorIsland.contentContainer.centerYAnchor),
        ])
        annotationInspectorIsland.isHidden = true
    }

    private func makeTimelineIsland() -> NSView {
        let island = LiquidGlassIslandView(isDark: theme.isDark, cornerRadius: 16)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        let previousFrame = iconPillButton("backward.frame", title: "上一帧", action: #selector(stepFrame(_:)), size: 26)
        previousFrame.tag = -1
        previousFrame.toolTip = "上一帧 ←"
        let nextFrame = iconPillButton("forward.frame", title: "下一帧", action: #selector(stepFrame(_:)), size: 26)
        nextFrame.tag = 1
        nextFrame.toolTip = "下一帧 →"
        stepButtons = [previousFrame, nextFrame]

        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        rangeLabel.textColor = .secondaryLabelColor
        rangeLabel.setContentHuggingPriority(.required, for: .horizontal)
        resetButton.isHidden = true

        let header = NSStackView(views: [playButton, previousFrame, nextFrame, timeLabel, NSView(), rangeLabel, resetButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        timeline.isDark = theme.isDark
        timeline.accentColor = NSColor(srgbRed: 0.22, green: 0.52, blue: 0.98, alpha: 1)
        timeline.setAccessibilityRole(.image)
        timeline.setAccessibilityLabel("录屏时间轴，拖动两端手柄可精确裁剪")
        timeline.toolTip = "拖动两端裁剪，点击或拖动轨道预览画面"
        timeline.heightAnchor.constraint(equalToConstant: 54).isActive = true

        annotationTimeline.accentColor = timeline.accentColor
        annotationTimeline.heightAnchor.constraint(equalToConstant: 50).isActive = true

        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 96).isActive = true
        progress.isHidden = true
        cancelButton.isHidden = true

        statusBar.orientation = .horizontal
        statusBar.alignment = .centerY
        statusBar.spacing = 8
        statusBar.addArrangedSubview(status)
        statusBar.addArrangedSubview(progress)
        statusBar.addArrangedSubview(NSView())
        statusBar.addArrangedSubview(cancelButton)

        // 把状态/进度与透明标注轨共享在同一个 50pt 槽位里：
        // 平时无标注时只展示简洁提示（零灰色空块！），有 2 行重叠标注时也都能完整可见。
        let lowerLane = NSView()
        lowerLane.heightAnchor.constraint(equalToConstant: 50).isActive = true
        annotationTimeline.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        lowerLane.addSubview(statusBar)
        lowerLane.addSubview(annotationTimeline)
        NSLayoutConstraint.activate([
            annotationTimeline.leadingAnchor.constraint(equalTo: lowerLane.leadingAnchor),
            annotationTimeline.trailingAnchor.constraint(equalTo: lowerLane.trailingAnchor),
            annotationTimeline.topAnchor.constraint(equalTo: lowerLane.topAnchor),
            annotationTimeline.bottomAnchor.constraint(equalTo: lowerLane.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: lowerLane.leadingAnchor, constant: 10),
            statusBar.trailingAnchor.constraint(equalTo: lowerLane.trailingAnchor, constant: -10),
            statusBar.centerYAnchor.constraint(equalTo: lowerLane.centerYAnchor),
        ])

        let stack = NSStackView(views: [header, timeline, lowerLane])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        for view in [header, timeline, lowerLane] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        island.contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: island.contentContainer.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: island.contentContainer.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: island.contentContainer.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: island.contentContainer.bottomAnchor, constant: -8),
        ])
        return island
    }

    private func makeBottomDockRow() -> NSView {
        configureGIFMenu()

        formatPill.onSelect = { [weak self] index in
            guard let self, let format = ExportFormat(rawValue: index) else { return }
            selectExportFormat(format)
        }
        gifSpecButton.isHidden = true
        gifSpecButton.toolTip = "调整 GIF 帧率、尺寸与播放速度"
        gifSpecButton.setAccessibilityRole(.menuButton)
        gifSpecButton.setAccessibilityLabel("GIF 规格与倍速")

        saveButton.toolTip = "保存当前格式文件（⌘S）"
        primaryCopyButton.setAccessibilityLabel("复制视频")
        primaryCopyButton.toolTip = "复制当前片段到剪贴板（⌘C）"

        outputControls = [gifSpecButton, saveButton, primaryCopyButton]

        let dock = LiquidGlassIslandView(isDark: theme.isDark, cornerRadius: nil)
        let dockStack = NSStackView(views: [
            formatPill,
            gifSpecButton,
            hairlineDivider(height: 18),
            dragOutChip,
            saveButton,
            primaryCopyButton,
        ])
        dockStack.orientation = .horizontal
        dockStack.alignment = .centerY
        dockStack.spacing = 6
        dockStack.translatesAutoresizingMaskIntoConstraints = false
        dock.contentContainer.addSubview(dockStack)
        NSLayoutConstraint.activate([
            dock.heightAnchor.constraint(equalToConstant: 44),
            dockStack.leadingAnchor.constraint(equalTo: dock.contentContainer.leadingAnchor, constant: 7),
            dockStack.trailingAnchor.constraint(equalTo: dock.contentContainer.trailingAnchor, constant: -7),
            dockStack.centerYAnchor.constraint(equalTo: dock.contentContainer.centerYAnchor),
        ])

        let container = NSView()
        container.heightAnchor.constraint(equalToConstant: 44).isActive = true
        dock.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dock)
        NSLayoutConstraint.activate([
            dock.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            dock.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dock.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
            dock.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    private func hairlineDivider(height: CGFloat) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = (theme.isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.10)).cgColor
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func pillButton(_ title: String, action: Selector, symbol: String? = nil,
                            shortcut: String? = nil, tone: LiquidGlassPillButton.Tone = .subtle,
                            height: CGFloat = 30, pad: CGFloat = 11) -> LiquidGlassPillButton {
        let button = LiquidGlassPillButton(title: title, target: self, action: action)
        button.configure(title: title, symbol: symbol, shortcut: shortcut,
                         tone: tone, isDark: theme.isDark, height: height, horizontalPadding: pad)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func iconPillButton(_ symbol: String, title: String, action: Selector,
                                tone: LiquidGlassPillButton.Tone = .ghost, size: CGFloat = 28) -> LiquidGlassPillButton {
        let button = LiquidGlassPillButton(title: "", target: self, action: action)
        button.configure(title: "", symbol: symbol, tone: tone, isDark: theme.isDark,
                         height: size, horizontalPadding: 0, capsule: true)
        button.widthAnchor.constraint(equalToConstant: size).isActive = true
        button.heightAnchor.constraint(equalToConstant: size).isActive = true
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    private func compactTimeField(_ title: String, field: NSTextField, scope: String) -> NSStackView {
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.delegate = self
        field.setAccessibilityLabel("\(scope)秒数")
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 3
        field.formatter = formatter
        field.doubleValue = 0
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        return stack
    }

    private func adaptWindowAspectRatioIfNeeded(for videoSize: CGSize) {
        guard !didAdaptInitialWindowSize else { return }
        didAdaptInitialWindowSize = true
        let aspect = max(0.55, min(2.4, videoSize.width / max(1, videoSize.height)))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let chromeHeight: CGFloat = 250
        let targetVideoHeight = min(460, max(280, videoSize.height * 0.65))
        let targetWidth = min(visible.width - 60, max(640, min(920, targetVideoHeight * aspect + 40)))
        let targetHeight = min(visible.height - 60, max(520, min(740, (targetWidth - 40) / aspect + chromeHeight)))
        let origin = CGPoint(x: visible.midX - targetWidth / 2, y: visible.midY - targetHeight / 2)
        window.setFrame(CGRect(origin: origin, size: CGSize(width: targetWidth, height: targetHeight)), display: true)
    }

    // MARK: - 格式切换 & GIF 倍速/规格 & 拖出发送

    func selectExportFormat(_ format: ExportFormat) {
        exportFormat = format
        if formatPill.selectedIndex != format.rawValue {
            formatPill.selectedIndex = format.rawValue
        }
        let isGIF = format == .gif
        gifSpecButton.isHidden = !isGIF
        saveButton.updateContent(title: isGIF ? "保存 GIF" : "保存 MP4", symbol: "arrow.down.to.line")
        primaryCopyButton.updateContent(title: isGIF ? "复制 GIF" : "复制视频", symbol: "doc.on.doc", shortcut: "⌘C")
        primaryCopyButton.setAccessibilityLabel(isGIF ? "复制 GIF" : "复制视频")
        primaryCopyButton.toolTip = isGIF
            ? "将当前片段复制为 GIF（\(gifSpecSummary())，⌘C）"
            : "将当前片段作为 MP4 文件复制（⌘C）"
        updateFormatBadge()
        updateEditsStatus()
    }

    private func updateFormatBadge() {
        let prefix = exportFormat == .gif ? "GIF" : "MP4"
        if let res = videoResolutionText {
            formatLabel.stringValue = "\(prefix) · \(res)"
        } else {
            formatLabel.stringValue = prefix
        }
    }

    private func gifSpecSummary() -> String {
        let speedStr = Self.formatSpeed(gifSpeed)
        return "\(gifFPS)fps · \(speedStr)"
    }

    private static func formatSpeed(_ speed: Double) -> String {
        if speed == floor(speed) {
            return "\(Int(speed))×"
        }
        return String(format: "%g×", speed)
    }

    private func configureDragOutChip() {
        dragOutChip.payloadProvider = { [weak self] in
            guard let self, canOutput, let range = timeline.range else { return nil }
            let format = exportFormat
            let sourceURL = videoURL
            let activeAnnotations = annotations(in: range)
            let isFullUntouched = activeAnnotations.isEmpty && range.start == 0 && range.end == duration
            let cachedMP4 = trimmedURL
            let cachedGIF = gifURL
            let fps = gifFPS
            let size = gifSize
            let speed = gifSpeed
            let thumb = dragPreviewImage()

            if format == .gif {
                return LiquidGlassDragOutChip.DragPayload(
                    fileType: .gif,
                    fileName: "TapSnap-录屏.gif",
                    previewImage: thumb,
                    writeFile: { destination in
                        if let cachedGIF, FileManager.default.fileExists(atPath: cachedGIF.path) {
                            let data = try Data(contentsOf: cachedGIF, options: .mappedIfSafe)
                            try data.write(to: destination, options: .atomic)
                            return
                        }
                        try await GifExporter.export(
                            videoURL: sourceURL,
                            to: destination,
                            sampleInterval: 1 / Double(fps),
                            maximumPixelDimension: size == 0 ? nil : size,
                            playbackSpeed: speed,
                            timeRange: range,
                            annotations: activeAnnotations
                        )
                    }
                )
            } else {
                return LiquidGlassDragOutChip.DragPayload(
                    fileType: .mpeg4Movie,
                    fileName: "TapSnap-录屏.mp4",
                    previewImage: thumb,
                    writeFile: { destination in
                        if isFullUntouched {
                            let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                            try data.write(to: destination, options: .atomic)
                            return
                        }
                        if let cachedMP4, FileManager.default.fileExists(atPath: cachedMP4.path) {
                            let data = try Data(contentsOf: cachedMP4, options: .mappedIfSafe)
                            try data.write(to: destination, options: .atomic)
                            return
                        }
                        try await VideoTrimmer.export(
                            videoURL: sourceURL,
                            to: destination,
                            range: range,
                            annotations: activeAnnotations
                        )
                    }
                )
            }
        }
    }

    private func dragPreviewImage() -> NSImage {
        if let cg = timeline.thumbnails.compactMap({ $0 }).first {
            return NSImage(cgImage: cg, size: CGSize(width: 68, height: 48))
        }
        return NSImage(systemSymbolName: exportFormat == .gif ? "sparkles.rectangle.stack" : "film",
                       accessibilityDescription: nil) ?? NSImage(size: CGSize(width: 48, height: 48))
    }

    // MARK: - 标注与快速调色

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

    private func applyQuickColor(_ color: RGBAColor) {
        guard canEditAnnotations else { return }
        if let annotation = selectedAnnotation {
            var style = annotation.style
            style.color = color
            edits.toolStyles[annotation.kind] = style
            changeAnnotation(annotation.id) { $0.style.color = color }
        } else if let kind = activeTool {
            var style = toolStyle(for: kind)
            style.color = color
            edits.toolStyles[kind] = style
            updateToolStyle()
        }
        syncQuickColorState()
    }

    private func syncQuickColorState() {
        let targetKind = selectedAnnotation?.kind ?? activeTool
        toolsState.showsQuickColors = targetKind != nil && targetKind != .mask
        if let annotation = selectedAnnotation {
            toolsState.activeColor = annotation.style.color
        } else if let kind = activeTool {
            toolsState.activeColor = toolStyle(for: kind).color
        } else {
            toolsState.activeColor = nil
        }
    }

    private func selectTool(_ kind: RecordingAnnotation.Kind?) {
        activeTool = kind
        annotationCanvas.tool = kind
        toolsState.selectedTool = kind
        updateToolStyle()
        syncQuickColorState()
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
        syncQuickColorState()
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
        annotationInspectorIsland.isHidden = current == nil
        if let current {
            annotationTitle.stringValue = current.kind.title
            annotationStart.doubleValue = current.range.start
            annotationEnd.doubleValue = current.range.end
            editTextButton.isHidden = current.kind != .text
        }
        syncQuickColorState()
        updateLowerLaneVisibility()
        refreshAnnotationSelectionOutline()
        updateAnnotationAvailability(enabled: annotationEditingAvailable)
    }

    private func updateLowerLaneVisibility() {
        let isExporting = exportTask != nil || isSaving
        let hasAnnotations = !edits.annotations.isEmpty
        statusBar.isHidden = hasAnnotations && !isExporting
        annotationTimeline.isHidden = isExporting
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
        } else if exportFormat == .gif {
            status.stringValue = "GIF 导出：\(gifFPS) FPS · \(gifSize == 0 ? "原始尺寸" : "\(gifSize)px") · \(Self.formatSpeed(gifSpeed)) 倍速"
        } else if trim.start == 0, trim.end == duration {
            status.stringValue = "空格播放 · 拖两头裁剪 · ⌘C 复制或按住「拖出发送」直发"
        } else {
            status.stringValue = "复制、保存与拖出发送将使用当前裁剪片段"
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

    // MARK: - GIF 参数菜单（倍速 / 帧率 / 尺寸）

    private func configureGIFMenu() {
        gifMenu.removeAllItems()

        let speedHeader = NSMenuItem(title: "播放速度", action: nil, keyEquivalent: "")
        speedHeader.isEnabled = false
        gifMenu.addItem(speedHeader)
        for option in Self.gifSpeedOptions {
            let item = gifMenu.addItem(withTitle: option.label, action: #selector(changeGIFSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.speed
            item.state = abs(option.speed - gifSpeed) < 0.001 ? .on : .off
        }

        gifMenu.addItem(.separator())
        let fpsMenu = NSMenu()
        for fps in [10, 15, 24, 30] {
            let item = fpsMenu.addItem(withTitle: "\(fps) FPS", action: #selector(changeGIFFPS(_:)), keyEquivalent: "")
            item.target = self
            item.tag = fps
            item.state = fps == gifFPS ? .on : .off
        }
        gifMenu.addItem(withTitle: "帧率（当前 \(gifFPS) FPS）", action: nil, keyEquivalent: "").submenu = fpsMenu

        let sizeMenu = NSMenu()
        for size in [640, 960, 1280, 1920, 0] {
            let item = sizeMenu.addItem(withTitle: size == 0 ? "原始尺寸" : "最长边 \(size) 像素",
                                        action: #selector(changeGIFSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = size
            item.state = size == gifSize ? .on : .off
        }
        let sizeText = gifSize == 0 ? "原始尺寸" : "\(gifSize)px"
        gifMenu.addItem(withTitle: "尺寸（当前 \(sizeText)）", action: nil, keyEquivalent: "").submenu = sizeMenu
    }

    @objc private func showGIFOptions(_ sender: NSButton) {
        configureGIFMenu()
        gifMenu.popUp(positioning: nil, at: CGPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func changeGIFSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? Double else { return }
        setGIFSpeed(speed)
    }

    func setGIFSpeed(_ speed: Double) {
        gifSpeed = speed
        gifURL = nil
        gifSpecButton.updateContent(title: gifSpecSummary(), symbol: "gauge.with.dots.needle.67percent")
        updateEditsStatus()
    }

    @objc private func changeGIFFPS(_ sender: NSMenuItem) {
        gifFPS = sender.tag
        gifURL = nil
        gifSpecButton.updateContent(title: gifSpecSummary(), symbol: "gauge.with.dots.needle.67percent")
        updateEditsStatus()
    }

    @objc private func changeGIFSize(_ sender: NSMenuItem) {
        gifSize = sender.tag
        gifURL = nil
        gifSpecButton.updateContent(title: gifSpecSummary(), symbol: "gauge.with.dots.needle.67percent")
        updateEditsStatus()
    }

    // MARK: - 缩略图与窗口生命周期

    private func loadThumbnails(_ asset: AVURLAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 224, height: 128)
        let count = timeline.thumbnails.count
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
    }

    func windowWillClose(_ notification: Notification) { close() }

    // MARK: - 播放与时间轴

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
        playButton.updateContent(title: "", symbol: playing ? "pause.fill" : "play.fill")
        playButton.setAccessibilityLabel(label)
        refreshAnnotationSelectionOutline()
    }

    private func updatePlaybackTime(_ time: TimeInterval) {
        guard !closed, time.isFinite else { return }
        timeline.playhead = time
        annotationTimeline.playhead = time
        timeLabel.stringValue = "\(timestamp(time)) / \(timestamp(duration))"
        refreshAnnotationSelectionOutline()
    }

    private func syncPlaybackTime() {
        guard !trackingScrub, seekInProgress == nil, queuedSeek == nil else { return }
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
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 60_000)
        let isFull = range.start == 0 && range.end == duration
        rangeLabel.stringValue = isFull
            ? String(format: "全段 · %.2fs", duration)
            : String(format: "%.2fs – %.2fs · 共 %.2fs", range.start, range.end, range.duration)
        resetButton.isEnabled = !isFull
        resetButton.isHidden = isFull
        gifURL = nil
        trimmedURL = nil
        updateEditsStatus()
    }

    // MARK: - 导出与剪贴板

    @objc private func cancelExport() { exportTask?.cancel() }

    @objc private func copyCurrentFormat() {
        if exportFormat == .gif {
            prepareGIF(save: false)
        } else {
            prepareVideo(save: false)
        }
    }

    @objc private func saveCurrentFormat() {
        if exportFormat == .gif {
            prepareGIF(save: true)
        } else {
            prepareVideo(save: true)
        }
    }

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
        let fps = gifFPS, size = gifSize, speed = gifSpeed
        let current = UUID()
        exportID = current
        setExporting(true)
        status.stringValue = "正在生成 GIF（\(Self.formatSpeed(speed))）…"
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await GifExporter.export(
                    videoURL: videoURL,
                    to: destination,
                    sampleInterval: 1 / Double(fps),
                    maximumPixelDimension: size == 0 ? nil : size,
                    playbackSpeed: speed,
                    timeRange: range,
                    annotations: annotations,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.exportID == current, !self.closed else { return }
                            self.progress.doubleValue = value
                            self.status.stringValue = "正在生成 GIF… \(Int(value * 100))%"
                        }
                    }
                )
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
        formatPill.isEnabled = !exporting && duration > 0
        dragOutChip.isEnabled = !exporting && duration > 0
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
        updateLowerLaneVisibility()
    }

    private func useFile(_ url: URL, type: UTType, save: Bool) {
        if save {
            saveFile(url, type: type)
        } else {
            do {
                if type == .gif {
                    try RecordingClipboard.copyGIF(at: url, to: pasteboard)
                    status.stringValue = "GIF 已复制 · \(gifSpecSummary())"
                    primaryCopyButton.flashSuccess("已复制 GIF")
                } else {
                    try RecordingClipboard.copyVideo(at: url, to: pasteboard)
                    status.stringValue = "视频已复制 · 可粘贴为 MP4 文件"
                    primaryCopyButton.flashSuccess("已复制 MP4")
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
                    self.saveButton.flashSuccess("已保存")
                } catch { self.status.stringValue = "保存失败：\(error.localizedDescription)" }
                self.isSaving = false
                if !self.closed { self.setExporting(false) }
            }
        }
    }
}

private final class RecordingPreviewWindow: NSPanel {
    var onCopyCurrent: (() -> Void)?
    var onSaveCurrent: (() -> Void)?
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
                onCopyCurrent?()
            }
            return true
        }
        if attachedSheet == nil, modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            if !(firstResponder is NSTextView), !event.isARepeat {
                onSaveCurrent?()
                return true
            }
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

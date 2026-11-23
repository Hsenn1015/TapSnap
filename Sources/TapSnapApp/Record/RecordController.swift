import AppKit
import Foundation
import TapSnapCore
import TapSnapMedia
import TapSnapScreen
import TapSnapTheme
import SwiftUI

/// 框选、录制控制和结果预览。所有会话操作都在主线程执行。
final class RecordController {
    private let environment: AppEnvironment
    private let makeSession: @MainActor (RecordSession.Configuration) -> RecordSession
    private var session: RecordSession?
    private var barWindow: NSPanel?
    private var barModel: RecordControlBarModel?
    private var regionOverlay: RecordingRegionOverlay?
    private var preview: RecordingPreviewPanel?
    private var token = UUID()
    private var isFinishing = false
    private var startup: (id: UUID, task: Task<Void, Never>)?
    private(set) var lastRecordingURL: URL?
    private var lastRecordingEdits = RecordingPreviewEdits()

    @MainActor
    var isRecordingOrEditing: Bool { startup != nil || session != nil || preview != nil }

    @MainActor
    var borderWindowID: CGWindowID? {
        guard let regionOverlay, regionOverlay.windowNumber > 0 else { return nil }
        return CGWindowID(regionOverlay.windowNumber)
    }

    init(environment: AppEnvironment,
         makeSession: @escaping @MainActor (RecordSession.Configuration) -> RecordSession = {
             RecordSession(configuration: $0)
         }) {
        self.environment = environment
        self.makeSession = makeSession
    }

    /// 再按一次录屏快捷键结束当前录制。
    func start() {
        Task { @MainActor in
            if let session {
                switch session.state {
                case .recording, .paused: finish()
                default: barWindow?.orderFrontRegardless()
                }
                return
            }
            preview?.close()
            preview = nil
            environment.captureCoordinator.start(.record)
            environment.toast.info("框选要录制的区域，确认后开始录制")
        }
    }

    /// rect 是相对该屏幕左上角的点坐标。
    func start(rect: CGRect, screen: ScreenDescriptor) {
        start(rect: rect, screen: screen, replacing: nil)
    }

    private func start(rect: CGRect, screen: ScreenDescriptor, replacing previous: RecordSession?) {
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if startup?.id == requestID { startup = nil } }
            guard !Task.isCancelled else { return }
            guard session === previous else {
                barWindow?.orderFrontRegardless()
                environment.toast.info("已有录制任务，请先完成或取消当前录制")
                return
            }
            preview?.close()
            preview = nil
            let current = UUID()
            token = current
            if let previous {
                previous.cancel()
                try? FileManager.default.removeItem(at: previous.configuration.outputURL)
            }
            let settings = environment.config.settings.record
            do {
                let directory = try AppPaths.ensureDirectory(AppPaths.caches.appendingPathComponent("recordings", isDirectory: true))
                let output = directory.appendingPathComponent("recording-\(UUID().uuidString).mp4")
                var configuration = previous?.configuration ?? .init(
                    screen: screen, rect: rect, frameRate: settings.frameRate,
                    includesCursor: settings.includesCursor, includesMicrophone: settings.includesMicrophone,
                    includesSystemAudio: settings.includesSystemAudio,
                    includesCamera: settings.includesCamera, showsKeyPresses: settings.showsKeyPresses,
                    showsMouseClicks: settings.showsMouseClicks, outputURL: output)
                configuration.outputURL = output
                let recording = makeSession(configuration)
                session = recording
                let model = barModel ?? makeRecordingControls(for: rect, screen: screen)
                recording.onStateChange = { [weak self] state in
                    guard let self, token == current else { return }
                    switch state {
                    case .paused:
                        regionOverlay?.isPaused = true
                    case .recording:
                        regionOverlay?.isPaused = false
                    case .finishing:
                        regionOverlay?.close()
                        regionOverlay = nil
                    case .failed(let message):
                        guard startup?.id != requestID else { return }
                        teardown()
                        environment.toast.error("录制失败：\(message)")
                    default: break
                    }
                }
                try await recording.start()
                guard token == current, session === recording else { return }
                model.isBusy = false
                model.startTimer { recording.elapsed }
            } catch {
                guard token == current else { return }
                teardown()
                let selection = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                guard !(error is CancellationError),
                      !environment.guideScreenCapturePermission(for: error, resuming: .init(outcome: .record,
                          rect: selection, displayID: screen.id)) else { return }
                environment.toast.error("无法开始录制：\(error.localizedDescription)")
            }
        }
        startup = (requestID, task)
    }

    @MainActor
    private func makeRecordingControls(for rect: CGRect, screen: ScreenDescriptor) -> RecordControlBarModel {
        let model = RecordControlBarModel()
        model.onPauseToggle = { [weak self] in self?.togglePause() }
        model.onRestart = { [weak self] in self?.restart(rect: rect, screen: screen) }
        model.onFinish = { [weak self] in self?.finish() }
        model.onCancel = { [weak self] in self?.cancel() }
        let overlay = RecordingRegionOverlay(rect: rect, screen: screen,
            borderStyle: environment.config.settings.capture.selectionBorderStyle)
        let window = Self.makeControlBar(for: rect, displayFrame: overlay.frame, visibleFrame: screen.visibleFrame,
                                         model: model, theme: environment.theme)
        barModel = model
        regionOverlay = overlay
        barWindow = window
        overlay.orderFrontRegardless()
        window.orderFrontRegardless()
        return model
    }

    @MainActor
    static func makeControlBar(for rect: CGRect, displayFrame: CGRect, visibleFrame: CGRect,
                               model: RecordControlBarModel, theme: Theme) -> NSPanel {
        let controller = NSHostingController(rootView: RecordControlBarView(model: model, theme: theme))
        let size = controller.sizeThatFits(in: CGSize(width: visibleFrame.width, height: 44))
        // 保持面板宽度，计时文案变化时仍围绕选区中心布局。
        controller.sizingOptions = []
        let frame = controlBarFrame(for: rect, displayFrame: displayFrame, visibleFrame: visibleFrame, size: size)
        let window = NSPanel(contentRect: frame,
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.hidesOnDeactivate = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrame(frame, display: false)
        return window
    }

    static func controlBarFrame(for rect: CGRect, displayFrame: CGRect, visibleFrame: CGRect, size: CGSize) -> CGRect {
        let outlineGap: CGFloat = 8
        let available = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(ceil(size.width), available.width)
        let height = size.height
        // 选区相对屏幕左上角，控制条窗口使用 AppKit 全局坐标。
        let selection = CGRect(x: displayFrame.minX + rect.minX, y: displayFrame.maxY - rect.maxY,
                               width: rect.width, height: rect.height)
        let outline = SelectionBorderView.outlineRect(for: selection, in: displayFrame)
        let x = min(max(selection.midX - width / 2, available.minX), available.maxX - width)
        let below = min(outline.minY - outlineGap - height, available.maxY - height)
        let above = max(outline.maxY + outlineGap, available.minY)
        let y: CGFloat
        if below >= available.minY {
            y = below
        } else if above + height <= available.maxY {
            y = above
        } else {
            y = available.minY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    @MainActor
    private func restart(rect: CGRect, screen: ScreenDescriptor) {
        guard let recording = session, let model = barModel, !model.isBusy else { return }
        switch recording.state {
        case .recording, .paused:
            model.stopTimer()
            model.elapsed = 0
            model.isPaused = false
            model.busyText = "正在重录…"
            model.isBusy = true
            regionOverlay?.isPaused = false
            start(rect: rect, screen: screen, replacing: recording)
        default: break
        }
    }

    private func togglePause() {
        Task { @MainActor in
            guard let session, let model = barModel, !model.isBusy else { return }
            switch session.state {
            case .recording:
                session.pause()
                model.isPaused = true
            case .paused:
                session.resume()
                model.isPaused = false
            default: break
            }
        }
    }

    private func finish() {
        Task { @MainActor in
            guard let recording = session, let model = barModel, !model.isBusy else { return }
            switch recording.state {
            case .recording, .paused: break
            default: return
            }
            let current = token
            isFinishing = true
            model.isFinishing = true
            model.isBusy = true
            model.busyText = "正在结束…"
            model.stopTimer()
            do {
                let url = try await recording.finish()
                guard token == current, session === recording else { return }
                let screen = barWindow?.screen
                teardown()
                guard let url else {
                    environment.toast.error("录制没有生成可播放的内容")
                    return
                }
                lastRecordingURL = url
                lastRecordingEdits = RecordingPreviewEdits()
                showPreview(videoURL: url, on: screen)
            } catch {
                guard token == current else { return }
                teardown()
                environment.toast.error("录制保存失败：\(error.localizedDescription)")
            }
        }
    }

    private func cancel() {
        Task { @MainActor in
            guard !isFinishing else { return }
            token = UUID()
            startup?.task.cancel()
            startup = nil
            session?.cancel()
            teardown()
        }
    }

    func showLastRecording() {
        Task { @MainActor in
            if let preview {
                preview.show()
                return
            }
            guard let url = lastRecordingURL else {
                environment.toast.warning("还没有可预览的录制文件")
                return
            }
            showPreview(videoURL: url)
        }
    }

    @MainActor
    private func showPreview(videoURL: URL, on screen: NSScreen? = nil) {
        preview?.close()
        let panel = RecordingPreviewPanel(videoURL: videoURL, theme: environment.theme, edits: lastRecordingEdits)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel, preview === panel else { return }
            if videoURL == lastRecordingURL { lastRecordingEdits = panel.edits }
            preview = nil
        }
        preview = panel
        panel.show(on: screen)
    }

    @MainActor
    private func teardown() {
        token = UUID()
        regionOverlay?.close()
        regionOverlay = nil
        barModel?.stopTimer()
        barWindow?.orderOut(nil)
        barWindow = nil
        barModel = nil
        session = nil
        isFinishing = false
    }
}

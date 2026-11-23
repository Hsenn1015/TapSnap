import AppKit
import Foundation
import TapSnapCore
import TapSnapImageIO
import TapSnapScreen
import TapSnapStitching
import TapSnapSystem
import UniformTypeIdentifiers

/// 滚动长截图会话。
///
/// 持续捕获指定区域，由 `FrameStitcher` 按位移拼接，完成后显示预览。
final class LongShotSession: NSObject {
    private let environment: AppEnvironment
    private let makeStreamer: () -> ScreenStreamer
    private let resolveRegion: (CGPoint, CGRect) -> ScrollRegionResolution?
    private var streamer: ScreenStreamer?
    private let stitcher = FrameStitcher()
    private var selectionRect: CGRect?
    private var screen: ScreenDescriptor?
    private let preview = LongShotPreviewPanel()
    private var privacyEditor: EditController?
    private var forcePrivacy = false

    private enum State { case idle, capturing, finishing, result }
    private enum ScrollRegionSource: String {
        case system = "系统滚动视口"
        case manual = "用户指定滚动视口"
    }
    // UI 状态只在主线程访问；旧会话的异步回调不能重新打开窗口。
    private var state: State = .idle
    private var sessionID = UUID()
    private var processingFrame = false
    private var capturedSegments = 0
    private var scrollMonitor: Any?
    private var interruptionMonitor: Any?
    private var automaticRequested = false
    private var automaticStartPending = false
    private var automaticTask: Task<Void, Never>?
    private var latestAutomaticFrame: ScreenStreamer.Frame?
    private static let automaticEventTag: Int64 = 0x545341

    private var resolvingRegion = false
    private var probingAutomatically = false
    private var layoutReady = false
    private var scrollViewport: CGRect?
    private var scrollProcessID: pid_t?
    private var selectionImage: CGImage?
    private var pendingFrame: CGImage?
    private var regionWindow: SelectionOverlayWindow?
    private var regionRequestID = UUID()
    private let regionQueue = DispatchQueue(label: "com.sensnap.longshot-region")

    /// 拼接串行执行，同时最多接收一张在途帧，避免长图越来越慢时积压整屏图像。
    private let stitchingQueue = DispatchQueue(label: "com.sensnap.longshot")

    @MainActor
    var hasActiveSession: Bool { state != .idle }

    init(environment: AppEnvironment, makeStreamer: @escaping () -> ScreenStreamer = { ScreenStreamer() },
         resolveRegion: @escaping (CGPoint, CGRect) -> ScrollRegionResolution? = ScrollRegionResolver.resolve) {
        self.environment = environment
        self.makeStreamer = makeStreamer
        self.resolveRegion = resolveRegion
        super.init()
    }

    func start() {
        guard state == .idle else {
            preview.showExisting()
            return
        }
        // 长截图的第一屏仍然要先框选，复用截图覆盖层。
        environment.captureCoordinator.start(.longShot, mode: .longShot)
        environment.toast.info("框选需要滚动的区域，之后按提示滚动")
    }

    /// 框选完成后由 `CaptureCoordinator` 调用，进入持续抓帧阶段。
    func beginCapturing(rect: CGRect, screen: ScreenDescriptor, initialImage: CGImage? = nil, forcePrivacy: Bool = false) {
        guard state == .idle else {
            preview.showExisting()
            return
        }
        guard rect.width * screen.scale > 16, rect.height * screen.scale > 32 else {
            environment.toast.warning("选区太小，请重新选择较大的滚动区域")
            return
        }
        state = .capturing
        self.forcePrivacy = forcePrivacy || environment.config.settings.privacy.enabled
        sessionID = UUID()
        let id = sessionID
        self.selectionRect = rect
        self.screen = screen
        processingFrame = false
        capturedSegments = 0
        layoutReady = false
        resolvingRegion = false
        regionRequestID = UUID()
        scrollViewport = nil
        scrollProcessID = nil
        selectionImage = initialImage
        pendingFrame = nil
        stitchingQueue.async { [stitcher] in stitcher.reset() }

        // 预览窗同时充当控制条：完成 / 取消都在它上面。
        preview.showLive(
            on: screen,
            avoiding: rect,
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() },
            onSelectScrollRegion: { [weak self] in self?.selectScrollRegion() },
            onToggleAutomaticScroll: { [weak self] in self?.toggleAutomaticScroll() }
        )
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard event.scrollingDeltaY != 0 else { return }
            let wheel = event.cgEvent
            if let wheel, Self.isAutomaticWheel(wheel) { return }
            let point = wheel?.location ?? CursorSnapshot.current().location
            DispatchQueue.main.async {
                guard let self, self.sessionID == id, self.state == .capturing else { return }
                self.didScroll(at: point)
            }
        }

        // 保留框选时的第一屏，避免启动流期间用户滚动而漏掉开头。
        if let initialImage { append(initialImage, sessionID: id) }
        let streamer = makeStreamer()
        streamer.onFrame = { [weak self] frame in
            DispatchQueue.main.async { self?.handle(frame, sessionID: id) }
        }
        streamer.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.sessionID == id, self.state == .capturing else { return }
                self.environment.toast.error("长截图中断：\(error.localizedDescription)")
                self.finish()
            }
        }
        self.streamer = streamer
        streamer.start(screen: screen, frameRate: 10, excludingCurrentApplication: true,
                       hideDesktopIcons: environment.config.settings.capture.hideDesktopIcons)
        interruptionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.sessionID == id, self.state == .capturing else { return }
                self.pauseAutomaticScroll(message: "检测到操作，自动滚动已暂停")
            }
        }
        if environment.config.settings.longShot.autoScroll {
            requestAutomaticScroll(afterHandoff: true)
        }
    }

    private func handle(_ frame: ScreenStreamer.Frame, sessionID id: UUID) {
        guard state == .capturing, sessionID == id else { return }
        if automaticTask != nil {
            latestAutomaticFrame = frame
            return
        }
        guard !processingFrame, let rect = selectionRect, let screen,
              let cropped = Self.cropFrame(frame.image, rect: rect, screen: screen) else { return }
        if selectionImage == nil {
            selectionImage = cropped
            append(cropped, sessionID: id)
        } else if !layoutReady || resolvingRegion {
            pendingFrame = cropped
        } else {
            append(cropped, sessionID: id)
        }
    }

    func didScroll(at point: CGPoint) {
        guard state == .capturing else { return }
        pauseAutomaticScroll(message: "已切换为手动滚动")
        // The pointer can leave the scrolling body while trackpad momentum is still active.
        guard !layoutReady, !resolvingRegion, regionWindow == nil,
              let selectionRect, selectionRect.contains(point) else { return }
        findScrollRegion(at: point, within: selectionRect, automatically: false)
    }

    private func findScrollRegion(at point: CGPoint, within selection: CGRect, automatically: Bool,
                                  retry: Bool = true, delay: DispatchTimeInterval = .milliseconds(0)) {
        resolvingRegion = true
        probingAutomatically = automatically
        let id = sessionID
        let requestID = UUID()
        regionRequestID = requestID
        regionQueue.asyncAfter(deadline: .now() + delay) { [weak self, resolveRegion] in
            let resolution = resolveRegion(point, selection)
            DispatchQueue.main.async {
                guard let self, self.sessionID == id, self.regionRequestID == requestID,
                      self.state == .capturing, self.regionWindow == nil else { return }
                self.probingAutomatically = false
                if let resolution {
                    self.configureScrollRegion(resolution.content, viewport: resolution.viewport,
                                               processID: resolution.processID, source: .system, sessionID: id)
                } else if automatically, retry, self.automaticRequested {
                    self.findScrollRegion(at: point, within: selection, automatically: true, retry: false,
                                          delay: .milliseconds(250))
                } else {
                    self.useOriginalSelection(sessionID: id)
                }
            }
        }
    }

    /// 仅在用户点击「滚动区域…」后显示第二次框选。
    private func selectScrollRegion() {
        pauseAutomaticScroll(message: nil)
        guard state == .capturing, capturedSegments <= 1, regionWindow == nil,
              let selectionRect, let screen, let selectionImage else { return }
        guard !processingFrame, !resolvingRegion else {
            preview.updateStatus("正在处理当前帧，请稍后选择滚动区域")
            return
        }
        resolvingRegion = true
        regionRequestID = UUID()
        let window = SelectionOverlayWindow(screen: screen)
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        window.setFrame(CGRect(x: selectionRect.minX, y: desktopTop - selectionRect.maxY,
                               width: selectionRect.width, height: selectionRect.height), display: false)
        let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: selectionRect.size))
        view.screenImage = selectionImage
        view.showsMagnifier = false
        let id = sessionID
        view.onFinish = { [weak self] rect in
            guard let self, self.sessionID == id, self.state == .capturing else { return }
            self.dismissRegionWindow()
            guard let rect else {
                self.resolvingRegion = false
                self.preview.updateStatus(self.layoutReady ? "已保留滚动区域，可继续滚动" : "可滚动正文，或点「滚动区域…」")
                if self.layoutReady { self.resumeAfterRegionSelection(sessionID: id) }
                return
            }
            let global = CGRect(x: selectionRect.minX + rect.minX,
                                y: selectionRect.minY + selectionRect.height - rect.maxY,
                                width: rect.width, height: rect.height).intersection(selectionRect)
            self.configureScrollRegion(global, viewport: global, source: .manual, sessionID: id)
        }
        window.contentView = view
        regionWindow = window
        preview.updateStatus("框选滚动正文，按回车确认，Esc 返回")
        environment.toast.info("框选滚动正文，按回车确认，Esc 返回")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func configureScrollRegion(_ content: CGRect, viewport: CGRect, processID: pid_t? = nil,
                                       source: ScrollRegionSource, sessionID id: UUID) {
        guard let selectionRect, let selectionImage else { resolvingRegion = false; return }
        let requestID = regionRequestID
        let scaleX = CGFloat(selectionImage.width) / selectionRect.width
        let scaleY = CGFloat(selectionImage.height) / selectionRect.height
        let rect = CGRect(x: (content.minX - selectionRect.minX) * scaleX,
                          y: (content.minY - selectionRect.minY) * scaleY,
                          width: content.width * scaleX, height: content.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: selectionImage.width, height: selectionImage.height))
        stitchingQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.stitcher.setScrollingRect(rect) }
            DispatchQueue.main.async {
                guard self.sessionID == id, self.regionRequestID == requestID, self.state == .capturing else { return }
                self.resolvingRegion = false
                switch result {
                case .success:
                    self.scrollViewport = viewport
                    self.scrollProcessID = processID
                    self.layoutReady = true
                    Log.shared.info("长截图布局：原帧 \(selectionImage.width)×\(selectionImage.height)，\(source.rawValue) \(rect)")
                    self.preview.updateStatus("已确定滚动区域，请继续向下滚动")
                    self.resumeAfterRegionSelection(sessionID: id)
                case .failure(let error):
                    if case StitchingError.invalidScrollingRegion = error, source == .system {
                        self.useOriginalSelection(sessionID: id)
                        return
                    }
                    if case StitchingError.layoutChanged = error {
                        self.environment.toast.warning("已开始拼接，无法更换滚动区域；已保留当前结果")
                        self.finish()
                        return
                    }
                    self.pauseAutomaticScroll(message: nil)
                    self.preview.updateStatus("滚动区域太小。点「滚动区域…」重选。", isWarning: true)
                }
            }
        }
    }

    private func useOriginalSelection(sessionID id: UUID) {
        resolvingRegion = false
        pauseAutomaticScroll(message: nil)
        // Keep stitching the complete first selection, without inferring an automatic scroll target.
        layoutReady = true
        preview.updateStatus("已沿用原选区，可手动向下滚动")
        Log.shared.info("长截图：系统未返回可用滚动视口，沿用原选区手动滚动")
        resumeAfterRegionSelection(sessionID: id)
    }

    private func resumeAfterRegionSelection(sessionID id: UUID) {
        if let frame = pendingFrame {
            pendingFrame = nil
            append(frame, sessionID: id)
        } else {
            startAutomaticScrollIfReady()
        }
    }

    private func stopRegionSelection() {
        pauseAutomaticScroll(message: nil)
        if let interruptionMonitor { NSEvent.removeMonitor(interruptionMonitor) }
        interruptionMonitor = nil
        regionRequestID = UUID()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        dismissRegionWindow()
        pendingFrame = nil
        selectionImage = nil
        resolvingRegion = false
    }

    private func dismissRegionWindow() {
        (regionWindow?.contentView as? SelectionOverlayView)?.stopBorderAnimation()
        regionWindow?.orderOut(nil)
        regionWindow = nil
    }

    static func cropFrame(_ image: CGImage, rect: CGRect, screen: ScreenDescriptor) -> CGImage? {
        let localRect = Geometry.localRect(rect, in: screen.frame)
        // 使用实际抓帧比例；显示缩放变化时也不把 point 当作 pixel 裁剪。
        let scale = CGFloat(image.width) / screen.frame.width
        return ImageCrop.crop(image, to: localRect.snapped(to: scale), scale: scale)
    }

    private func append(_ cropped: CGImage, sessionID id: UUID,
                        onAutomaticResult: ((Result<Bool, Error>) -> Void)? = nil) {
        processingFrame = true
        stitchingQueue.async {
            let previousHeight = self.stitcher.currentImage?.height ?? 0
            let result = Result { try self.stitcher.append(cropped) }
            let hasFixedRegions = self.stitcher.hasFixedRegions
            DispatchQueue.main.async {
                if self.sessionID == id { self.processingFrame = false }
                guard self.sessionID == id, self.state == .capturing else {
                    onAutomaticResult?(.failure(CancellationError()))
                    return
                }
                if case .success(let stitched) = result, stitched.height > previousHeight {
                    self.capturedSegments += 1
                    if stitched.height > cropped.height { self.preview.lockScrollRegion() }
                    self.preview.update(image: stitched, viewportHeight: CGFloat(cropped.height))
                    if self.layoutReady {
                        let detail = hasFixedRegions ? "固定区域保留一次，其下留白" : "\(stitched.width) × \(stitched.height) 像素"
                        self.preview.updateStatus("已拼接 \(self.capturedSegments) 段 · \(detail)")
                    }
                }
                if let onAutomaticResult {
                    onAutomaticResult(result.map { $0.height > previousHeight })
                } else if case .failure(let error) = result {
                    self.reportStitchingError(error)
                }
                self.startAutomaticScrollIfReady()
            }
        }
    }

    private func reportStitchingError(_ error: Error, automatic: Bool = false) {
        if automatic { Log.shared.warn("长截图自动滚动拼接失败：\(error)") }
        switch error {
        case StitchingError.imageTooLarge:
            environment.toast.warning("长图已达到尺寸上限，已保留当前结果")
            finish()
        case StitchingError.incompatibleFrame:
            environment.toast.warning("画面尺寸发生变化，已保留当前结果")
            finish()
        case StitchingError.layoutChanged:
            environment.toast.warning("滚动区域发生变化，已保留当前结果；请重新开始")
            finish()
        case StitchingError.reverseScroll where !automatic:
            preview.updateStatus("当前向上滚动：请回到已截位置，继续向下", isWarning: true)
        default:
            let message = automatic ? "自动滚动已暂停，请回滚少许后继续" : "本帧未拼接：请回滚少许，再缓慢向下滚动"
            preview.updateStatus(message, isWarning: true)
        }
    }

    private func toggleAutomaticScroll() {
        guard state == .capturing else { return }
        if automaticRequested { pauseAutomaticScroll(message: "自动滚动已暂停"); return }
        requestAutomaticScroll()
    }

    private func requestAutomaticScroll(afterHandoff: Bool = false) {
        guard Permissions.status(of: .accessibility) == .authorized else {
            if afterHandoff {
                preview.updateStatus("请手动滚动，或点击「自动滚动」开启辅助功能权限")
            } else {
                environment.showAccessibilityGuide(for: "自动滚动")
            }
            return
        }
        automaticRequested = true
        preview.setAutomaticScroll(true)
        if afterHandoff {
            // Let the selection panels disappear before hit-testing the target app.
            automaticStartPending = true
            let id = sessionID
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                guard let self, self.sessionID == id, self.automaticStartPending else { return }
                self.automaticStartPending = false
                self.startAutomaticScrollIfReady()
            }
        } else {
            startAutomaticScrollIfReady()
        }
    }

    private func startAutomaticScrollIfReady() {
        guard state == .capturing, automaticRequested, !automaticStartPending, automaticTask == nil,
              !processingFrame, !resolvingRegion, regionWindow == nil,
              let selectionRect, let screen else { return }
        guard let scrollViewport, layoutReady else {
            if layoutReady, capturedSegments > 1 {
                pauseAutomaticScroll(message: "本次已沿用原选区，可继续手动滚动")
                return
            }
            if selectionImage != nil {
                preview.updateStatus("正在确定滚动区域…")
                findScrollRegion(at: selectionRect.center, within: selectionRect, automatically: true)
            }
            return
        }
        let settings = environment.config.settings.longShot
        let policy = AutomaticScrollPolicy(viewportHeight: scrollViewport.height, configuredStep: settings.scrollStep,
            intervalMilliseconds: settings.scrollIntervalMs, overlap: settings.overlapRatio)
        let target = scrollViewport.center
        guard let window = Self.scrollTargetWindow(at: target, expectedProcess: scrollProcessID),
              let eventSource = CGEventSource(stateID: .privateState) else {
            pauseAutomaticScroll(message: "找不到可自动滚动的窗口，可手动滚动")
            return
        }
        eventSource.localEventsSuppressionInterval = 0
        preview.updateStatus("将鼠标移到滚动正文，停一下会自动开始")
        let id = sessionID
        automaticTask = Task { @MainActor [weak self] in
            await self?.runAutomaticScroll(policy, viewport: scrollViewport, window: window, eventSource: eventSource,
                                           rect: selectionRect, screen: screen, sessionID: id)
        }
    }

    @MainActor
    private func runAutomaticScroll(_ policy: AutomaticScrollPolicy, viewport: CGRect, window: ScrollTarget,
                                    eventSource: CGEventSource, rect: CGRect, screen: ScreenDescriptor,
                                    sessionID id: UUID) async {
        var stationarySteps = 0
        var waitingForPointer = true
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        do {
            while sessionID == id {
                try Task.checkCancellation()
                guard let pointer = CGEvent(source: nil)?.location, viewport.contains(pointer),
                      !preview.isUnderPointer(at: pointer, desktopTop: desktopTop),
                      CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved) >= 0.05 else {
                    if !waitingForPointer {
                        waitingForPointer = true
                        preview.updateStatus("将鼠标移回滚动正文可继续，也可点「暂停滚动」")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                guard Self.scrollTargetWindow(at: pointer, expectedProcess: window.pid) == window else {
                    pauseAutomaticScroll(message: "原滚动窗口已被遮挡或关闭，可手动滚动")
                    return
                }
                if waitingForPointer {
                    waitingForPointer = false
                    preview.updateStatus("正在自动滚动；移开鼠标可点暂停或完成")
                    Log.shared.info("长截图：使用当前鼠标位置向正文发送滚轮事件")
                }
                let start = ProcessInfo.processInfo.systemUptime
                let grew = try await policy.scrollAndStitch(post: {
                    // Use the proven system input route only while the pointer is still over
                    // the original window. A move immediately stops the remaining wheel pulses.
                    guard let event = Self.automaticWheel($0, source: eventSource),
                          let current = CGEvent(source: nil)?.location, current == pointer,
                          !self.preview.isUnderPointer(at: current, desktopTop: desktopTop) else { return false }
                    event.location = current
                    event.post(tap: .cghidEventTap)
                    return true
                }) { after in
                    let image: CGImage
                    if let frame = latestAutomaticFrame, frame.timestamp >= after,
                       let cropped = Self.cropFrame(frame.image, rect: rect, screen: screen) {
                        image = cropped
                    } else {
                        // ScreenCaptureKit can stop delivering complete frames on a static page.
                        image = try await captureFrame(rect: rect, screen: screen)
                    }
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation { continuation in
                        append(image, sessionID: id) { continuation.resume(with: $0) }
                    }
                }
                try Task.checkCancellation()
                guard let grew else {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                stationarySteps = grew ? 0 : stationarySteps + 1
                if stationarySteps >= 3 {
                    pauseAutomaticScroll(message: "画面不再移动，已暂停自动滚动；可点完成")
                    return
                }
                let remaining = policy.interval - (ProcessInfo.processInfo.systemUptime - start)
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            }
        } catch {
            guard !Task.isCancelled, sessionID == id, state == .capturing else { return }
            if error is StitchingError {
                pauseAutomaticScroll(message: nil)
                reportStitchingError(error, automatic: true)
            } else {
                pauseAutomaticScroll(message: "抓帧失败，已暂停自动滚动")
            }
        }
    }

    private static func isAutomaticWheel(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == automaticEventTag ||
            event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier)
    }

    struct ScrollTarget: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
    }

    private static func scrollTargetWindow(at point: CGPoint, expectedProcess: pid_t?) -> ScrollTarget? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        return scrollTargetWindow(in: windows, at: point, expectedProcess: expectedProcess,
                                  ownProcess: ProcessInfo.processInfo.processIdentifier)
    }

    static func scrollTargetWindow(in windows: [[String: Any]], at point: CGPoint,
                                   expectedProcess: pid_t?, ownProcess: pid_t) -> ScrollTarget? {
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid > 0, pid != ownProcess,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            // A different application covering the selection must not receive our scroll.
            return expectedProcess == nil || expectedProcess == pid ? ScrollTarget(pid: pid, windowID: windowID) : nil
        }
        return nil
    }

    static func automaticWheel(_ delta: Int32, source: CGEventSource) -> CGEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0) else { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: Self.automaticEventTag)
        return event
    }

    private func captureFrame(rect: CGRect, screen: ScreenDescriptor) async throws -> CGImage {
        let frame = try await environment.capture.capture(screen: screen,
            options: .init(excludingCurrentApplication: true,
                hideDesktopIcons: environment.config.settings.capture.hideDesktopIcons))
        guard let cropped = Self.cropFrame(frame.image, rect: rect, screen: screen) else {
            throw CaptureError.captureFailed(underlying: nil)
        }
        return cropped
    }

    private func pauseAutomaticScroll(message: String?) {
        guard automaticRequested else { return }
        automaticRequested = false
        automaticStartPending = false
        if probingAutomatically {
            regionRequestID = UUID()
            resolvingRegion = false
            probingAutomatically = false
        }
        automaticTask?.cancel()
        automaticTask = nil
        latestAutomaticFrame = nil
        preview.setAutomaticScroll(false)
        if let message {
            preview.updateStatus(message)
            Log.shared.info("长截图：\(message)")
        }
    }

    func finish() {
        guard state == .capturing else { return }
        let finalRect = layoutReady ? selectionRect : nil
        state = .finishing
        stopRegionSelection()
        let id = sessionID
        preview.setFinishing()
        streamer?.stop()
        streamer = nil
        Task { @MainActor in
            // Drain the last visible scroll before finalizing, including a step already posted by auto-scroll.
            var lastFrame: CGImage?
            if let finalRect, let screen {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard sessionID == id, state == .finishing else { return }
                lastFrame = try? await captureFrame(rect: finalRect, screen: screen)
            }
            guard sessionID == id, state == .finishing else { return }
            let finalFrame = lastFrame
            stitchingQueue.async { [weak self] in
                guard let self else { return }
                var finalFrameRejected = false
                if let finalFrame {
                    do { _ = try self.stitcher.append(finalFrame) }
                    catch { finalFrameRejected = true }
                }
                let image = try? self.stitcher.finish()
                let rejected = finalFrameRejected
                DispatchQueue.main.async {
                    guard self.sessionID == id, self.state == .finishing else { return }
                    guard let image else {
                        self.cancel()
                        self.environment.toast.warning("没有拼接出内容")
                        return
                    }
                    self.presentResult(image)
                    Log.shared.info("长截图完成：\(image.width)×\(image.height)")
                    if rejected { self.environment.toast.warning("最后一帧无法可靠拼接，已保留此前完整内容") }
                }
            }
        }
    }

    func cancel() {
        sessionID = UUID()
        state = .idle
        stopRegionSelection()
        processingFrame = false
        selectionRect = nil
        screen = nil
        privacyEditor?.privacy.cancel()
        privacyEditor = nil
        forcePrivacy = false
        preview.close()
        streamer?.stop()
        streamer = nil
        stitchingQueue.async { [stitcher] in stitcher.reset() }
    }

    // MARK: - 结果处理

    private func presentResult(_ image: CGImage) {
        state = .result
        let scale = screen?.scale ?? 1
        let document = EditDocument(baseImage: image, scale: scale, sourceTopLeft: selectionRect?.origin)
        let editor = EditController(environment: environment, image: image, scale: scale,
                                    style: environment.defaultEditStyle, scrollsLongImage: true, restoring: document)
        privacyEditor = editor
        if forcePrivacy || environment.config.settings.privacy.enabled { editor.scanPrivacy() }
        preview.showResult(image, actions: [
            ("贴图", { [weak self] in
                guard let self, let editor = self.privacyEditor, let output = editor.renderedImage() else { return }
                self.environment.pinGroups.show(output, from: editor.outputTopLeft, scale: scale)
                self.cancel()
            }),
            ("复制", { [weak self] in
                guard let self, let editor = self.privacyEditor, let output = editor.renderedImage() else { return }
                self.environment.pinTransfer.copy(output, scale: scale, sourceTopLeft: editor.outputTopLeft,
                                                  kind: .longShot, successMessage: "已复制长图")
            }),
            ("保存", { [weak self] in
                guard let self, let output = self.privacyEditor?.renderedImage() else { return }
                self.save(output)
            }),
        ], privacyEditor: editor, onEdit: { [weak self] in
            guard let self, self.state == .result, let editor = self.privacyEditor else { return }
            // 同一个编辑文档交给编辑器，保留已加的遮盖和正在进行的扫描。
            self.privacyEditor = nil
            self.cancel()
            self.environment.presentEditor(editor)
        }, onClose: { [weak self] in
            self?.cancel()
        })
    }

    private func save(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(ImageCodec.defaultFileName()).png"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try ImageCodec.encode(image, as: .png)
            try data.write(to: url, options: .atomic)
            environment.toast.success("已保存 \(url.lastPathComponent)")
        } catch {
            environment.toast.error("保存失败：\(error)")
        }
    }
}

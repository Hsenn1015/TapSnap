import AppKit
import Foundation
import TapSnapActionsBar
import TapSnapConfig
import TapSnapCore
import TapSnapScreen
import TapSnapTheme
import TapSnapVision

/// 截图流程编排：抓屏 -> 每屏盖一层覆盖层 -> 等用户框选 -> 按用途分发。
final class CaptureCoordinator {
    /// 框选完之后把图交给谁。
    enum Outcome: String, Codable {
        /// 进编辑窗口
        case edit
        /// 极速截图：松手即按默认设置输出（复制/保存），开启隐私检查时仍进入复核
        case quickCapture
        /// 仅复制当前选区
        case copy
        /// 按默认输出设置完成（复制、保存或保存并复制）
        case quickComplete
        /// 直接贴到屏幕上
        case pin
        /// 保存当前选区
        case save
        /// 交给文字识别
        case ocr
        /// 极速取字：松手静默识别并复制，不弹结果窗、不抢焦点
        case quickOCR
        /// 交给表格识别
        case table
        case translate
        /// 截图秒译：松手直接弹出轻量悬停译文卡，不跳大窗
        case quickTranslate
        case formula
        /// 交给滚动长截图
        case longShot
        /// 交给录屏
        case record
    }

    private let environment: AppEnvironment
    private var outcome: Outcome = .edit
    private var session: ScreenshotSession?
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var overlayViews: [SelectionOverlayView] = []
    private var sessionWindows: [VisibleWindow] = []
    private var isPreparingHandoff = false
    private var shutterSound: NSSound?
    private var forcePrivacy = false

    @MainActor
    var isCaptureActive: Bool { session != nil }

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func start(_ outcome: Outcome, mode: ScreenshotSession.Mode = .region,
               outputOptions: ScreenshotOutputOptions? = nil, forcePrivacy: Bool = false) {
        guard session == nil else { return }
        self.outcome = outcome
        self.forcePrivacy = forcePrivacy
        if outcome == .quickTranslate || outcome == .translate {
            // 框选期间并发预热翻译服务 DNS + TLS 连接，消除松手后的冷连接等待。
            TranslationModelClient.prewarm(config: environment.config)
        }
        let pendingSession = ScreenshotSession(mode: mode, outputOptions: outputOptions)
        let pointerScreenID = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        session = pendingSession
        let id = pendingSession.id

        Task { @MainActor in
            do {
                let allowSelfCapture = environment.config.settings.capture.allowSelfCapture
                let excludedWindowIDs = allowSelfCapture
                    ? [environment.record.borderWindowID].compactMap { $0 }
                    : [environment.record.borderWindowID, environment.toastPresenter.windowID].compactMap { $0 }
                let frames = try await environment.capture.captureAllScreens(options: .init(
                    excludingCurrentApplication: outcome == .longShot,
                    excludedWindowIDs: excludedWindowIDs,
                    hideDesktopIcons: environment.config.settings.capture.hideDesktopIcons
                ))
                guard session?.id == id else { return }
                session?.frames = frames
                if mode == .fullScreen, var capture = session,
                   let frame = frames.first(where: { $0.screen.id == pointerScreenID?.uint32Value }) ?? frames.first {
                    capture.targetScreen = frame.screen
                    capture.selectionRect = frame.screen.frame
                    complete(capture, outcome: outcome)
                } else {
                    presentOverlays()
                }
            } catch {
                guard session?.id == id else { return }
                session = nil
                handleCaptureFailure(error, resuming: .init(outcome: outcome, mode: mode,
                    options: outputOptions, forcePrivacy: forcePrivacy))
            }
        }
    }

    @MainActor
    private func handleCaptureFailure(_ error: Error, resuming capture: PendingScreenCapture) {
        guard !environment.guideScreenCapturePermission(for: error, resuming: capture) else { return }
        environment.toast.error("截图失败：\(error.localizedDescription)")
    }

    private func presentOverlays() {
        guard let id = session?.id else { return }
        let screens = session?.frames.map(\.screen) ?? []
        guard !screens.isEmpty else {
            session = nil
            environment.toast.error("没有检测到屏幕")
            return
        }

        // 在覆盖层出现前记住真实窗口顺序，界面检测慢时也能立即给出窗口选区。
        let windows = Self.visibleWindows(excludingCurrentApplication: outcome == .longShot)
        sessionWindows = windows
        let captureSettings = environment.config.settings.capture
        for screen in screens {
            let window = SelectionOverlayWindow(screen: screen)
            let view = SelectionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.screenImage = session?.frame(for: screen)?.image
            view.showsFrozenSelection = outcome == .edit || outcome == .pin || outcome == .quickCapture
            view.selectsWindows = session?.mode == .window
            if screens.count > 1, !view.selectsWindows, outcome != .longShot, outcome != .record,
               let desktop = Geometry.boundingBox(of: screens.map(\.frame)) {
                func local(_ rect: CGRect, on display: ScreenDescriptor) -> CGRect {
                    CGRect(x: rect.minX - display.frame.minX, y: display.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
                }
                view.desktopDragBounds = local(desktop, on: screen)
                view.onSelectionChange = { [weak self] selection, pointer, dragging in
                    guard let self, self.session?.id == id else { return }
                    let global = selection.map {
                        CGRect(x: screen.frame.minX + $0.minX, y: screen.frame.maxY - $0.maxY, width: $0.width, height: $0.height)
                    }
                    let cursor = CGPoint(x: screen.frame.minX + pointer.x, y: screen.frame.maxY - pointer.y)
                    let toolbarIndex = screens.firstIndex { $0.frame.contains(cursor) }
                    let scale = global.flatMap { rect in screens.filter { $0.frame.intersects(rect) }.map(\.scale).max() }
                    for (i, peer) in self.overlayViews.enumerated() {
                        peer.selectionScale = scale
                        let rect = global.flatMap { area in
                            screens[i].id == screen.id || !area.intersection(screens[i].frame).isEmpty
                                ? local(area, on: screens[i]) : nil
                        }
                        peer.synchronizeSelection(rect, showToolbar: !dragging && (toolbarIndex.map { $0 == i } ?? (screens[i].id == screen.id)),
                                                  dragging: dragging)
                    }
                }
            }
            view.windowRegions = windows.compactMap { Self.viewRect(for: $0.bounds, on: screen) }
            if !view.selectsWindows {
                view.accessibilitySnapLookup = { point in
                    let global = CGPoint(x: screen.frame.minX + point.x, y: screen.frame.maxY - point.y)
                    guard let front = windows.first(where: { $0.bounds.contains(global) }),
                          let processID = front.processID,
                          let target = SelectionAccessibilityTarget.frame(at: global, in: front.bounds, processID: processID)
                    else { return nil }
                    return Self.viewRect(for: target, on: screen)
                }
            }
            view.borderConfiguration = captureSettings.selectionBorderConfiguration
            view.showsMagnifier = captureSettings.showMagnifier
            view.showsSizeLabel = captureSettings.showSelectionSize
            view.config = environment.config
            if outcome == .quickOCR {
                view.confirmsOnRelease = true
                view.showsMagnifier = false
            }
            if outcome == .quickCapture {
                view.confirmsOnRelease = true
            }
            if outcome == .edit, let last = captureSettings.lastSelection {
                view.lastSelectionRect = Self.viewRect(for: last, on: screen)
            }
            if outcome == .quickTranslate {
                let translationSettings = environment.config.settings.translation
                view.quickTranslateStyle = translationSettings.quickTranslateStyle
                view.quickTranslateTargetLanguage = Self.quickTranslateLanguageName(for: translationSettings.targetLanguage)
                view.showsMagnifier = false
                view.onCycleQuickTranslateLanguage = { [weak self] in
                    guard let self else { return "简体中文" }
                    let nextCode = Self.nextQuickTranslateLanguage(after: self.environment.config.settings.translation.targetLanguage)
                    self.environment.config.update { $0.translation.targetLanguage = nextCode }
                    let label = Self.quickTranslateLanguageName(for: nextCode)
                    for peer in self.overlayViews {
                        peer.quickTranslateTargetLanguage = label
                    }
                    return label
                }
            }
            view.onFinish = { [weak self] rect in
                self?.finish(rect: rect, screen: screen, sessionID: id)
            }
            if outcome == .edit {
                let autoCopy = captureSettings.autoCopyToClipboard
                let autoSave = session?.outputOptions?.autoSave ?? captureSettings.autoSaveToFile
                let completesOnConfirm = session?.outputOptions == nil && !forcePrivacy && (autoCopy || autoSave)
                view.quickConfirmationCopies = completesOnConfirm
                view.quickConfirmationAction = autoSave ? .confirm : .copy
                if completesOnConfirm {
                    view.confirmationTitle = Self.quickConfirmationTitle(
                        autoCopy: autoCopy,
                        autoSave: autoSave,
                        privacyEnabled: environment.config.settings.privacy.enabled,
                        settings: environment.config.settings
                    )
                } else {
                    view.confirmationTitle = "编辑 ⏎"
                }
                view.quickToolbarTheme = environment.theme
                view.quickToolbarToolTip = { [config = environment.config] action in
                    ActionsBarModel().toolTip(for: action, config: config)
                }
                view.onQuickAction = { [weak self] action, rect in
                    self?.finish(action: action, rect: rect, screen: screen, sessionID: id)
                }
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            overlayWindows.append(window)
            overlayViews.append(view)
            view.previewSnap(at: view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }

        if session?.mode != .window { detectSnapRegions() }
    }

    /// 后台检测图像边界，补足窗口和辅助功能没提供的区域。
    ///
    /// Vision 在整屏图上要几百毫秒，所以不挡框选：用户先画着，检测完再挂上去。
    private func detectSnapRegions() {
        for view in overlayViews {
            guard let image = view.screenImage else { continue }
            let size = view.bounds.size
            Task { @MainActor [weak view] in
                let regions = await Task.detached(priority: .userInitiated) {
                    UIRegionDetector().detectRegions(in: image)
                }.value
                guard !regions.isEmpty, let view, view.window?.isVisible == true else { return }
                view.snapRegions = regions.map { region in
                    let bounds = CGRect(
                        x: region.bounds.minX * size.width,
                        y: region.bounds.minY * size.height,
                        width: region.bounds.width * size.width,
                        height: region.bounds.height * size.height
                    )
                    return SelectionSnapRegion(bounds: bounds, confidence: region.confidence)
                }
            }
        }
    }

    private func dismissOverlays(afterPin: Bool = false) {
        overlayViews.forEach { $0.stopBorderAnimation() }
        for window in overlayWindows {
            if afterPin { window.animationBehavior = .none }
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        overlayViews.removeAll()
    }

    private func finish(action: ActionKind, rect: CGRect, screen: ScreenDescriptor, sessionID: UUID) {
        let destination: Outcome
        switch action {
        case .edit:
            finish(rect: rect, screen: screen, sessionID: sessionID, switchingTo: .edit)
            return
        case .confirm: destination = .quickComplete
        case .copy: destination = .copy
        case .pin: destination = .pin
        case .save: destination = .save
        case .ocr: destination = .ocr
        case .translate: destination = .translate
        case .formula: destination = .formula
        case .tableRecognize: destination = .table
        case .longShot: destination = .longShot
        case .record: destination = .record
        case .crop, .print, .qrCode: destination = .edit
        default:
            guard action.isAnnotationTool else { return }
            destination = .edit
        }
        finish(rect: rect, screen: screen, sessionID: sessionID, switchingTo: destination,
               initialAction: destination == .edit ? action : nil)
    }

    private func finish(rect: CGRect?, screen: ScreenDescriptor, sessionID id: UUID,
                        switchingTo requestedOutcome: Outcome? = nil, initialAction: ActionKind? = nil) {
        guard session?.id == id, !isPreparingHandoff else { return }
        guard let rect, var session else {
            cancel()
            return
        }

        session.select(viewRect: rect, on: screen)
        let selectedOutcome = requestedOutcome ?? outcome
        if selectedOutcome == .pin {
            complete(session, outcome: .pin)
            return
        }
        let needsCleanFrame = selectedOutcome == .longShot && outcome != .longShot
        isPreparingHandoff = true
        Task { @MainActor in
            // 留一帧让松手与处理中状态上屏，避免刚点完就突然切走。
            if selectedOutcome != .copy, selectedOutcome != .quickComplete, selectedOutcome != .quickCapture,
               selectedOutcome != .quickOCR, selectedOutcome != .quickTranslate,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try? await Task.sleep(for: .milliseconds(65))
            }
            guard self.session?.id == id, isPreparingHandoff else { return }
            if needsCleanFrame {
                dismissOverlays()
                do {
                    let frame = try await environment.capture.capture(screen: screen,
                                                                     options: .init(excludingCurrentApplication: true,
                                                                                    hideDesktopIcons: environment.config.settings.capture.hideDesktopIcons))
                    guard self.session?.id == id else { return }
                    session.frames = [frame]
                } catch {
                    guard self.session?.id == id else { return }
                    let shouldReviewPrivacy = forcePrivacy
                    cancel()
                    handleCaptureFailure(error, resuming: .init(outcome: selectedOutcome,
                        options: session.outputOptions, forcePrivacy: shouldReviewPrivacy,
                        rect: session.selectionRect, displayID: screen.id))
                    return
                }
            }
            complete(session, outcome: selectedOutcome, initialAction: initialAction)
        }
    }

    private func complete(_ session: ScreenshotSession, outcome: Outcome, initialAction: ActionKind? = nil) {
        guard let globalRect = session.selectionRect, let screen = session.targetScreen else { return }
        let cropped = session.croppedImage()
        let windows = sessionWindows.isEmpty ? Self.visibleWindows(excludingCurrentApplication: true) : sessionWindows
        let sourceAppName = Self.sourceAppName(for: globalRect, among: windows)
        let forcePrivacy = self.forcePrivacy
        self.forcePrivacy = false
        self.session = nil
        self.sessionWindows = []
        isPreparingHandoff = false

        guard let cropped else {
            dismissOverlays()
            environment.toast.error("没有可用的屏幕帧")
            return
        }

        // 原位贴图及其隐私复查窗口先就位，再撤掉上方的框选层。
        if outcome != .pin { dismissOverlays() }
        // 最近选区落盘和快门音不阻塞截图交接。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.environment.config.update { $0.capture.lastSelection = globalRect }
            self.playShutterIfNeeded(for: outcome)
        }
        let checksPrivacy = forcePrivacy || environment.config.settings.privacy.enabled
        let document = EditDocument(baseImage: cropped, scale: session.outputScale,
                                    capturedAt: session.frame(for: screen)?.timestamp ?? session.startedAt,
                                    sourceTopLeft: globalRect.origin.rounded(to: session.outputScale),
                                    sourceAppName: sourceAppName)
        if outcome != .longShot && outcome != .record {
            environment.rememberCapture(document, privateCapture: checksPrivacy)
        }
        // 打印和二维码识别由编辑器执行。需要检查时，把它们留给复核后的确认操作。
        let editorExport = initialAction.flatMap { $0.exportsImage ? $0 : nil }
        let reviewedAction = checksPrivacy ? Self.reviewedAction(for: outcome) ?? editorExport : nil
        if outcome == .edit || reviewedAction != nil {
            environment.openEditor(image: cropped, scale: document.scale, captureRect: globalRect, captureScreen: screen,
                                   outputOptions: outcome == .edit || outcome == .save ? session.outputOptions : nil,
                                   forcePrivacy: forcePrivacy, reviewedAction: reviewedAction,
                                   initialAction: reviewedAction == nil ? initialAction : nil, restoring: document)
            if outcome == .pin { dismissOverlays(afterPin: true) }
            return
        }
        switch outcome {
        case .edit:
            break
        case .copy:
            environment.pinTransfer.copy(cropped, scale: document.scale, sourceTopLeft: document.sourceTopLeft)
        case .quickComplete, .quickCapture:
            if !environment.completeScreenshotOutputs(
                cropped,
                scale: document.scale,
                sourceTopLeft: document.sourceTopLeft,
                sourceAppName: document.sourceAppName,
                formatOverride: session.outputOptions?.format,
                autoSaveOverride: session.outputOptions?.autoSave
            ) {
                environment.openEditor(image: cropped, scale: document.scale, captureRect: globalRect, captureScreen: screen,
                                       outputOptions: session.outputOptions, restoring: document)
            }
        case .pin:
            environment.pinGroups.show(cropped, from: document.sourceTopLeft, scale: document.scale) {
                self.dismissOverlays(afterPin: true)
            }
        case .save:
            if !environment.saveScreenshot(cropped, formatOverride: session.outputOptions?.format,
                                           chooseLocation: true, sourceAppName: document.sourceAppName) {
                environment.openEditor(image: cropped, scale: document.scale, captureRect: globalRect, captureScreen: screen,
                                       outputOptions: session.outputOptions, restoring: document)
            }
        case .ocr:
            environment.ocrCoordinator.recognize(cropped)
        case .quickOCR:
            environment.ocrCoordinator.recognizeSilently(cropped)
        case .translate:
            environment.translateImage(cropped, captureRect: globalRect)
        case .quickTranslate:
            environment.quickTranslateImage(cropped, captureRect: globalRect)
        case .formula:
            environment.recognizeFormula(cropped)
        case .table:
            environment.tableRecognizer.recognize(cropped)
        case .longShot:
            environment.longShot.beginCapturing(rect: globalRect, screen: screen, initialImage: cropped,
                                                forcePrivacy: forcePrivacy)
        case .record:
            environment.record.start(rect: Geometry.localRect(globalRect, in: screen.frame), screen: screen)
        }
    }

    private func playShutterIfNeeded(for outcome: Outcome) {
        if outcome != .longShot, outcome != .record, environment.config.settings.capture.playShutterSound {
            if shutterSound == nil {
                shutterSound = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif", byReference: true)
                    ?? NSSound(named: "Tink")
            }
            shutterSound?.play()
        }
    }

    static func quickConfirmationTitle(
        autoCopy: Bool,
        autoSave: Bool,
        privacyEnabled: Bool,
        settings: Settings
    ) -> String {
        if autoSave && autoCopy {
            return privacyEnabled ? "检查后保存并复制" : "保存并复制"
        }
        if autoSave {
            return privacyEnabled ? "检查后保存" : "保存"
        }
        let title = privacyEnabled ? "检查后复制" : "复制"
        return OperationShortcut.action(.copy).displayTitle(in: settings, title: title)
    }

    static func reviewedAction(for outcome: Outcome) -> ActionKind? {
        switch outcome {
        case .copy: return .copy
        case .quickComplete, .quickCapture: return .confirm
        case .pin: return .pin
        case .save: return .save
        case .ocr: return .ocr
        case .translate: return .translate
        case .formula: return .formula
        case .table: return .tableRecognize
        default: return nil
        }
    }

    /// 编辑器关闭后复用原选区，并重新抓取干净首帧。
    func startFromEditor(_ outcome: Outcome, rect: CGRect?, screen: ScreenDescriptor?,
                         outputOptions: ScreenshotOutputOptions? = nil, forcePrivacy: Bool = false) {
        guard let rect, let previousScreen = screen else { start(outcome, outputOptions: outputOptions, forcePrivacy: forcePrivacy); return }
        guard let screen = ScreenLayout.current().first(where: { $0.id == previousScreen.id }) else {
            environment.toast.warning("原屏幕已断开，请重新框选")
            start(outcome, outputOptions: outputOptions, forcePrivacy: forcePrivacy)
            return
        }
        guard session == nil else { return }
        if !screen.frame.contains(rect), ScreenLayout.current().contains(where: { $0.id != screen.id && $0.frame.intersects(rect) }) {
            environment.toast.info("请在一块屏幕内选择滚动或录制区域")
            start(outcome, outputOptions: outputOptions, forcePrivacy: forcePrivacy)
            return
        }
        let clipped = rect.intersection(screen.frame)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else {
            environment.toast.warning("原选区已不在当前屏幕，请重新框选")
            start(outcome, outputOptions: outputOptions, forcePrivacy: forcePrivacy)
            return
        }
        var pending = ScreenshotSession(mode: .region, outputOptions: outputOptions)
        pending.selectionRect = clipped
        pending.targetScreen = screen
        session = pending
        self.forcePrivacy = forcePrivacy
        Task { @MainActor in
            do {
                let frame = try await environment.capture.capture(screen: screen,
                    options: .init(excludingCurrentApplication: !environment.config.settings.capture.allowSelfCapture,
                                   hideDesktopIcons: environment.config.settings.capture.hideDesktopIcons))
                guard session?.id == pending.id else { return }
                pending.frames = [frame]
                complete(pending, outcome: outcome)
            } catch {
                guard session?.id == pending.id else { return }
                cancel()
                handleCaptureFailure(error, resuming: .init(outcome: outcome,
                    options: outputOptions, forcePrivacy: forcePrivacy, rect: clipped, displayID: screen.id))
            }
        }
    }

    /// 直接按上一次确认的选区重新截一张，便于界面改动前后像素级对齐对比。
    func recaptureLastSelection() {
        guard let last = environment.config.settings.capture.lastSelection,
              last.width >= 2, last.height >= 2 else {
            environment.toast.info("还没有上次截图区域")
            return
        }
        let screens = ScreenLayout.current()
        let intersecting = screens.filter { !$0.frame.intersection(last).isEmpty }
        guard let primary = screens.first(where: { $0.frame.contains(last) }) ?? intersecting.first else {
            environment.toast.warning("上次选区不在当前屏幕，请重新框选")
            start(.edit)
            return
        }
        if primary.frame.contains(last) {
            startFromEditor(.edit, rect: last, screen: primary)
            return
        }
        guard session == nil else { return }
        var pending = ScreenshotSession(mode: .region)
        pending.selectionRect = last
        pending.targetScreen = primary
        session = pending
        Task { @MainActor in
            do {
                let allowSelfCapture = environment.config.settings.capture.allowSelfCapture
                let excludedWindowIDs = allowSelfCapture
                    ? [environment.record.borderWindowID].compactMap { $0 }
                    : [environment.record.borderWindowID, environment.toastPresenter.windowID].compactMap { $0 }
                let frames = try await environment.capture.captureAllScreens(options: .init(
                    excludingCurrentApplication: false,
                    excludedWindowIDs: excludedWindowIDs,
                    hideDesktopIcons: environment.config.settings.capture.hideDesktopIcons
                ))
                guard session?.id == pending.id else { return }
                pending.frames = frames
                complete(pending, outcome: .edit)
            } catch {
                guard session?.id == pending.id else { return }
                cancel()
                handleCaptureFailure(error, resuming: .init(outcome: .edit, rect: last, displayID: primary.id))
            }
        }
    }

    func startPreset(_ preset: ScreenshotPreset) {
        let options = ScreenshotOutputOptions(format: preset.format, autoSave: preset.autoSave)
        guard let rect = preset.rect else { start(.edit, outputOptions: options); return }
        let screens = ScreenLayout.current()
        guard let screen = Self.screen(for: preset, among: screens), screen.frame.contains(rect),
              rect.width >= 2, rect.height >= 2 else {
            environment.toast.warning("预设区域不在当前屏幕，请重新框选；本次输出格式仍沿用预设")
            start(.edit, outputOptions: options)
            return
        }
        startFromEditor(.edit, rect: rect, screen: screen, outputOptions: options)
    }

    static func screen(for preset: ScreenshotPreset, among screens: [ScreenDescriptor]) -> ScreenDescriptor? {
        if let id = preset.screenID { return screens.first { $0.id == id } }
        if let rect = preset.rect { return screens.first { $0.frame.contains(rect) } }
        return nil
    }

    private struct VisibleWindow: Sendable {
        let bounds: CGRect
        let processID: pid_t?
        let ownerName: String?
    }

    private static func sourceAppName(for rect: CGRect, among windows: [VisibleWindow]) -> String? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = windows.first(where: { $0.bounds.contains(center) && ($0.ownerName?.isEmpty == false) }) {
            return hit.ownerName
        }
        return windows.first(where: { !$0.bounds.intersection(rect).isEmpty && ($0.ownerName?.isEmpty == false) })?.ownerName
    }

    private static func viewRect(for rect: CGRect, on screen: ScreenDescriptor) -> CGRect? {
        let visible = rect.intersection(screen.frame)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        return Geometry.localRect(visible, in: screen.frame)
            .flippedVertically(in: CGRect(origin: .zero, size: screen.frame.size))
    }

    /// 按系统窗口的前后顺序保留真实边界和所属应用。
    private static func visibleWindows(excludingCurrentApplication: Bool) -> [VisibleWindow] {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return entries.compactMap { entry in
            let processID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  !excludingCurrentApplication || processID != currentPID,
                  let raw = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  rect.width > 2, rect.height > 2 else { return nil }
            let ownerName = entry[kCGWindowOwnerName as String] as? String
            return VisibleWindow(bounds: rect, processID: processID, ownerName: ownerName)
        }
    }

    static let quickTranslateCycleLanguages = ["zh-Hans", "en", "ja", "ko"]

    static func nextQuickTranslateLanguage(after current: String) -> String {
        guard let index = quickTranslateCycleLanguages.firstIndex(of: current) else {
            return quickTranslateCycleLanguages[0]
        }
        return quickTranslateCycleLanguages[(index + 1) % quickTranslateCycleLanguages.count]
    }

    static func quickTranslateLanguageName(for code: String) -> String {
        switch code {
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "de": return "德语"
        case "es": return "西班牙语"
        default: return code
        }
    }

    func cancel() {
        dismissOverlays()
        session = nil
        sessionWindows = []
        isPreparingHandoff = false
        forcePrivacy = false
    }
}

import AppKit
import Combine
import Foundation
import TapSnapActionsBar
import TapSnapConfig
import TapSnapCore
import TapSnapImageIO
import TapSnapOCR
import TapSnapPalette
import TapSnapScreen
import TapSnapStitching
import TapSnapSystem
import TapSnapTheme
import TapSnapToast
import SwiftUI
import UniformTypeIdentifiers

/// 依赖容器。
///
/// 集中创建应用依赖并传给各控制器，便于测试时替换。
///
/// 常驻控制器（截图、长截图、录制、识别）也挂在环境上：它们的生命周期要跨过
/// 一次菜单点击，交给调用方临时创建会被立刻释放。
final class AppEnvironment {
    let config: ConfigStore
    let palette: ColorPaletteStore
    let toast: ToastCenter
    let capture: ScreenCaptureService
    let ocr: OCRService
    let stitcher: FrameStitcher
    let pinGroups: PinGroupManager
    private let selectScreenshotFile: (ImageFormat, URL) -> URL?

    @MainActor lazy var toastPresenter = ToastPresenter(center: toast, theme: { [weak self] in self?.theme ?? .dark })
    lazy var captureCoordinator = CaptureCoordinator(environment: self)
    lazy var longShot = LongShotSession(environment: self)
    lazy var record = RecordController(environment: self)
    lazy var ocrCoordinator = OCRCoordinator(environment: self)
    lazy var screenshotPresets = ScreenshotPresetsPanel(environment: self)
    lazy var desktopBar = DesktopBarController(config: config)
    lazy var tutorial = TutorialWindowController(theme: { [unowned self] in self.theme }, config: config)
    lazy var translationPanel = TranslationPanel()
    lazy var formulaPanel = FormulaPanel(theme: { [weak self] in self?.theme ?? .dark })
    lazy var tableRecognizer = TableRecognizer(environment: self)
    lazy var pinTransfer = PinTransfer(environment: self)
    lazy var shortcutCenter = ShortcutCenter(environment: self)

    let clipboardHistory = ClipboardHistory()
    lazy var clipboardPanel = ClipboardHistoryPanel(
        history: clipboardHistory,
        theme: { [unowned self] in self.theme },
        editImage: { [unowned self] image in self.openEditor(image: image, scale: 1) }
    )
    lazy var pinGroupsPanel = PinGroupsPanel(
        groups: pinGroups,
        theme: { [unowned self] in self.theme }
    )
    lazy var ocrResultPanel = OCRResultPanel(theme: { [unowned self] in self.theme })

    /// 当前打开的编辑窗口（关掉后置 nil）。
    private var editor: EditController?
    private(set) var recentScreenshot: EditDocument?
    private var recentSourceID: UUID?
    private var settingsWindow: NSWindow?
    private var settingsAppearanceObservation: AnyCancellable?

    @MainActor
    var isUpdateInteractionBusy: Bool {
        editor != nil || captureCoordinator.isCaptureActive || record.isRecordingOrEditing || longShot.hasActiveSession
    }

    init(config: ConfigStore = .shared,
         selectScreenshotFile: @escaping (ImageFormat, URL) -> URL? = AppEnvironment.showSavePanel) {
        self.config = config
        self.selectScreenshotFile = selectScreenshotFile
        self.palette = ColorPaletteStore()
        self.toast = ToastCenter.shared
        self.capture = ScreenCaptureService()
        self.ocr = OCRService()
        self.stitcher = FrameStitcher()
        self.pinGroups = PinGroupManager(config: config)
    }

    var theme: Theme {
        config.settings.appearance.useDarkTheme ? .dark : .light
    }

    func openSettings(section: SettingsSection? = nil) {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
            if let section {
                window.contentViewController = NSHostingController(rootView: SettingsView(environment: self, section: section))
            }
        } else {
            let hosting = NSHostingController(rootView: SettingsView(environment: self, section: section ?? .general))
            window = NSWindow(contentViewController: hosting)
            window.title = "TapSnap 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            settingsAppearanceObservation = config.$settings
                .map(\.appearance.useDarkTheme)
                .removeDuplicates()
                .sink { [weak window] isDark in
                    window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                }
            hosting.view.layoutSubtreeIfNeeded()
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                let content = CGRect(origin: .zero, size: hosting.view.fittingSize)
                let size = window.frameRect(forContentRect: content).size
                window.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
            }
            settingsWindow = window
        }
        // The long-shot preview is a floating panel.
        window.level = section == .privacy && NSApp.keyWindow?.level == .floating ? .floating : .normal
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 按设置里的标注默认值生成样式。
    var defaultEditStyle: EditItemStyle {
        let annotate = config.settings.annotate
        return EditItemStyle(
            color: RGBAColor(hex: annotate.defaultColorHex) ?? RGBAColor(rgb: 0xFF3B30),
            lineWidth: annotate.defaultLineWidth,
            fontSize: annotate.defaultFontSize
        )
    }

    func openEditor(image: CGImage, scale: CGFloat, captureRect: CGRect? = nil, captureScreen: ScreenDescriptor? = nil,
                    outputOptions: ScreenshotOutputOptions? = nil, forcePrivacy: Bool = false, reviewedAction: ActionKind? = nil,
                    initialAction: ActionKind? = nil, restoring document: EditDocument? = nil) {
        let requiresPrivacyReview = forcePrivacy || config.settings.privacy.enabled || reviewedAction == .copy || reviewedAction == .save
            || reviewedAction == .print || reviewedAction == .qrCode
        let controller = EditController(
            environment: self,
            image: image,
            scale: scale,
            style: defaultEditStyle,
            captureRect: captureRect,
            captureScreen: captureScreen,
            outputOptions: outputOptions,
            scanPrivacyOnOpen: forcePrivacy || config.settings.privacy.enabled,
            requiresPrivacyReview: requiresPrivacyReview,
            reviewedAction: reviewedAction, restoring: document
        )
        presentEditor(controller, initialAction: initialAction)
    }

    func rememberCapture(_ document: EditDocument, privateCapture: Bool) {
        recentSourceID = document.id
        recentScreenshot = privateCapture ? nil : document
    }

    func protectOriginal(_ document: EditDocument) {
        if recentSourceID == document.id { recentScreenshot = nil }
    }

    func rememberReviewedImage(_ image: CGImage, from document: EditDocument) {
        guard recentSourceID == document.id, recentScreenshot !== document else { return }
        recentScreenshot = EditDocument(baseImage: image, scale: document.scale, capturedAt: document.capturedAt)
    }

    func editRecentScreenshot() {
        guard let document = recentScreenshot else { toast.info("还没有可编辑的最近截图"); return }
        if editor?.document === document { editor?.bringForward(); return }
        recentSourceID = document.id
        openEditor(image: document.baseImage, scale: document.scale, restoring: document)
    }

    func editImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { openEditor(image: try ImageCodec.decode(Data(contentsOf: url)), scale: 1) }
        catch { toast.error("无法打开图片：\(error.localizedDescription)") }
    }

    func editClipboardImage() {
        guard let image = pinTransfer.image(from: .general) else { toast.info("剪贴板里没有图片"); return }
        openEditor(image: image, scale: 1)
    }

    func presentEditor(_ controller: EditController, initialAction: ActionKind? = nil) {
        editor?.close()
        editor = controller
        controller.onClose = { [weak self] in self?.editor = nil }
        if let initialAction, initialAction.isAnnotationTool { controller.perform(initialAction) }
        controller.present()
        if let initialAction, !initialAction.isAnnotationTool { controller.perform(initialAction) }
    }

    func chooseScreenshotDestination(format: ImageFormat) -> URL? {
        selectScreenshotFile(format, URL(fileURLWithPath: config.settings.capture.saveDirectory, isDirectory: true))
    }

    private static func showSavePanel(format: ImageFormat, directory: URL) -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.allowedContentTypes = [UTType(format.uti) ?? .image]
        panel.nameFieldStringValue = "\(ImageCodec.defaultFileName()).\(format.fileExtension)"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    @discardableResult
    func saveScreenshot(_ image: CGImage, formatOverride: String? = nil, chooseLocation: Bool = false) -> Bool {
        let settings = config.settings.capture
        let format = ImageFormat(fileExtension: formatOverride ?? settings.saveFormat) ?? .png
        let directory = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
        do {
            let url: URL
            if chooseLocation {
                guard let destination = chooseScreenshotDestination(format: format) else { return false }
                url = destination
                try ImageCodec.encode(image, as: format, quality: settings.jpegQuality).write(to: url, options: .atomic)
            } else {
                url = try ImageCodec.write(image, to: directory, format: format, quality: settings.jpegQuality)
            }
            toast.success("已保存到 \(url.lastPathComponent)")
            return true
        } catch {
            toast.error("保存失败：\(error)")
            return false
        }
    }

    /// 启动时检查一次关键权限，缺了就提示（不阻塞启动）。
    /// 摄像头/麦克风只在用到录屏时才检查，不在这里打扰用户。
    func verifyPermissions(atLaunch: Bool = true) {
        let required: [SystemPermission] = [.screenCapture, .accessibility]
        let missing = required.filter { Permissions.status(of: $0) != .authorized }
        guard !missing.isEmpty else { return }
        if atLaunch || missing.contains(.screenCapture) {
            toast.warning("缺少\(missing.map(\.displayName).joined(separator: "、"))权限")
        }
    }
}

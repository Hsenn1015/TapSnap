import AppKit
import Carbon.HIToolbox
import Foundation
import TapSnapActionsBar
import TapSnapConfig
import TapSnapCore
import TapSnapIcons
import TapSnapSystem
import TapSnapTheme

/// 菜单栏图标与主菜单。
///
/// 状态栏菜单提供截图、贴图、长截图、录屏和设置等入口。
final class MenuBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let environment: AppEnvironment
    private let updater: AppUpdater?
    private var statusItem: NSStatusItem?
    private var updateMenuItem: NSMenuItem?
    private var togglePinsMenuItem: NSMenuItem?
    private var desktopBarMenuItem: NSMenuItem?
    private var demoModeMenuItem: NSMenuItem?
    private var shortcutItems: [ShortcutAction: (item: NSMenuItem, title: String)] = [:]
    private var shortcutFailures: [ShortcutAction: String] = [:]

    init(environment: AppEnvironment, updater: AppUpdater? = nil) {
        self.environment = environment
        self.updater = updater
    }

    @MainActor func install() {
        let item = NSStatusBar.system.statusItem(withLength: AppPaths.isDevelopmentBuild ? NSStatusItem.variableLength : NSStatusItem.squareLength)
        if AppPaths.isDevelopmentBuild, let button = item.button {
            button.title = "开发版"
            button.imagePosition = .imageLeading
        }
        item.menu = buildMenu()
        statusItem = item
        updater?.onAvailabilityChanged = { [weak self] in self?.refreshUpdateStatus() }
        refreshUpdateStatus()
    }

    func flashStatusItem() {
        guard let button = statusItem?.button else { return }
        button.highlight(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            button.highlight(false)
        }
    }

    /// 处理 tapsnap:// 协议（兼容旧的 sensnap://）。
    func handle(url: URL) {
        switch url.host {
        case "capture":
            startCapture()
        case "pin":
            pinFromClipboard()
        case "longshot":
            startLongShot()
        case "settings":
            openSettings()
        case "history":
            showClipboardHistory()
        default:
            environment.toast.info("未知命令：\(url.absoluteString)")
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // 核心捕获
        menu.addItem(shortcutMenuItem("截图", action: #selector(startCapture), shortcut: .screenshot, symbol: "camera.viewfinder"))
        menu.addItem(shortcutMenuItem("截图并贴图", action: #selector(startCaptureAndPin), shortcut: .screenshotAndPin, symbol: "pin"))
        menu.addItem(shortcutMenuItem("长截图", action: #selector(startLongShot), shortcut: .longShot, symbol: "rectangle.expand.vertical"))
        menu.addItem(shortcutMenuItem("屏幕录制", action: #selector(startRecording), shortcut: .recordScreen, symbol: "record.circle"))
        menu.addItem(submenuItem("更多截图与编辑", symbol: "ellipsis.circle") { sub in
            sub.addItem(menuItem("窗口截图", action: #selector(startWindowCapture), symbol: "macwindow"))
            sub.addItem(menuItem("全屏截图", action: #selector(startFullScreenCapture), symbol: "rectangle.dashed"))
            sub.addItem(menuItem("隐私截图", action: #selector(startPrivacyCapture), symbol: "eye.slash"))
            sub.addItem(menuItem("延时截图（3 秒）", action: #selector(startDelayedCapture), symbol: "timer"))
            sub.addItem(menuItem("截图预设…", action: #selector(showScreenshotPresets), symbol: "slider.horizontal.3"))
            sub.addItem(.separator())
            sub.addItem(menuItem("编辑最近截图", action: #selector(editRecentScreenshot), symbol: "pencil"))
            sub.addItem(menuItem("编辑剪贴板图片", action: #selector(editClipboardImage), symbol: "doc.on.clipboard"))
            sub.addItem(menuItem("打开图片…", action: #selector(editImageFile), symbol: "photo"))
            sub.addItem(menuItem("最近录制…", action: #selector(showLastRecording), symbol: "film"))
        })

        menu.addItem(.separator())

        // 识别与翻译
        menu.addItem(shortcutMenuItem("文字识别", action: #selector(startOCR), shortcut: .ocrRegion, symbol: "text.viewfinder"))
        menu.addItem(shortcutMenuItem("截图秒译", action: #selector(startQuickTranslation), shortcut: .quickTranslate, symbol: "sparkle.magnifyingglass"))
        menu.addItem(menuItem("截图翻译", action: #selector(startTranslation), symbol: "character.bubble"))
        menu.addItem(submenuItem("更多识别", symbol: "sparkles") { sub in
            sub.addItem(menuItem("表格识别", action: #selector(startTableRecognition), symbol: "tablecells"))
            sub.addItem(menuItem("公式识别", action: #selector(startFormulaRecognition), symbol: "x.squareroot"))
        })

        menu.addItem(.separator())

        // 贴图与历史
        menu.addItem(shortcutMenuItem("贴图（剪贴板）", action: #selector(pinFromClipboard), shortcut: .pinFromClipboard, symbol: "paperclip"))
        menu.addItem(submenuItem("贴图管理", symbol: "square.on.square") { sub in
            let togglePins = menuItem("隐藏所有贴图", action: #selector(toggleAllPins), symbol: "eye.slash")
            togglePinsMenuItem = togglePins
            sub.addItem(togglePins)
            sub.addItem(menuItem("恢复上次关闭的贴图", action: #selector(restoreLastPin), symbol: "arrow.uturn.backward"))
            sub.addItem(menuItem("贴图分组", action: #selector(showPinGroups), symbol: "folder"))
        })
        menu.addItem(shortcutMenuItem("剪贴板历史", action: #selector(showClipboardHistory), shortcut: .showHistory, symbol: "clock.arrow.circlepath"))

        menu.addItem(.separator())

        // 设置与维护
        menu.addItem(menuItem("设置…", action: #selector(openSettings), key: ",", symbol: "gearshape"))
        if updater != nil {
            let banner = menuItem("检查更新…", action: #selector(checkForUpdates), symbol: "arrow.down.circle")
            banner.isHidden = true
            updateMenuItem = banner
            menu.addItem(banner)
        }
        menu.addItem(submenuItem("更多", symbol: "ellipsis") { sub in
            let desktopBar = menuItem("桌面工具栏", action: #selector(toggleDesktopBar), symbol: "dock.rectangle")
            desktopBarMenuItem = desktopBar
            sub.addItem(desktopBar)
            let demoMode = menuItem("演示模式（允许录屏）", action: #selector(toggleDemoMode), symbol: "video.badge.checkmark")
            demoModeMenuItem = demoMode
            sub.addItem(demoMode)
            sub.addItem(menuItem("权限检查", action: #selector(checkPermissions), symbol: "checkmark.shield"))
            sub.addItem(menuItem("使用指南", action: #selector(showTutorial), symbol: "book"))
            sub.addItem(.separator())
            if updater != nil {
                sub.addItem(menuItem("检查更新…", action: #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath"))
            }
            sub.addItem(menuItem("关于 \(AppInfo.displayName)", action: #selector(showAbout), symbol: "info.circle"))
        })
        menu.addItem(menuItem(AppPaths.isDevelopmentBuild ? "退出开发版" : "退出", action: #selector(quit), key: "q", symbol: "power"))

        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshShortcutItems()
        togglePinsMenuItem?.title = environment.pinGroups.isHidden ? "显示所有贴图" : "隐藏所有贴图"
        desktopBarMenuItem?.state = environment.config.settings.appearance.showDesktopBar ? .on : .off
        demoModeMenuItem?.state = environment.config.settings.capture.allowSelfCapture ? .on : .off
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(editRecentScreenshot) { return environment.recentScreenshot != nil }
        if menuItem.action == #selector(restoreLastPin) { return environment.pinGroups.canRestoreLastClosed }
        if menuItem.action == #selector(checkForUpdates) { return updater?.canCheckForUpdates == true }
        return true
    }

    @MainActor private func refreshUpdateStatus() {
        let version = updater?.availableVersion
        updateMenuItem?.isHidden = version == nil
        updateMenuItem?.title = version.map { "有新版 \($0) · 查看…" } ?? "检查更新…"
        let description = version.map { "\(AppInfo.displayName)，\($0) 可更新" } ?? AppInfo.displayName
        guard let button = statusItem?.button,
              let camera = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: description) else { return }
        if version != nil {
            let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
                camera.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14, y: 14, width: 5, height: 5)).fill()
                return true
            }
            image.accessibilityDescription = description
            image.isTemplate = true
            button.image = image
        } else {
            camera.isTemplate = true
            button.image = camera
        }
        button.toolTip = description
    }

    func updateShortcutFailures(_ failures: [ShortcutAction: String]) {
        shortcutFailures = failures
        refreshShortcutItems()
    }

    private func refreshShortcutItems() {
        let secureInputEnabled = IsSecureEventInputEnabled()
        for (action, entry) in shortcutItems {
            let blocked = environment.shortcutCenter.isBlockedBySecureInput(action, secureInputEnabled: secureInputEnabled)
            Self.updateShortcutMenuItem(
                entry.item, title: entry.title, binding: environment.config.binding(for: action),
                failure: shortcutFailures[action], secureInputBlocked: blocked
            )
        }
    }

    private func shortcutMenuItem(_ title: String, action: Selector, shortcut: ShortcutAction, symbol: String? = nil) -> NSMenuItem {
        let item = menuItem(title, action: action, symbol: symbol)
        shortcutItems[shortcut] = (item, title)
        Self.updateShortcutMenuItem(item, title: title, binding: environment.config.binding(for: shortcut), failure: nil)
        return item
    }

    static func updateShortcutMenuItem(_ item: NSMenuItem, title: String, binding: KeyBinding?, failure: String?,
                                       secureInputBlocked: Bool = false) {
        item.keyEquivalent = binding?.combo.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = binding?.combo.cocoaModifiers ?? []
        if let failure {
            item.title = "\(title)（快捷键不可用）"
            item.toolTip = "快捷键不可用：\(failure)。仍可点击此菜单项。"
        } else if secureInputBlocked {
            item.title = "\(title)（macOS 安全输入中）"
            item.toolTip = "macOS 正在保护敏感输入，优先快捷键暂不可用。仍可点击此菜单项。"
        } else {
            item.title = title
            item.toolTip = binding?.displayString
        }
    }

    private func menuItem(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        symbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        if let symbol {
            item.image = menuSymbolImage(symbol)
        }
        return item
    }

    private func submenuItem(_ title: String, symbol: String? = nil, build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol {
            item.image = menuSymbolImage(symbol)
        }
        let submenu = NSMenu(title: title)
        submenu.delegate = self
        build(submenu)
        item.submenu = submenu
        return item
    }

    private func menuSymbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    // MARK: - 动作

    @MainActor @objc private func checkForUpdates() { updater?.checkForUpdates() }

    @objc private func startCapture() {
        environment.captureCoordinator.start(.edit)
    }

    @objc private func startPrivacyCapture() { environment.captureCoordinator.start(.edit, forcePrivacy: true) }
    @objc private func editRecentScreenshot() { environment.editRecentScreenshot() }
    @objc private func editClipboardImage() { environment.editClipboardImage() }
    @objc private func editImageFile() { environment.editImageFile() }
    @objc private func startWindowCapture() { environment.captureCoordinator.start(.edit, mode: .window) }
    @objc private func startFullScreenCapture() { environment.captureCoordinator.start(.edit, mode: .fullScreen) }
    @objc private func showScreenshotPresets() { environment.screenshotPresets.show() }
    @objc private func startTranslation() { environment.captureCoordinator.start(.translate) }
    @objc private func startQuickTranslation() { environment.captureCoordinator.start(.quickTranslate) }
    @objc private func startFormulaRecognition() {
        environment.formulaPanel.captureWhenReady { [weak environment = environment] in
            environment?.captureCoordinator.start(.formula)
        }
    }
    @objc private func toggleDesktopBar() { environment.config.update { $0.appearance.showDesktopBar.toggle() } }
    @objc private func toggleDemoMode() {
        let next = !environment.config.settings.capture.allowSelfCapture
        environment.config.update { $0.capture.allowSelfCapture = next }
        environment.toast.info(next ? "已开启演示模式：允许截屏/录屏捕获 TapSnap 窗口" : "已关闭演示模式：已恢复隐藏浮窗保护")
    }
    @objc private func showTutorial() { environment.tutorial.show() }

    @objc private func startCaptureAndPin() {
        environment.captureCoordinator.start(.pin)
    }

    @objc private func pinFromClipboard() {
        environment.pinTransfer.pinFromPasteboard()
    }

    @objc private func startLongShot() {
        environment.longShot.start()
    }

    @objc private func startRecording() {
        environment.record.start()
    }

    @objc private func startOCR() {
        environment.ocrCoordinator.captureAndRecognize()
    }

    @objc private func startTableRecognition() {
        environment.tableRecognizer.captureAndRecognize()
    }

    @objc private func toggleAllPins() {
        environment.pinGroups.toggleVisibility()
    }

    @objc private func showClipboardHistory() {
        environment.clipboardPanel.toggle()
    }

    /// 延时截图：给用户 3 秒去摆好窗口。
    @objc private func startDelayedCapture() {
        environment.toast.info("3 秒后开始截图")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.environment.captureCoordinator.start(.edit)
        }
    }

    @objc private func showLastRecording() {
        environment.record.showLastRecording()
    }

    @objc private func restoreLastPin() {        environment.pinGroups.restoreLastClosed()
    }

    @objc private func showPinGroups() {
        environment.pinGroupsPanel.toggle()
    }

    /// 桌面工具栏按钮的转发入口（桌面栏只发通知，不持有环境）。
    func performDesktopBarAction(_ action: ActionKind) {
        switch action {
        case .crop, .copy, .save, .confirm, .cancel:
            startCapture()
        case .pin:
            pinFromClipboard()
        case .longShot:
            startLongShot()
        case .record:
            startRecording()
        case .ocr:
            startOCR()
        case .tableRecognize:
            startTableRecognition()
        case .translate:
            startTranslation()
        case .formula:
            startFormulaRecognition()
        default:
            startCapture()
        }
    }

    @objc private func openSettings() {
        environment.openSettings()
    }

    @MainActor
    @objc private func checkPermissions() {
        environment.screenPermission.request()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "\(AppInfo.displayName) \(AppInfo.version)"
        alert.informativeText = """
            TapSnap 是一款桌面截图、贴图和录屏工具，支持滚动长截图、手绘标注、文字识别和隐私打码。

            主要功能
            • 截图 · 区域、窗口、全屏和滚动长截图
            • 贴图 · 将截图或剪贴板图片固定在桌面
            • 手绘标注 · 箭头、形状和自由高亮
            • 录屏编辑 · 裁剪、按时段标注、复制视频或 GIF
            • 内容识别 · 提取文字、表格和公式
            • 隐私打码 · 检查并遮盖截图里的敏感信息

            """
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

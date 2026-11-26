import AppKit
import Foundation
import TapSnapActionsBar
import TapSnapCore
import TapSnapSystem
import TapSnapToast

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var menuBar: MenuBarController?
    private var shortcutCenter: ShortcutCenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.shared.enableFileLogging()
        Log.shared.info("==== 启动 ====")
        Self.installMainMenu()

        let environment = AppEnvironment()
        self.environment = environment

        environment.toastPresenter.install()

        let updater = AppPaths.isDevelopmentBuild ? nil : AppUpdater(
            isBusy: { [weak environment] in environment?.isUpdateInteractionBusy == true },
            notify: { [weak environment] text in
                environment?.toast.show(ToastMessage(text: text, duration: 4))
            })
        let menuBar = MenuBarController(environment: environment, updater: updater)
        menuBar.install()
        self.menuBar = menuBar

        let shortcutCenter = environment.shortcutCenter
        shortcutCenter.onRegistrationFailuresChanged = { [weak menuBar] failures in
            menuBar?.updateShortcutFailures(failures)
        }
        self.shortcutCenter = shortcutCenter
        shortcutCenter.registerAll()

        environment.clipboardHistory.start()
        environment.pinGroups.start()
        environment.desktopBar.start()
        ToolBallController.shared.start(config: environment.config)

        // 悬浮球点击 = 发起区域截图。
        ToolBallController.shared.onCapture = {
            environment.captureCoordinator.start(.edit)
        }

        NotificationCenter.default.addObserver(
            forName: .desktopBarAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let action = note.object as? ActionKind else { return }
            self?.menuBar?.performDesktopBarAction(action)
        }

        updater?.start()
        Log.shared.info("TapSnap \(AppInfo.version) 已启动")
        environment.screenPermission.restoreOnLaunch()
        TranslationModelClient.prewarm(config: environment.config)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutCenter?.unregisterAll()
        environment?.clipboardHistory.stop()
        environment?.pinGroups.flushPersistence()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        shortcutCenter?.retryFailedRegistrations()
    }

    /// 菜单栏应用点 Dock 图标（或被 open 唤起）时不做任何事，只提示已在运行。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shortcutCenter?.retryFailedRegistrations()
        menuBar?.flashStatusItem()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let schemes = AppPaths.isDevelopmentBuild ? ["tapsnap-dev"] : ["tapsnap", "sensnap"]
        guard let url = urls.first, let scheme = url.scheme,
              schemes.contains(scheme.lowercased()) else { return }
        menuBar?.handle(url: url)
    }

    /// 菜单栏常驻应用（`.accessory`）默认没有主菜单，会导致所有输入框的
    /// ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z / ⇧⌘Z 和 ⌘W 失灵。注册标准主菜单以恢复系统编辑快捷键。
    @MainActor
    static func installMainMenu(on app: NSApplication? = nil) {
        let app = app ?? .shared
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        app.mainMenu = mainMenu
    }
}

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

        let environment = AppEnvironment()
        self.environment = environment

        environment.toastPresenter.install()

        let updater = AppUpdater(isBusy: { [weak environment] in environment?.isUpdateInteractionBusy == true },
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

        updater.start()
        Log.shared.info("TapSnap \(AppInfo.version) 已启动")
        environment.screenPermission.restoreOnLaunch()
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
        // tapsnap:// 为当前入口，继续接受旧的 sensnap:// 链接。
        guard let url = urls.first, let scheme = url.scheme,
              ["tapsnap", "sensnap"].contains(scheme.lowercased()) else { return }
        menuBar?.handle(url: url)
    }
}

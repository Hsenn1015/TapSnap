import AppKit
import TapSnapCore
import TapSnapSystem

/// 程序入口。
///
/// 用 `NSApplication` 手动启动而不是 SwiftUI 的 `@main App`：本应用是
/// `LSUIElement` 的菜单栏常驻程序，窗口由自己创建的 NSPanel 管理，
/// 生命周期（截图覆盖层、贴图窗口）不受 SwiftUI Scene 约束更省心。
@main
enum TapSnapMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == ScreenPermissionContinuation.probeArgument {
            exit(Permissions.status(of: .screenCapture) == .authorized ? 0 : 1)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)

        guard SingleInstance.ensureSingle() else {
            Log.shared.info("已有实例在运行，本次启动退出")
            return
        }

        app.run()
    }
}

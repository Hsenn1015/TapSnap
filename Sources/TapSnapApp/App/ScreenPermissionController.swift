import AppKit
import SwiftUI
import TapSnapScreen
import TapSnapSystem
import TapSnapTheme
import TapSnapUI

struct PendingScreenCapture: Codable, Equatable {
    let outcome: CaptureCoordinator.Outcome
    var mode: ScreenshotSession.Mode = .region
    var options: ScreenshotOutputOptions?
    var forcePrivacy = false
    var rect: CGRect?
    var displayID: UInt32?

    @MainActor
    func resume(in environment: AppEnvironment) {
        let coordinator = environment.captureCoordinator
        if outcome == .ocr && mode == .fullScreen {
            environment.ocrCoordinator.recognizeFullScreen()
        } else if let rect, let screen = ScreenLayout.current().first(where: { $0.id == displayID }) {
            coordinator.startFromEditor(outcome, rect: rect, screen: screen, outputOptions: options, forcePrivacy: forcePrivacy)
        } else {
            coordinator.start(outcome, mode: mode, outputOptions: options, forcePrivacy: forcePrivacy)
        }
    }
}

/// Only passed to the replacement process when TapSnap restarts itself.
struct ScreenPermissionContinuation: Codable, Equatable {
    static let resumeArgument = "--resume-screen-permission"

    let capture: PendingScreenCapture?
    let previousApp: Int32?

    func launchArgument() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
    }

    static func fromArguments(_ arguments: [String]) -> ScreenPermissionContinuation? {
        guard let flag = arguments.firstIndex(of: resumeArgument), flag + 1 < arguments.count,
              let data = Data(base64Encoded: arguments[flag + 1]) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum ScreenAccessCheck: Equatable {
    case available, denied, failed(String)

    static func run(_ check: () async throws -> Void) async -> Self {
        do {
            try await check()
            return .available
        } catch {
            return CaptureError.isPermissionDenied(error) ? .denied : .failed(error.localizedDescription)
        }
    }
}

/// Exists only while a permission guide is open. Intermediate app activations
/// (for example Finder) do not consume the return to the capturing process.
enum ScreenPermissionSettingsVisit {
    case idle, openingSettings, inSettings, authorizedInSettings

    enum ReturnAction { case none, recheck, resume }

    mutating func didActivate(settings: Bool, tapSnap: Bool) -> ReturnAction {
        if settings && self == .openingSettings { self = .inSettings }
        guard tapSnap else { return .none }
        switch self {
        case .inSettings:
            self = .idle
            return .recheck
        case .authorizedInSettings:
            self = .idle
            return .resume
        default:
            return .none
        }
    }
}

@MainActor
final class ScreenPermissionController: NSObject, ObservableObject, NSWindowDelegate {
    private unowned let environment: AppEnvironment
    private var window: NSPanel?
    private var continuation: ScreenPermissionContinuation?
    private var settingsVisit = ScreenPermissionSettingsVisit.idle
    private var verification: Task<Void, Never>?

    @Published private(set) var offersRelaunch = false
    @Published private(set) var isChecking = false
    @Published private(set) var feedback: String?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// A capture reaches here only after ScreenCaptureKit has already denied it.
    func request(for capture: PendingScreenCapture? = nil) {
        if let capture {
            if window == nil { cancelVerification() }
            continuation = .init(capture: capture, previousApp: continuation?.previousApp
                ?? NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        if let window {
            if capture != nil && settingsInFront { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if capture == nil { continueAfterAuthorization() }
            return
        }
        if capture != nil {
            present()
        } else if continuation == nil {
            continuation = .init(capture: nil, previousApp: nil)
            continueAfterAuthorization()
        }
    }

    func restoreOnLaunch(arguments: [String] = CommandLine.arguments) {
        guard let saved = ScreenPermissionContinuation.fromArguments(arguments) else { return }
        continuation = saved
        if saved.capture != nil {
            finish()
        } else {
            continueAfterAuthorization()
        }
    }

    func openSettings() {
        feedback = nil
        cancelVerification()
        settingsVisit = settingsInFront ? .inSettings : .openingSettings
        Permissions.openSettingsPanel(for: .screenCapture)
    }

    /// Both an explicit retry and a return from Settings verify access in this process.
    func continueAfterAuthorization() {
        guard continuation != nil, verification == nil else { return }
        settingsVisit = .idle
        isChecking = true
        let rechecking = window != nil
        verification = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await ScreenAccessCheck.run { try await self.environment.capture.checkAccess() }
            guard !Task.isCancelled else { return }
            self.verification = nil
            self.isChecking = false
            switch result {
            case .available:
                if self.window != nil && self.settingsInFront {
                    self.settingsVisit = .authorizedInSettings
                    return
                }
                self.finish()
            case .denied:
                if rechecking {
                    self.offersRelaunch = true
                    self.feedback = "macOS 仍未允许当前运行的 TapSnap 录屏。如果设置中已经开启，可以重新打开 TapSnap 再试。"
                }
                if self.window == nil { self.present() }
            case .failed(let detail):
                let message = "无法检查屏幕录制权限：\(detail)"
                if self.window != nil {
                    self.feedback = message
                } else {
                    self.continuation = nil
                    self.environment.toast.error(message)
                }
            }
        }
    }

    func reopenAfterAuthorization() {
        guard !isChecking, window != nil, let saved = continuation,
              offersRelaunch || saved.capture != nil else { return }
        guard !environment.isUpdateInteractionBusy else {
            feedback = "请先完成录制或保存并关闭编辑窗口，再重新打开 TapSnap。"
            return
        }
        do {
            try reopen(with: saved)
        } catch {
            feedback = "暂时无法重新打开 TapSnap，请从菜单退出后，再打开这份应用。"
        }
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
        settingsVisit = .idle
        cancelVerification()
        offersRelaunch = false
        window = nil
        continuation = nil
        feedback = nil
    }

    var hasPendingCapture: Bool { continuation?.capture != nil }

    private func cancelVerification() {
        verification?.cancel()
        verification = nil
        isChecking = false
    }

    private var settingsInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
    }

    private func present() {
        let theme = environment.theme
        let panel = PermissionGuidePanel(theme: theme) {
            ScreenPermissionGuide(controller: self, theme: theme)
        }
        panel.delegate = self
        window = panel
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if settingsInFront {
            settingsVisit = .inSettings
            panel.orderBack(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let settings = app.bundleIdentifier == "com.apple.systempreferences"
        let currentApp = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
        activated(settings: settings, tapSnap: currentApp)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if NSApp.isActive { activated(settings: false, tapSnap: true) }
    }

    private func activated(settings: Bool, tapSnap: Bool) {
        switch settingsVisit.didActivate(settings: settings, tapSnap: tapSnap) {
        case .recheck: continueAfterAuthorization()
        case .resume: finish()
        case .none: break
        }
    }

    private func finish() {
        guard let saved = continuation else { return }
        continuation = nil
        close()
        guard let capture = saved.capture else {
            environment.reportCheckedPermissions()
            return
        }
        Task { @MainActor [weak self] in
            if let pid = saved.previousApp, pid != ProcessInfo.processInfo.processIdentifier,
               let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
               app.bundleIdentifier != "com.apple.systempreferences",
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                app.activate()
            }
            // Let the permission window close before taking the screenshot.
            try? await Task.sleep(for: .milliseconds(160))
            guard let self else { return }
            capture.resume(in: self.environment)
        }
    }

    private func reopen(with saved: ScreenPermissionContinuation) throws {
        let application = Bundle.main.bundleURL
        guard application.pathExtension == "app" else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Release the one-instance guard and hotkeys before opening the exact same bundle again.
        process.arguments = ["-c", """
            attempt=0
            while [ "$attempt" -lt 50 ]; do
                if ! /bin/kill -0 "$1" 2>/dev/null; then
                    exec /usr/bin/open "$2" --args "$3" "$4"
                fi
                attempt=$((attempt + 1))
                /bin/sleep 0.2
            done
            """, "tapsnap-reopen", "\(ProcessInfo.processInfo.processIdentifier)", application.path,
            ScreenPermissionContinuation.resumeArgument, try saved.launchArgument()]
        try process.run()
        NSApp.terminate(nil)
    }
}

struct ScreenPermissionGuide: View {
    @ObservedObject var controller: ScreenPermissionController
    let theme: Theme

    var body: some View {
        PermissionGuideView(theme: theme, title: "允许截图和录屏",
                            instructions: "在系统设置的「隐私与安全性」中打开「屏幕与系统音频录制」（部分系统显示为「屏幕录制」），允许 TapSnap。返回 TapSnap 时会自动检测权限。",
                            feedback: controller.feedback, isChecking: controller.isChecking,
                            openSettings: { controller.openSettings() },
                            recheck: { controller.continueAfterAuthorization() },
                            relaunch: relaunchAction,
                            restartFromHelp: restartFromHelp, close: { controller.close() })
    }

    private var restartFromHelp: (() -> Void)? {
        guard controller.hasPendingCapture else { return nil }
        return { controller.reopenAfterAuthorization() }
    }

    private var relaunchAction: (() -> Void)? {
        guard controller.offersRelaunch else { return nil }
        return { controller.reopenAfterAuthorization() }
    }
}

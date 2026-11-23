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
    static let probeArgument = "--check-screen-permission"
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

enum ScreenPermissionNextStep: Equatable {
    case wait, resume, reopen

    static func decide(currentGrant: Bool, freshGrant: Bool, captureRejected: Bool,
                       userConfirmed: Bool, mayReopenAutomatically: Bool) -> Self {
        if currentGrant && !captureRejected { return .resume }
        if userConfirmed || (freshGrant && mayReopenAutomatically) { return .reopen }
        return .wait
    }
}

@MainActor
final class ScreenPermissionController: NSObject, ObservableObject, NSWindowDelegate {
    private unowned let environment: AppEnvironment
    private var window: NSPanel?
    private var continuation: ScreenPermissionContinuation?
    private var monitor: Task<Void, Never>?
    private var requested = false
    private var captureRejected = false
    private var mayReopenAutomatically = true

    @Published private(set) var settingsOpened = false
    @Published private(set) var feedback: String?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func request(for capture: PendingScreenCapture? = nil) {
        if window != nil {
            if let capture, let prior = continuation {
                continuation = .init(capture: capture, previousApp: prior.previousApp)
            }
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        continuation = .init(capture: capture, previousApp: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        captureRejected = capture != nil && isAuthorized
        if !isAuthorized && !requested {
            requested = true
            NSApp.activate(ignoringOtherApps: true)
            _ = Permissions.request(.screenCapture)
        }
        if isAuthorized && !captureRejected {
            finish()
        } else {
            present()
        }
    }

    func restoreOnLaunch(arguments: [String] = CommandLine.arguments) {
        guard let saved = ScreenPermissionContinuation.fromArguments(arguments) else { return }
        continuation = saved
        requested = true
        mayReopenAutomatically = false
        if isAuthorized {
            finish()
        } else {
            settingsOpened = true
            feedback = "请在系统设置中启用这份 TapSnap。"
            present()
        }
    }

    func openSettings() {
        settingsOpened = true
        feedback = nil
        Permissions.openSettingsPanel(for: .screenCapture)
        watchPermission()
    }

    func continueAfterAuthorization() {
        advance(freshGrant: false, userConfirmed: true)
    }

    func copyApplicationPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Bundle.main.bundlePath, forType: .string)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        monitor?.cancel()
        monitor = nil
        window = nil
        continuation = nil
        settingsOpened = false
        feedback = nil
    }

    private var isAuthorized: Bool { Permissions.status(of: .screenCapture) == .authorized }

    private func present() {
        let settingsInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
        if settingsInFront { settingsOpened = true }
        let theme = environment.theme
        let view = NSHostingController(rootView: ScreenPermissionGuide(controller: self, theme: theme))
        view.sizingOptions = [.preferredContentSize]
        let panel = NSPanel(contentViewController: view)
        panel.title = "TapSnap 权限"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        panel.delegate = self
        panel.center()
        window = panel
        if settingsInFront {
            panel.orderBack(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        watchPermission()
    }

    private func watchPermission() {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            // A newly started process can see a grant before the current process picks it up.
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" {
                    self.settingsOpened = true
                }
                let freshGrant: Bool
                if self.mayReopenAutomatically && (!self.isAuthorized || self.captureRejected) {
                    freshGrant = await self.freshAuthorization()
                } else {
                    freshGrant = false
                }
                guard !Task.isCancelled else { return }
                self.advance(freshGrant: freshGrant, userConfirmed: false)
            }
        }
    }

    private func freshAuthorization() async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        return await withCheckedContinuation { continuation in
            let probe = Process()
            probe.executableURL = executable
            probe.arguments = [ScreenPermissionContinuation.probeArgument]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            probe.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try probe.run() }
            catch { continuation.resume(returning: false) }
        }
    }

    private func advance(freshGrant: Bool, userConfirmed: Bool) {
        guard let continuation else { return }
        switch ScreenPermissionNextStep.decide(currentGrant: isAuthorized, freshGrant: freshGrant,
                                               captureRejected: captureRejected, userConfirmed: userConfirmed,
                                               mayReopenAutomatically: mayReopenAutomatically) {
        case .wait: break
        case .resume: finish()
        case .reopen:
            guard !environment.isUpdateInteractionBusy else {
                settingsOpened = true
                feedback = "保存当前内容后，点击「已授权，继续」。"
                return
            }
            do {
                try reopen(with: continuation)
            } catch {
                mayReopenAutomatically = false
                feedback = "暂时无法重新打开 TapSnap，请再点一次继续。"
            }
        }
    }

    private func finish() {
        guard let saved = continuation else { return }
        continuation = nil
        close()
        guard let capture = saved.capture else {
            environment.toast.success("录屏权限已开启")
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
        monitor?.cancel()
        NSApp.terminate(nil)
    }
}

struct ScreenPermissionGuide: View {
    @ObservedObject var controller: ScreenPermissionController
    let theme: Theme
    @State private var showsHelp = false
    @State private var copiedPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.token(.primary))
                    .frame(width: 40, height: 40)
                    .background(theme.token(.muted), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("允许截图和录屏")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.token(.foreground))
                    Text("开启录屏权限后，TapSnap 会继续刚才的操作。")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.token(.mutedForeground))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureGroup("列表里找不到 TapSnap？", isExpanded: $showsHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("在「录屏与系统录音」点 ＋。按 ⌘⇧G，粘贴应用路径。")
                        .fixedSize(horizontal: false, vertical: true)
                    SnapButton(copiedPath ? "已复制路径" : "复制应用路径", theme: theme, variant: .outline, size: .sm) {
                        controller.copyApplicationPath()
                        copiedPath = true
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.token(.mutedForeground))

            if let feedback = controller.feedback {
                Text(feedback)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.token(.mutedForeground))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack(spacing: 8) {
                SnapButton("稍后", theme: theme, variant: .ghost) { controller.close() }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 4)
                if controller.settingsOpened {
                    SnapButton("打开系统设置", theme: theme, variant: .outline) { controller.openSettings() }
                    SnapButton("已授权，继续", theme: theme, variant: .primary) { controller.continueAfterAuthorization() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    SnapButton("打开系统设置", theme: theme, variant: .primary) { controller.openSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(theme.token(.popover))
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}

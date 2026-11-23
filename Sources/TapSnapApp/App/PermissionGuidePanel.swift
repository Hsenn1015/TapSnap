import AppKit
import SwiftUI
import TapSnapSystem
import TapSnapTheme
import TapSnapUI

/// 保留同一个内容视图。展开帮助和更新检测结果时重新适配窗口，超出屏幕高度时允许滚动。
@MainActor
final class PermissionGuidePanel: NSPanel {
    private let initialVisibleFrame: CGRect
    private let guideWidth: CGFloat

    init<Content: View>(theme: Theme, visibleFrame: CGRect? = nil, @ViewBuilder content: () -> Content) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        initialVisibleFrame = visibleFrame ?? screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let available = initialVisibleFrame.insetBy(dx: 12, dy: 12)
        let style: NSWindow.StyleMask = [.titled, .closable]
        guideWidth = min(460, available.width)
        super.init(contentRect: CGRect(x: 0, y: 0, width: guideWidth, height: 160),
                   styleMask: style, backing: .buffered, defer: false)
        title = "TapSnap 权限"
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let host = NSHostingView(rootView: content()
            .frame(width: guideWidth)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                self?.fit(documentHeight: height)
            })
        scroll.documentView = host
        contentView = scroll
        fit(documentHeight: host.fittingSize.height)
        setFrameOrigin(CGPoint(x: available.midX - frame.width / 2, y: available.midY - frame.height / 2))
    }

    private func fit(documentHeight: CGFloat) {
        guard documentHeight > 0, let scroll = contentView as? NSScrollView,
              let document = scroll.documentView else { return }
        let size = CGSize(width: guideWidth, height: ceil(documentHeight))
        let available = ((isVisible ? screen?.visibleFrame : nil) ?? initialVisibleFrame).insetBy(dx: 12, dy: 12)
        let maximumHeight = contentRect(forFrameRect: available).height
        let viewport = CGSize(width: guideWidth, height: min(size.height, maximumHeight))
        if document.frame.size != size { document.setFrameSize(size) }
        if scroll.frame.size != viewport {
            let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
            setContentSize(viewport)
            let top = min(available.maxY, max(topLeft.y, available.minY + frame.height))
            setFrameTopLeftPoint(CGPoint(x: topLeft.x, y: top))
        }
    }
}

struct PermissionGuideView: View {
    let theme: Theme
    let title: String
    let instructions: String
    var feedback: String?
    var isChecking = false
    let openSettings: () -> Void
    let recheck: () -> Void
    var relaunch: (() -> Void)?
    let close: () -> Void
    @State private var showsHelp = false
    @State private var copiedPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.token(.foreground))
                Text(instructions)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.token(.mutedForeground))
            }
            DisclosureGroup("已开启权限，或列表里找不到 TapSnap？", isExpanded: $showsHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("请确认系统设置中允许的是下方路径的 TapSnap。需要添加时，点 ＋，按 ⌘⇧G，再粘贴路径。")
                    Text(verbatim: Bundle.main.bundlePath)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    SnapButton(copiedPath ? "已复制路径" : "复制应用路径", theme: theme, variant: .outline, size: .sm) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        copiedPath = pasteboard.setString(Bundle.main.bundlePath, forType: .string)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .font(.system(size: 13))
            .foregroundStyle(theme.token(.mutedForeground))

            if let feedback {
                Text(feedback)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.token(.foreground))
                    .accessibilityLabel("检测结果，\(feedback)")
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.token(.popover))
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onExitCommand(perform: close)
    }

    @ViewBuilder private var buttons: some View {
        SnapButton("打开系统设置", theme: theme, variant: .outline, action: openSettings)
        SnapButton(isChecking ? "检测中…" : "重新检测", theme: theme,
                   variant: .primary, isEnabled: !isChecking, action: recheck)
            .keyboardShortcut(.defaultAction)
        if let relaunch {
            SnapButton("重新打开 TapSnap", theme: theme, variant: .outline, isEnabled: !isChecking, action: relaunch)
        }
    }
}

/// 只在用户查看辅助功能引导时查询；授权后即可在当前进程重新注册快捷键。
@MainActor
final class AccessibilityPermissionGuideController: NSObject, ObservableObject, NSWindowDelegate {
    private let theme: @MainActor () -> Theme
    private let onAuthorized: () -> Void
    private var panel: PermissionGuidePanel?
    @Published private(set) var operation = ""
    @Published private(set) var screenCaptureAvailable = false
    @Published private(set) var feedback: String?

    init(theme: @escaping @MainActor () -> Theme = { .matching(isDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) },
         onAuthorized: @escaping () -> Void) {
        self.theme = theme
        self.onAuthorized = onAuthorized
    }

    func show(for operation: String, screenCaptureAvailable: Bool = false) {
        if Permissions.status(of: .accessibility) == .authorized {
            panel?.close()
            onAuthorized()
            return
        }
        self.operation = operation
        self.screenCaptureAvailable = screenCaptureAvailable
        if panel == nil {
            let theme = theme()
            let panel = PermissionGuidePanel(theme: theme) {
                AccessibilityPermissionGuide(controller: self, theme: theme)
            }
            panel.delegate = self
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        guard panel != nil else { return }
        if Permissions.status(of: .accessibility) == .authorized {
            panel?.close()
            onAuthorized()
        } else {
            feedback = "当前这份 TapSnap 仍未获得辅助功能权限。"
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard panel != nil, Permissions.status(of: .accessibility) == .authorized else { return }
        panel?.close()
        onAuthorized()
    }

    func close() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        feedback = nil
    }
}

private struct AccessibilityPermissionGuide: View {
    @ObservedObject var controller: AccessibilityPermissionGuideController
    let theme: Theme

    var body: some View {
        PermissionGuideView(theme: theme, title: "允许\(controller.operation)",
                            instructions: instructions,
                            feedback: controller.feedback,
                            openSettings: { Permissions.openSettingsPanel(for: .accessibility) },
                            recheck: controller.refresh, close: controller.close)
    }

    private var instructions: String {
        let settings = "在系统设置的「隐私与安全性」中打开「设备控制与数据访问」（部分系统显示为「辅助功能」），允许 TapSnap。此权限用于自动滚动和优先响应快捷键。"
        return controller.screenCaptureAvailable ? "屏幕录制权限已开启，可以截图和录屏。\n\n" + settings : settings
    }
}

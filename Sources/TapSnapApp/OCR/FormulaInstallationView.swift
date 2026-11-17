import SwiftUI
import TapSnapTheme
import TapSnapUI

/// The formula window shows this view until its local runtime is ready.
struct FormulaInstallationView: View {
    enum State: Equatable {
        case checking
        case readyToInstall
        case missingPython
        case installing(stage: String)
        case cancelling
        case installed
        case failed(message: String)
    }

    let theme: Theme
    let state: State
    let onInstall: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void
    let onRecheckPython: () -> Void
    let onBeginRecognition: () -> Void

    @Environment(\.openURL) private var openURL
    private static let pythonInstallerPage = URL(string: "https://www.python.org/downloads/release/python-31210/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "function")
                    .font(.system(size: 19, weight: .medium))
                    .accessibilityHidden(true)
                    .frame(width: 42, height: 42)
                    .background(theme.token(.secondary), in: .rect(cornerRadius: theme.metrics.radiusMD))
                Text(state == .installed ? "公式识别" : "安装公式识别")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(alignment: .leading, spacing: 8) {
                status
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.token(.card), in: .rect(cornerRadius: theme.metrics.radiusLG))
            .overlay {
                RoundedRectangle(cornerRadius: theme.metrics.radiusLG)
                    .strokeBorder(theme.token(.border), lineWidth: 1)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.token(.foreground))
        .background(theme.token(.background))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .checking:
            loading("正在检查本地识别环境…")
        case .readyToInstall:
            Text("下载模型和运行依赖").font(.headline)
            description("首次安装需要联网，装好后约占 1.2 GB。公式截图只在本机处理。")
        case .missingPython:
            Text("需要 Python 3.12").font(.headline)
            description("安装官方 macOS 版本后，返回 TapSnap 重新检测。")
        case .installing(let stage):
            loading(stage)
        case .cancelling:
            loading("正在取消并清理本次安装…")
        case .installed:
            Text("公式识别已就绪").font(.headline)
            description("框选公式后即可在本机识别并复制 LaTeX。")
        case .failed(let message):
            Label("安装失败", systemImage: "exclamationmark.circle")
                .font(.headline)
                .foregroundStyle(theme.token(.destructive))
            ViewThatFits(in: .vertical) {
                description(message)
                    .textSelection(.enabled)
                ScrollView {
                    description(message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(maxHeight: 120, alignment: .topLeading)
        }
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .checking, .cancelling:
            EmptyView()
        case .readyToInstall:
            button("稍后", variant: .outline, action: onDismiss)
            button("开始安装", variant: .primary, action: onInstall)
        case .missingPython:
            button("下载 Python 3.12", variant: .outline) { openURL(Self.pythonInstallerPage) }
            button("重新检测", variant: .primary, action: onRecheckPython)
        case .installing:
            button("取消安装", variant: .outline, action: onCancel)
        case .installed:
            button("开始识别", variant: .primary, action: onBeginRecognition)
        case .failed:
            button("关闭", variant: .outline, action: onDismiss)
            button("重试", variant: .primary, action: onInstall)
        }
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(theme.token(.mutedForeground))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loading(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(text).font(.headline)
        }
    }

    private func button(_ label: String, variant: SnapButtonVariant, action: @escaping () -> Void) -> some View {
        SnapButton(theme: theme, variant: variant, action: action) { Text(label) }
    }
}

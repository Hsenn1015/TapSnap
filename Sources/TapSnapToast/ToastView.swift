import TapSnapCore
import TapSnapIcons
import TapSnapTheme
import TapSnapUI
import SwiftUI

/// 按实际内容居中堆叠，外侧留出阴影空间。
struct ToastStackView: View {
    let messages: [ToastMessage]
    let theme: Theme
    var onAction: ((UUID) -> Void)? = nil
    let onDismiss: (UUID) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(messages) { message in
                ToastRow(
                    theme: theme,
                    message: message,
                    onAction: {
                        if let onAction { onAction(message.id) } else { onDismiss(message.id) }
                    },
                    onDismiss: { onDismiss(message.id) }
                )
            }
        }
        .padding(14)
    }
}

private struct ToastRow: View {
    let theme: Theme
    let message: ToastMessage
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let (symbol, accent) = statusAppearance
        HStack(spacing: 9) {
            Button(action: onDismiss) {
                HStack(spacing: 9) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 24, height: 24)
                        .background(accent.opacity(theme.isDark ? 0.17 : 0.10), in: Circle())
                        .accessibilityHidden(true)
                    Text(message.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.token(.popoverForeground))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("关闭提示")
            if let actionTitle = message.actionTitle {
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.token(.primary))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(theme.token(.primary).opacity(theme.isDark ? 0.16 : 0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(actionTitle)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, message.actionTitle == nil ? 15 : 10)
        .padding(.vertical, 8)
        .background {
            shape.fill(surface)
                .overlay { shape.strokeBorder(theme.token(.foreground).opacity(0.11), lineWidth: 1) }
                .shadow(color: .black.opacity(0.19), radius: 8, y: 3)
        }
        .contentShape(shape)
    }

    private var surface: LinearGradient {
        let colors: [UInt32] = theme.isDark ? [0x28303b, 0x1e252e] : [0xfcfdff, 0xf1f4f8]
        return LinearGradient(colors: colors.map { RGBAColor(rgb: $0).color }, startPoint: .top, endPoint: .bottom)
    }

    private var statusAppearance: (String, Color) {
        let symbol: String
        let color: UInt32
        switch message.style {
        case .info:
            symbol = "info"
            color = theme.isDark ? 0x9ac6ff : 0x295c9f
        case .success:
            symbol = "checkmark"
            color = theme.isDark ? 0x72e5bc : 0x087858
        case .warning:
            symbol = "exclamationmark"
            color = theme.isDark ? 0xffc975 : 0x89550c
        case .error:
            symbol = "xmark"
            color = theme.isDark ? 0xff9ba6 : 0xb24153
        }
        return (symbol, RGBAColor(rgb: color).color)
    }
}

/// 权限引导弹窗。
public struct PermissionPromptView: View {
    public var theme: Theme
    public var prompt: PermissionPrompt
    public var onClose: () -> Void

    public init(theme: Theme = .dark, prompt: PermissionPrompt, onClose: @escaping () -> Void) {
        self.theme = theme
        self.prompt = prompt
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconView(icon: .settings, size: 16, color: theme.token(.primary))
                Text(prompt.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.token(.foreground))
                Spacer()
            }
            Text(prompt.message)
                .font(.system(size: 12))
                .foregroundStyle(theme.token(.mutedForeground))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                SnapButton("稍后", theme: theme, variant: .ghost, size: .sm) {
                    onClose()
                }
                SnapButton("去系统设置", theme: theme, variant: .primary, size: .sm) {
                    prompt.openSystemSettings()
                    onClose()
                }
            }
        }
        .padding(18)
        .frame(width: 360)
        .senPanelStyle(theme: theme, radius: theme.metrics.radiusXL)
    }
}

import Combine
import TapSnapIcons
import TapSnapTheme
import TapSnapUI
import SwiftUI

/// 录制控制条的状态。
final class RecordControlBarModel: ObservableObject {
    @Published var isPaused = false
    @Published var elapsed: TimeInterval = 0
    @Published var isBusy = true
    @Published var isFinishing = false
    @Published var busyText = "正在开始…"

    var onPauseToggle: (() -> Void)?
    var onRestart: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private var timer: Timer?

    func startTimer(elapsed: @escaping @MainActor () -> TimeInterval) {
        stopTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsed = elapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 录制中的悬浮控制条。
struct RecordControlBarView: View {
    @ObservedObject var model: RecordControlBarModel
    var theme: Theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.metrics.radiusLG, style: .continuous)
        HStack(spacing: 10) {
            Circle()
                .fill(theme.token(.destructive))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(theme.token(.destructive).opacity(0.35), lineWidth: 3)
                        .scaleEffect(model.isPaused ? 1 : 1.9)
                )
                .opacity(model.isPaused ? 0.4 : 1)
                .animation(Interaction.toggle, value: model.isPaused)

            Text(model.isBusy ? model.busyText : model.elapsedText)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.token(.foreground))

            Rectangle()
                .fill(theme.token(.border))
                .frame(width: 1, height: 16)

            IconButton(icon: model.isPaused ? .confirm : .record, theme: theme, isEnabled: !model.isBusy) {
                model.onPauseToggle?()
            }
            .help(model.isPaused ? "继续录制" : "暂停录制")
            IconButton(icon: .restart, theme: theme, isEnabled: !model.isBusy) {
                model.onRestart?()
            }
            .help("重新录制 · 清空本次录制，从当前选区重新开始")
            IconButton(icon: .close, theme: theme, isEnabled: !model.isFinishing) { model.onCancel?() }
                .help("取消录制")

            SnapButton("完成", theme: theme, variant: .primary, size: .sm) {
                model.onFinish?()
            }
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(theme.token(.popover), in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(theme.token(.border), lineWidth: 1)
        }
    }
}

import AppKit
import TapSnapCore
import TapSnapTheme
import SwiftUI

/// 剪贴板历史面板。
///
/// 面板浮在鼠标附近，点击记录将内容放回剪贴板并关闭面板。
final class ClipboardHistoryPanel {
    private let history: ClipboardHistory
    private let theme: () -> Theme
    private var window: NSWindow?

    init(history: ClipboardHistory, theme: @escaping () -> Theme) {
        self.history = history
        self.theme = theme
    }

    func toggle() {
        window == nil ? show() : close()
    }

    func show() {
        guard window == nil else { return }

        let view = ClipboardHistoryView(
            history: history,
            theme: theme(),
            onPick: { [weak self] entry in
                self?.history.activate(entry)
                self?.close()
            },
            onClose: { [weak self] in self?.close() }
        )

        let panel = KeyablePanel(
            contentRect: CGRect(origin: .zero, size: ClipboardHistoryView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.title = "剪贴板历史"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.appearance = NSAppearance(named: view.theme.isDark ? .darkAqua : .aqua)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // NSPanel 默认会在 App 失活时自动隐藏，历史面板必须一直留在屏幕上。
        panel.hidesOnDeactivate = false
        panel.setContentSize(ClipboardHistoryView.panelSize)
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()

        window = panel
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    private func position(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        let x = min(max(visible.minX + 8, mouse.x - size.width / 2), visible.maxX - size.width - 8)
        let y = min(max(visible.minY + 8, mouse.y - size.height - 12), visible.maxY - size.height - 8)
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }
}

/// 无边框面板默认不能成为 key window，那样 Esc 就收不到。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct ClipboardHistoryView: View {
    static let panelSize = CGSize(width: 368, height: 468)

    @ObservedObject var history: ClipboardHistory
    let theme: Theme
    let onPick: (ClipboardHistory.Entry) -> Void
    let onClose: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if history.entries.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(history.entries) { entry in
                                row(entry)
                            }
                        }
                        .padding(6)
                    }
                    .accessibilityLabel("剪贴板记录")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.token(.card), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.token(.border), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .padding(8)
            Divider()
            HStack {
                Label("仅保存在本机", systemImage: "lock")
                Spacer()
                Text("最多 \(ClipboardHistory.capacity) 条")
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.token(.mutedForeground))
            .padding(.horizontal, 13)
            .frame(height: 34)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .foregroundStyle(theme.token(.foreground))
        .background(theme.token(.muted))
        .clipShape(frame)
        .overlay {
            frame.strokeBorder(theme.token(.foreground).opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 9) {
                glyph("clipboard", tint: RGBAColor(rgb: theme.isDark ? 0xAAB8FF : 0x4C58B8).color)
                Text("剪贴板历史")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(history.entries.count.formatted())
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.token(.mutedForeground))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.token(.secondary), in: .capsule)
                    .accessibilityLabel("\(history.entries.count) 条记录")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { WindowDragArea().accessibilityHidden(true) }
            .help("拖动标题栏移动窗口")
            headerButton("清空", icon: "trash", action: history.clear)
                .disabled(history.entries.isEmpty)
            headerButton("关闭", icon: "xmark", action: onClose)
        }
        .padding(.horizontal, 11)
        .frame(height: 53)
        .background(theme.token(.popover))
    }

    private func headerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.token(.mutedForeground))
                .frame(width: 27, height: 27)
                .background(theme.token(.card), in: .rect(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(theme.token(.border), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SnapPressStyle(scale: 0.94))
        .help(title == "清空" ? "清空本地剪贴板历史" : title)
        .accessibilityLabel(title)
    }

    private func glyph(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 29, height: 29)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            glyph("clipboard", tint: theme.token(.mutedForeground))
            Text("还没有记录")
                .font(.system(size: 13, weight: .semibold))
            Text("复制的文字和图片会出现在这里")
                .font(.system(size: 12))
                .foregroundStyle(theme.token(.mutedForeground))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ entry: ClipboardHistory.Entry) -> some View {
        Button {
            onPick(entry)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                switch entry.content {
                case .text(let text):
                    glyph("text.alignleft", tint: theme.token(.mutedForeground))
                    Text(text)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                case .image(let image):
                    glyph("photo", tint: theme.token(.mutedForeground))
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 200, maxHeight: 72, alignment: .leading)
                        .clipShape(.rect(cornerRadius: 6))
                }
                Spacer(minLength: 0)
                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(theme.token(.mutedForeground))
                    .padding(.top, 2)
            }
            .padding(7)
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(HistoryRowStyle(theme: theme))
        .accessibilityHint("复制这条记录")
    }
}

private struct HistoryRowStyle: ButtonStyle {
    let theme: Theme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? theme.token(.secondary) : hovering ? theme.token(.muted) : .clear,
                in: .rect(cornerRadius: 8)
            )
            .onHover { hovering = $0 }
    }
}

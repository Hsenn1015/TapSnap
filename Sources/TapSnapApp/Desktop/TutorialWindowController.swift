import AppKit
import SwiftUI
import TapSnapActionsBar
import TapSnapConfig
import TapSnapTheme
import TapSnapTutorial

/// 可反复打开的使用指南，操作示例直接进入对应功能。
final class TutorialWindowController {
    private let theme: () -> Theme
    private let config: ConfigStore
    private var window: NSWindow?

    init(theme: @escaping () -> Theme, config: ConfigStore = .shared) {
        self.theme = theme
        self.config = config
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = TutorialGuideView(theme: theme(), screenshotShortcut: config.settings.shortcuts[ShortcutAction.screenshot.rawValue]?.displayString,
                                     onClose: { [weak self] in self?.close() },
                                     onTry: { [weak self] scene in self?.tryScene(scene) })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "TapSnap 使用指南"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 650, height: 500))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() { window?.orderOut(nil); window = nil }

    private func tryScene(_ scene: TutorialScene) {
        close()
        if scene == .floatingBall { ToolBallController.shared.show(); return }
        let action: ActionKind
        switch scene {
        case .clipboardPin: action = .pin
        case .longScreenshot: action = .longShot
        case .ocrAndTranslate: action = .translate
        case .formulaRecognition: action = .formula
        case .tableRecognition: action = .tableRecognize
        case .keyboardMouseRecording: action = .record
        default: action = .crop
        }
        // 让指南先退出屏幕，避免被收进截图底图。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NotificationCenter.default.post(name: .desktopBarAction, object: action)
        }
    }
}

private struct TutorialGuideView: View {
    var theme: Theme
    var screenshotShortcut: String?
    var onClose: () -> Void
    var onTry: (TutorialScene) -> Void
    @State private var index = 0
    private var scene: TutorialScene { TutorialScene.allCases[index] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("快速上手").font(.system(size: 16, weight: .semibold)).padding(.bottom, 12)
                ForEach(Array(TutorialScene.allCases.enumerated()), id: \.offset) { position, scene in
                    Button { index = position } label: {
                        Text(scene.title).font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(index == position ? theme.token(.muted) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                Spacer()
                if let screenshotShortcut {
                    Text("截图快捷键\n\(screenshotShortcut)").font(.system(size: 11))
                        .foregroundStyle(theme.token(.mutedForeground))
                }
            }.padding(16).frame(width: 180)
            Divider()
            VStack(spacing: 8) {
                TutorialCardView(theme: theme, scene: scene, currentIndex: index, totalCount: TutorialScene.allCases.count,
                                 onNext: { if index + 1 < TutorialScene.allCases.count { index += 1 } else { onClose() } },
                                 onSkip: onClose)
                Button(tryTitle) { onTry(scene) }.buttonStyle(.borderedProminent)
            }.padding(4)
        }
        .frame(width: 650, height: 500)
        .background(theme.token(.background))
        .foregroundStyle(theme.token(.foreground))
        .onExitCommand(perform: onClose)
    }

    private var tryTitle: String {
        switch scene {
        case .clipboardPin: return "从剪贴板贴图"
        case .longScreenshot: return "开始长截图"
        case .ocrAndTranslate: return "开始识别并翻译"
        case .formulaRecognition: return "开始公式识别"
        case .tableRecognition: return "开始表格识别"
        case .floatingBall: return "显示悬浮球"
        case .keyboardMouseRecording: return "开始录屏"
        default: return "开始截图"
        }
    }
}

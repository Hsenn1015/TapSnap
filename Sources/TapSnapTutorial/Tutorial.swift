import Foundation
import TapSnapIcons
import TapSnapTheme
import TapSnapUI
import SwiftUI

/// 每个场景都给出当前产品中可执行的入口、步骤与结果。
public enum TutorialScene: String, CaseIterable, Sendable {
    case captureAndAnnotate
    case clipboardPin
    case longScreenshot
    case ocrAndTranslate
    case formulaRecognition
    case tableRecognition
    case floatingBall
    case keyboardMouseRecording

    public var title: String {
        switch self {
        case .captureAndAnnotate: return "截图与标注"
        case .clipboardPin: return "剪贴板贴图"
        case .longScreenshot: return "滚动长截图"
        case .ocrAndTranslate: return "文字识别与翻译"
        case .formulaRecognition: return "公式识别"
        case .tableRecognition: return "表格识别"
        case .floatingBall: return "悬浮球"
        case .keyboardMouseRecording: return "键鼠录制"
        }
    }

    public var subtitle: String {
        switch self {
        case .captureAndAnnotate: return "框选区域，随手标注，按一下就贴到屏幕上"
        case .clipboardPin: return "把剪贴板里的图直接贴到屏幕上对照查看"
        case .longScreenshot: return "滚动页面自动拼接成一张长图"
        case .ocrAndTranslate: return "框选文字即刻识别，可复制可翻译"
        case .formulaRecognition: return "截图里的公式转成 LaTeX"
        case .tableRecognition: return "表格截图还原成可编辑的表格"
        case .floatingBall: return "常驻小悬浮球，随手唤起截图"
        case .keyboardMouseRecording: return "录制时显示按键与鼠标操作"
        }
    }

    public var instructions: [String] {
        switch self {
        case .captureAndAnnotate:
            return ["从菜单栏选择「截图」，按住鼠标拖出选区。",
                    "按 ⌘C 直接复制，或按回车进入编辑器，添加箭头、文字或序号。",
                    "编辑后可以复制、保存或贴图。Esc 可取消当前截图。"]
        case .clipboardPin:
            return ["先复制图片，再从菜单栏选择「剪贴板贴图」。",
                    "拖动贴图移动，滚轮缩放，按住 Option 滚轮调整透明度。",
                    "右键可旋转、翻转、移动分组或开启鼠标穿透；在「贴图分组」中恢复鼠标操作。"]
        case .longScreenshot:
            return ["先截图框选区域，再点选区工具栏的「长截图」，也可从菜单栏直接开始。",
                    "让鼠标留在滚动正文中滚动，预览会持续拼接；固定区域只保留一次。",
                    "点「完成」进入编辑，检查拼接后复制或保存。"]
        case .ocrAndTranslate:
            return ["从菜单栏选择「文字识别」，框选文字区域。",
                    "在识别结果中核对并复制文字；截图编辑工具栏也提供文字识别与翻译。",
                    "翻译时选择目标语言，点「翻译」，完成后点「复制译文」。"]
        case .formulaRecognition:
            return ["首次使用先运行安装包中的 Install Formula.command，安装本地公式模型。",
                    "截图只框住公式，在编辑工具栏选择「公式识别」。",
                    "核对或修改 LaTeX，预览会同步更新，可复制 LaTeX 或公式图片。"]
        case .tableRecognition:
            return ["从菜单栏选择「表格识别」，尽量完整框住表格，避免多余背景。",
                    "核对识别出的行与列，尤其是合并单元格及复杂表头。",
                    "识别结果会以 CSV 文本复制到剪贴板，粘贴到电子表格后核对数据。"]
        case .floatingBall:
            return ["在「设置 → 通用 → 外观」打开悬浮球，也可使用已配置的悬浮球快捷键。",
                    "点击球体开始截图；右键可以直接启动贴图、长截图、录屏或文字识别。",
                    "拖动到任意屏幕，靠近边缘会吸附并淡化；鼠标靠近恢复亮度。"]
        case .keyboardMouseRecording:
            return ["在「设置 → 录屏」选择是否显示按键、鼠标点击，以及麦克风或摄像头。",
                    "截图框选后点「录屏」沿用当前区域，或从菜单栏启动屏幕录制。",
                    "结束录制后在预览中播放，保存视频，或点「复制 GIF」发送动图。"]
        }
    }

    public var note: String {
        switch self {
        case .captureAndAnnotate: return "快捷键可在「设置 → 快捷键」点击录制后直接修改。"
        case .clipboardPin: return "贴图和最近关闭记录仅保存在本机；分组面板可恢复关闭记录。"
        case .longScreenshot: return "滚动时保持窗口大小不变，等页面图片加载完成再继续。"
        case .ocrAndTranslate: return "设备端翻译需要 macOS 15 或更新版本，首次使用可能下载语言包。"
        case .formulaRecognition: return "模型安装后在本机识别，复杂公式仍需人工核对。"
        case .tableRecognition: return "识别质量取决于原图清晰度；导出前请核对数字与列顺序。"
        case .floatingBall: return "隐藏后可从设置重新打开；桌面工具栏也在外观设置中开启。"
        case .keyboardMouseRecording: return "GIF 不包含声音。麦克风和摄像头仅在开启相应选项时使用。"
        }
    }

    public var icon: IconSet {
        switch self {
        case .captureAndAnnotate: return .crop
        case .clipboardPin: return .pin
        case .longScreenshot: return .longShot
        case .ocrAndTranslate: return .ocr
        case .formulaRecognition: return .text
        case .tableRecognition: return .tableRecognize
        case .floatingBall: return .more
        case .keyboardMouseRecording: return .record
        }
    }
}

/// 引导播放器：按顺序播放场景，点击跳过/下一步。
public final class TutorialPlayer {
    public private(set) var scenes: [TutorialScene]
    public private(set) var currentIndex: Int = 0
    public var onSceneChange: ((TutorialScene) -> Void)?

    public init(scenes: [TutorialScene] = TutorialScene.allCases) {
        self.scenes = scenes
    }

    public var current: TutorialScene? {
        scenes.indices.contains(currentIndex) ? scenes[currentIndex] : nil
    }

    public var isFinished: Bool {
        currentIndex >= scenes.count
    }

    public func next() {
        guard !isFinished else { return }
        currentIndex += 1
        if let current {
            onSceneChange?(current)
        }
    }

    public func skip() {
        currentIndex = scenes.count
    }

    public func restart() {
        currentIndex = 0
        if let current {
            onSceneChange?(current)
        }
    }
}

// MARK: - 视图

/// 使用指南卡片：可直接按顺序完成的操作说明。
public struct TutorialCardView: View {
    public var theme: Theme
    public var scene: TutorialScene
    public var currentIndex: Int
    public var totalCount: Int
    public var onNext: () -> Void
    public var onSkip: () -> Void

    public init(
        theme: Theme,
        scene: TutorialScene,
        currentIndex: Int,
        totalCount: Int,
        onNext: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.theme = theme
        self.scene = scene
        self.currentIndex = currentIndex
        self.totalCount = totalCount
        self.onNext = onNext
        self.onSkip = onSkip
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconView(icon: scene.icon, size: 28, color: theme.token(.primary))
                VStack(alignment: .leading, spacing: 6) {
                    Text(scene.title).font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(theme.token(.foreground))
                    Text(scene.subtitle).font(.system(size: 12))
                        .foregroundStyle(theme.token(.mutedForeground))
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(scene.instructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(theme.token(.muted), in: Circle())
                        Text(instruction).font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .foregroundStyle(theme.token(.foreground))
            .padding(.vertical, 24)
            Text(scene.note).font(.system(size: 11))
                .foregroundStyle(theme.token(.mutedForeground))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)

            HStack(spacing: 6) {
                ForEach(0..<totalCount, id: \.self) { index in
                    Capsule()
                        .fill(index == currentIndex ? theme.token(.primary) : theme.token(.border))
                        .frame(width: index == currentIndex ? 16 : 6, height: 6)
                }
                Spacer()
                SnapButton("关闭", theme: theme, variant: .ghost, size: .sm, action: onSkip)
                SnapButton(currentIndex + 1 == totalCount ? "完成" : "下一步", theme: theme, variant: .primary, size: .sm, action: onNext)
            }
            .animation(Interaction.toggle, value: currentIndex)
            .padding(.top, 18)
        }
        .padding(18)
        .frame(width: 460, height: 420)
        .senPanelStyle(theme: theme, radius: theme.metrics.radiusXL)
    }
}

import AppKit
import Foundation
import TapSnapSystem

/// 设置中可绑定快捷键的动作。
public enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    case screenshot
    case quickCapture
    case captureLastRegion
    case screenshotAndPin
    case pinFromClipboard
    case longShot
    case recordScreen
    case ocrRegion
    case quickOCR
    case ocrFullScreen
    case quickTranslate
    case showToolBall
    case showHistory

    public var displayName: String {
        switch self {
        case .screenshot: return "截图"
        case .quickCapture: return "极速截图（松手即输出）"
        case .captureLastRegion: return "重截上次区域"
        case .screenshotAndPin: return "截图并贴图"
        case .pinFromClipboard: return "剪贴板贴图"
        case .longShot: return "长截图"
        case .recordScreen: return "屏幕录制"
        case .ocrRegion: return "区域文字识别"
        case .quickOCR: return "极速取字"
        case .ocrFullScreen: return "全屏文字识别"
        case .quickTranslate: return "截图秒译"
        case .showToolBall: return "显示/隐藏悬浮球"
        case .showHistory: return "剪贴板历史"
        }
    }
}

/// 用户自定义的按键绑定。
public struct KeyBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    /// Carbon 修饰位（cmdKey / shiftKey / optionKey / controlKey）。
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= GlobalShortcut.Combo.command }
        if flags.contains(.control) { modifiers |= GlobalShortcut.Combo.control }
        if flags.contains(.option) { modifiers |= GlobalShortcut.Combo.option }
        if flags.contains(.shift) { modifiers |= GlobalShortcut.Combo.shift }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    public var combo: GlobalShortcut.Combo {
        GlobalShortcut.Combo(keyCode: keyCode, carbonModifiers: modifiers)
    }

    public var displayString: String {
        combo.displayString
    }
}

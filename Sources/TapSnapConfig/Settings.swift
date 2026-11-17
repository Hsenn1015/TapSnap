import Foundation
import TapSnapCore
import TapSnapPrivacy
import TapSnapSystem

public enum SelectionBorderStyle: String, CaseIterable, Sendable {
    case aurora, pixelSteps, twoTonePrint, fabricStitch, iceMint, monochrome, viewfinder, amberDash, coolWhiteSweep

    public var displayName: String {
        switch self {
        case .aurora: return "极光"
        case .pixelSteps: return "像素阶梯"
        case .twoTonePrint: return "双色套印"
        case .fabricStitch: return "布纹缝线"
        case .iceMint: return "冰蓝薄荷"
        case .monochrome: return "黑白双线"
        case .viewfinder: return "四角取景"
        case .amberDash: return "琥珀虚线"
        case .coolWhiteSweep: return "冷白追光"
        }
    }
}

/// 全部可持久化配置。字段按功能分组，字段名即 JSON key。
///
/// 按功能分组的 Codable 数据模型，可一次性读写。
public struct Settings: Codable, Hashable, Sendable {
    public struct Capture: Codable, Hashable, Sendable {
        public var hideDesktopIcons = false
        public var playShutterSound = true
        public var autoCopyToClipboard = true
        public var autoSaveToFile = false
        public var saveDirectory = AppPaths.defaultSaveDirectory.path
        public var saveFormat = "png"
        public var jpegQuality = 0.9
        public var showMagnifier = true
        public var showSelectionSize = true
        private var selectionBorder: String?
        public var selectionBorderStyle: SelectionBorderStyle {
            get { selectionBorder.flatMap(SelectionBorderStyle.init(rawValue:)) ?? .aurora }
            set { selectionBorder = newValue == .aurora ? nil : newValue.rawValue }
        }
        /// 上次确认的选区（屏幕全局坐标），用来在下次截图时回显。
        public var lastSelection: CGRect?

        public init() {}
    }

    public struct Pin: Codable, Hashable, Sendable {
        public var defaultOpacity = 1.0
        public var alwaysOnTop = true
        public var doubleClickToClose = false
        public var showShadow = true
        public var snapToEdges = true

        public init() {}
    }

    public struct Annotate: Codable, Hashable, Sendable {
        public var defaultColorHex = "#FF3B30"
        public var defaultLineWidth = 3.0
        public var defaultFontSize = 14.0
        public var mosaicBlockSize = 12
        public var autoMosaicDetectsFaces = false
        public var magnifierZoom = 2.0

        public init() {}
    }

    public struct OCR: Codable, Hashable, Sendable {
        public var languages = ["zh-Hans", "en-US"]
        public var autoCopyText = true
        public var joinLinesWithSpace = false

        public init() {}
    }

    public struct LongShot: Codable, Hashable, Sendable {
        public var autoScroll = true
        public var scrollStep = 200
        public var scrollIntervalMs = 500
        public var overlapRatio = 0.4

        public init() {}
    }

    public struct Record: Codable, Hashable, Sendable {
        public var frameRate = 30
        public var includesCursor = true
        public var includesMicrophone = false
        public var includesSystemAudio = false
        public var format = "mp4"
        public var includesCamera = false
        public var showsKeyPresses = false
        public var showsMouseClicks = false

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case frameRate, includesCursor, includesMicrophone, includesSystemAudio, format
            case includesCamera, showsKeyPresses, showsMouseClicks
        }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            frameRate = try values.decodeIfPresent(Int.self, forKey: .frameRate) ?? 30
            includesCursor = try values.decodeIfPresent(Bool.self, forKey: .includesCursor) ?? true
            includesMicrophone = try values.decodeIfPresent(Bool.self, forKey: .includesMicrophone) ?? false
            includesSystemAudio = try values.decodeIfPresent(Bool.self, forKey: .includesSystemAudio) ?? false
            format = try values.decodeIfPresent(String.self, forKey: .format) ?? "mp4"
            includesCamera = try values.decodeIfPresent(Bool.self, forKey: .includesCamera) ?? false
            showsKeyPresses = try values.decodeIfPresent(Bool.self, forKey: .showsKeyPresses) ?? false
            showsMouseClicks = try values.decodeIfPresent(Bool.self, forKey: .showsMouseClicks) ?? false
        }
    }

    public struct Appearance: Codable, Hashable, Sendable {
        public var useDarkTheme = true
        // 旧配置键保留兼容；编辑器工具栏始终固定在底部。
        public var toolBarPosition = "bottom"
        public var showDesktopBar = false

        public init() {}
        private enum CodingKeys: String, CodingKey { case useDarkTheme, toolBarPosition, showDesktopBar }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            useDarkTheme = try values.decodeIfPresent(Bool.self, forKey: .useDarkTheme) ?? true
            toolBarPosition = "bottom"
            showDesktopBar = try values.decodeIfPresent(Bool.self, forKey: .showDesktopBar) ?? false
        }
    }

    public var capture = Capture()
    public var pin = Pin()
    public var annotate = Annotate()
    public var ocr = OCR()
    public var longShot = LongShot()
    public var record = Record()
    public var appearance = Appearance()
    private var privacyRules: PrivacySettings?
    public var privacy: PrivacySettings {
        get { privacyRules ?? PrivacySettings() }
        set { privacyRules = newValue }
    }
    public var shortcuts: [String: KeyBinding] = [:]
    /// 配置结构版本。老文件里没有这个键（解码为 nil），用来判断要不要补默认值。
    public var schemaVersion: Int?

    public static let currentSchemaVersion = 5

    public init() {}

    /// 首次启动时给每个动作填一组默认快捷键。
    public static func withDefaultShortcuts() -> Settings {
        var settings = Settings()
        settings.schemaVersion = currentSchemaVersion
        // 长截图用 L，避开 macOS 自带的 ⌘⇧3 全屏截图。
        settings.shortcuts[ShortcutAction.screenshot.rawValue] =
            KeyBinding(keyCode: 18, modifiers: GlobalShortcut.Combo.control)
        settings.shortcuts[ShortcutAction.screenshotAndPin.rawValue] =
            KeyBinding(keyCode: 19, modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)
        settings.shortcuts[ShortcutAction.longShot.rawValue] =
            KeyBinding(keyCode: 37, modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)
        settings.shortcuts[ShortcutAction.pinFromClipboard.rawValue] =
            KeyBinding(keyCode: 9, modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)
        settings.shortcuts[ShortcutAction.recordScreen.rawValue] =
            KeyBinding(keyCode: 15, modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)
        settings.shortcuts[ShortcutAction.ocrRegion.rawValue] =
            KeyBinding(keyCode: 31, modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)
        settings.shortcuts[ShortcutAction.showHistory.rawValue] =
            KeyBinding(keyCode: 4, modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)
        return settings
    }
}

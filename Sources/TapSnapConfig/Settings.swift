import Foundation
import TapSnapCore
import TapSnapPrivacy
import TapSnapSystem

public enum ScreenshotTranslationProvider: String, CaseIterable, Codable, Sendable {
    case apple, api, local, online

    public var title: String {
        switch self {
        case .apple: return "Apple 离线"
        case .api: return "翻译 API"
        case .local: return "本机模型"
        case .online: return "在线模型"
        }
    }
}

public enum TranslationFontFamily: String, CaseIterable, Codable, Hashable, Sendable {
    case system, serif, rounded, monospaced

    public var title: String {
        switch self {
        case .system: return "系统默认"
        case .serif: return "衬线"
        case .rounded: return "圆体"
        case .monospaced: return "等宽"
        }
    }
}

public enum TranslationAccentPreset: String, CaseIterable, Codable, Hashable, Sendable {
    case amber, blue, emerald, violet, rose, neutral

    public var title: String {
        switch self {
        case .amber: return "琥珀金"
        case .blue: return "天空蓝"
        case .emerald: return "翡翠绿"
        case .violet: return "紫罗兰"
        case .rose: return "珊瑚粉"
        case .neutral: return "极简灰"
        }
    }

    public var rgb: RGBAColor {
        switch self {
        case .amber: return RGBAColor(red: 0.96, green: 0.72, blue: 0.24, alpha: 1)
        case .blue: return RGBAColor(red: 0.29, green: 0.62, blue: 1.00, alpha: 1)
        case .emerald: return RGBAColor(red: 0.20, green: 0.78, blue: 0.56, alpha: 1)
        case .violet: return RGBAColor(red: 0.68, green: 0.49, blue: 0.98, alpha: 1)
        case .rose: return RGBAColor(red: 0.96, green: 0.42, blue: 0.56, alpha: 1)
        case .neutral: return RGBAColor(red: 0.64, green: 0.66, blue: 0.70, alpha: 1)
        }
    }
}

public struct TranslationTypographyStyle: Codable, Hashable, Sendable {
    public var sourceFontSize: Double = 13
    public var targetFontSize: Double = 14.5
    public var fontFamily: TranslationFontFamily = .system
    public var lineSpacing: Double = 5
    public var accent: TranslationAccentPreset = .amber

    public init() {}

    public static let `default` = TranslationTypographyStyle()
}

public struct ScreenshotTranslationSettings: Codable, Hashable, Sendable {
    public var provider: ScreenshotTranslationProvider?
    public var targetLanguage = "zh-Hans"
    public var apiProvider: TranslationAPIProvider = .google
    public var onlineProvider: PrivacyAIProvider = .deepSeek
    public var autoTranslateOnOpen = true
    public var style: TranslationTypographyStyle = .default
    private var profiles: [String: PrivacyAIConfiguration] = [:]
    private var apiProfiles: [String: TranslationAPIConfiguration] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case provider, targetLanguage, apiProvider, onlineProvider, autoTranslateOnOpen, style, profiles, apiProfiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(ScreenshotTranslationProvider.self, forKey: .provider)
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "zh-Hans"
        apiProvider = try container.decodeIfPresent(TranslationAPIProvider.self, forKey: .apiProvider) ?? .google
        onlineProvider = try container.decodeIfPresent(PrivacyAIProvider.self, forKey: .onlineProvider) ?? .deepSeek
        autoTranslateOnOpen = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateOnOpen) ?? true
        style = try container.decodeIfPresent(TranslationTypographyStyle.self, forKey: .style) ?? .default
        profiles = try container.decodeIfPresent([String: PrivacyAIConfiguration].self, forKey: .profiles) ?? [:]
        apiProfiles = try container.decodeIfPresent([String: TranslationAPIConfiguration].self, forKey: .apiProfiles) ?? [:]
    }

    public var modelConfiguration: PrivacyAIConfiguration? {
        guard provider == .local || provider == .online else { return nil }
        let preset: PrivacyAIProvider = provider == .local ? .local : onlineProvider
        return profiles[preset.rawValue] ?? PrivacyAIConfiguration(provider: preset)
    }

    public mutating func saveModel(_ model: PrivacyAIConfiguration) {
        profiles[model.provider.rawValue] = model
    }

    public var apiConfiguration: TranslationAPIConfiguration? {
        guard provider == .api else { return nil }
        return apiProfiles[apiProvider.rawValue] ?? TranslationAPIConfiguration(provider: apiProvider)
    }

    public mutating func saveAPI(_ api: TranslationAPIConfiguration) {
        apiProfiles[api.provider.rawValue] = api
    }
}

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
        /// 从左到右的常用按钮。nil 使用默认布局，空数组将所有可选按钮放进「更多」。
        public var selectionToolbarActions: [String]?
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
    private var screenshotTranslation: ScreenshotTranslationSettings?
    public var translation: ScreenshotTranslationSettings {
        get { screenshotTranslation ?? ScreenshotTranslationSettings() }
        set { screenshotTranslation = newValue }
    }
    public var longShot = LongShot()
    public var record = Record()
    public var appearance = Appearance()
    private var privacyRules: PrivacySettings?
    public var privacy: PrivacySettings {
        get { privacyRules ?? PrivacySettings() }
        set { privacyRules = newValue }
    }
    public var shortcuts: [String: KeyBinding] = [:]
    /// 缺省时用操作默认键位。保存过的字典里，缺少的动作视为已清除。
    public var operationShortcuts: [String: KeyBinding]?
    /// 配置结构版本。老文件里没有这个键（解码为 nil），用来判断要不要补默认值。
    public var schemaVersion: Int?

    public static let currentSchemaVersion = 6

    public init() {}

    /// 开发版的全局快捷键留空，由用户选择与正式版不同的组合。
    public static func withDefaultShortcuts(includesGlobalShortcuts: Bool = !AppPaths.isDevelopmentBuild) -> Settings {
        var settings = Settings()
        settings.schemaVersion = currentSchemaVersion
        guard includesGlobalShortcuts else { return settings }
        // 长截图用 L，避开 macOS 自带的 ⌘⇧3 全屏截图。
        settings.shortcuts[ShortcutAction.screenshot.rawValue] =
            KeyBinding(keyCode: 18, modifiers: GlobalShortcut.Combo.command | GlobalShortcut.Combo.shift)
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

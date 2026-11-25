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

/// 截图秒译（松手即译悬停浮卡）的框选标识与浮卡视觉风格。
public enum QuickTranslateStyle: String, CaseIterable, Codable, Hashable, Sendable {
    case cleanCard
    case liquidGlass
    case editorial
    case inlineBilingual
    case dynamicBubble

    public var displayName: String {
        switch self {
        case .cleanCard: return "极简分块卡片"
        case .liquidGlass: return "液态玻璃语义胶囊"
        case .editorial: return "聚光取词取景器"
        case .inlineBilingual: return "原地双语高亮卡"
        case .dynamicBubble: return "灵动岛气泡卡"
        }
    }

    public var summary: String {
        switch self {
        case .cleanCard: return "macOS 原生分块白/深灰卡：原文块 + 语言互换条 + 译文块，支持朗读与改字"
        case .liquidGlass: return "冰蓝靛紫液态毛玻璃 + 「译」胶囊徽标与指向尖角浮卡"
        case .editorial: return "轻暗幕四角取景框 + 3pt 渐变色条无顶栏首行直出译文"
        case .inlineBilingual: return "柔和琥珀高亮原选区 + 三态切换（仅译文 / 双语对照 / 覆盖原文）"
        case .dynamicBubble: return "薄荷绿灵动岛加载胶囊展开气泡 + 外侧竖排迷你动作豆"
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
    private var quickTranslateStyleRaw: String?
    private var profiles: [String: PrivacyAIConfiguration] = [:]
    private var apiProfiles: [String: TranslationAPIConfiguration] = [:]

    public var quickTranslateStyle: QuickTranslateStyle {
        get { quickTranslateStyleRaw.flatMap(QuickTranslateStyle.init(rawValue:)) ?? .cleanCard }
        set { quickTranslateStyleRaw = newValue == .cleanCard ? nil : newValue.rawValue }
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case provider, targetLanguage, apiProvider, onlineProvider, autoTranslateOnOpen, style, profiles, apiProfiles
        case quickTranslateStyleRaw = "quickTranslateStyle"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(ScreenshotTranslationProvider.self, forKey: .provider)
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "zh-Hans"
        apiProvider = try container.decodeIfPresent(TranslationAPIProvider.self, forKey: .apiProvider) ?? .google
        onlineProvider = try container.decodeIfPresent(PrivacyAIProvider.self, forKey: .onlineProvider) ?? .deepSeek
        autoTranslateOnOpen = try container.decodeIfPresent(Bool.self, forKey: .autoTranslateOnOpen) ?? true
        style = try container.decodeIfPresent(TranslationTypographyStyle.self, forKey: .style) ?? .default
        quickTranslateStyleRaw = try container.decodeIfPresent(String.self, forKey: .quickTranslateStyleRaw)
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

public enum RecordingMouseClickStyle: String, CaseIterable, Sendable {
    case liquidRipple
    case squareBracket
    case miniMouse
    case opticalFocus
    case orbitalSweep
    case microSpark
    case tactileGlass
    case crosshairSnap
    case spotlightHalo
    case sonarTriple
    case dualPulse
    case diamondPrism
    case liquidPetal
    case keycapBadge

    public var displayName: String {
        switch self {
        case .liquidRipple: return "液态玻璃水波"
        case .squareBracket: return "方框角标轻扣"
        case .miniMouse: return "迷你鼠标亮键"
        case .opticalFocus: return "精密靶环合焦"
        case .orbitalSweep: return "轨道一笔画弧"
        case .microSpark: return "极简微粒迸散"
        case .tactileGlass: return "触控玻璃压痕"
        case .crosshairSnap: return "精密十字轻锁"
        case .spotlightHalo: return "无框聚光微晕"
        case .sonarTriple: return "声纳极细三波"
        case .dualPulse: return "双轨脉冲环"
        case .diamondPrism: return "棱镜菱形切晶"
        case .liquidPetal: return "露珠四瓣绽放"
        case .keycapBadge: return "键标微泡提示"
        }
    }
}

public enum RecordingMouseScrollStyle: String, CaseIterable, Sendable {
    case glassPill
    case kineticChevron
    case wheelTicks
    case silkyStream
    case arcWave

    public var displayName: String {
        switch self {
        case .glassPill: return "液态滚动胶囊"
        case .kineticChevron: return "双层导向箭羽"
        case .wheelTicks: return "精密滚轮刻度"
        case .silkyStream: return "轻盈水流尾迹"
        case .arcWave: return "方向弧波"
        }
    }
}

public enum RecordingMouseEffectPalette: String, CaseIterable, Sendable {
    case glassBlue
    case applePure
    case leicaCoral
    case mintTeal
    case goldAmber

    public var displayName: String {
        switch self {
        case .glassBlue: return "液态冰蓝"
        case .applePure: return "纯净白晶"
        case .leicaCoral: return "徕卡橘红"
        case .mintTeal: return "薄荷青翠"
        case .goldAmber: return "香槟暖金"
        }
    }
}

public enum PinShadowStyle: String, CaseIterable, Sendable {
    case auroraAmbient, elevation, ambilight, frostedBezel, crispPaper, neonHalo

    public var displayName: String {
        switch self {
        case .auroraAmbient: return "极光环境柔晕"
        case .elevation: return "物理悬浮深影"
        case .ambilight: return "自适应取色溢光"
        case .frostedBezel: return "磨砂玻璃画框"
        case .crispPaper: return "锐利纸片硬影"
        case .neonHalo: return "电光聚焦微晕"
        }
    }
}

public enum SelectionBorderStyle: String, CaseIterable, Sendable {
    case liquidGlass, viewfinder, editorial, pixelSteps, titanium, fabricStitch, dualWingHUD

    public var displayName: String {
        switch self {
        case .liquidGlass: return "液态玻璃"
        case .viewfinder: return "光学取景器"
        case .editorial: return "瑞士极简线"
        case .pixelSteps: return "精致像素工艺"
        case .titanium: return "阳极钛金属"
        case .fabricStitch: return "匠心缝线"
        case .dualWingHUD: return "双翼锁角"
        }
    }

    public var availableMotions: [SelectionBorderMotion] {
        switch self {
        case .liquidGlass:
            return [.diagonalGlint, .dewdropPulse, .dualSlide, .cornerBloom, .refractionTurn, .verticalTide]
        case .viewfinder:
            return [.focusLock, .rangeScan, .apertureBreathe]
        case .editorial:
            return [.silkyDash, .penGlider, .cornerNodes]
        case .pixelSteps:
            return [.pixelMarch, .pixelCorners, .crtScan]
        case .titanium:
            return [.brushedSheen, .chromeEdge, .titaniumBreathe]
        case .fabricStitch:
            return [.runningStitch, .threadSheen, .cornerKnots]
        case .dualWingHUD:
            return [.hudBrackets, .tickWave, .pingDot]
        }
    }

    public var defaultMotion: SelectionBorderMotion { availableMotions[0] }

    public var availablePalettes: [SelectionBorderPalette] {
        switch self {
        case .liquidGlass:
            return [.glacier, .seasalt, .silverMist, .warmPearl, .titaniumIce, .motherOfPearl]
        case .viewfinder:
            return [.leica, .hasselblad, .cinemaCyan, .nightAmber]
        case .editorial:
            return [.swissMono, .linearIndigo, .braunOrange, .emerald]
        case .pixelSteps:
            return [.cyberPixel, .gameboy, .amberTerminal, .candyMint]
        case .titanium:
            return [.naturalTi, .desertTi, .spaceBlack, .cobaltTi]
        case .fabricStitch:
            return [.saddle, .denim, .forestCraft, .linen]
        case .dualWingHUD:
            return [.teOrange, .oscGreen, .avionics, .starship]
        }
    }

    public var defaultPalette: SelectionBorderPalette { availablePalettes[0] }

    /// 兼容旧版本保存的边框样式标识。
    public static func fromPersistedRawValue(_ raw: String) -> SelectionBorderStyle? {
        if let direct = SelectionBorderStyle(rawValue: raw) { return direct }
        switch raw {
        case "aurora", "iceMint", "coolWhiteSweep": return .liquidGlass
        case "monochrome": return .editorial
        case "amberDash": return .dualWingHUD
        case "twoTonePrint": return .titanium
        default: return nil
        }
    }
}

public enum SelectionBorderMotion: String, CaseIterable, Sendable {
    // 液态玻璃
    case diagonalGlint, dewdropPulse, dualSlide, cornerBloom, refractionTurn, verticalTide
    // 光学取景器
    case focusLock, rangeScan, apertureBreathe
    // 瑞士极简线
    case silkyDash, penGlider, cornerNodes
    // 精致像素工艺
    case pixelMarch, pixelCorners, crtScan
    // 阳极钛金属
    case brushedSheen, chromeEdge, titaniumBreathe
    // 匠心缝线
    case runningStitch, threadSheen, cornerKnots
    // 双翼锁角（精密仪表）
    case hudBrackets, tickWave, pingDot

    public var displayName: String {
        switch self {
        case .diagonalGlint: return "静谧折光"
        case .dewdropPulse: return "水膜呼吸"
        case .dualSlide: return "双液滴对滑"
        case .cornerBloom: return "四角折晶"
        case .refractionTurn: return "棱镜缓转"
        case .verticalTide: return "水光垂拂"
        case .focusLock: return "对焦轻合"
        case .rangeScan: return "测距扫描"
        case .apertureBreathe: return "光圈呼吸"
        case .silkyDash: return "现代丝滑虚线"
        case .penGlider: return "笔尖单丝滑行"
        case .cornerNodes: return "精密十字节点"
        case .pixelMarch: return "点阵步进"
        case .pixelCorners: return "像素角标轻跳"
        case .crtScan: return "像素扫屏"
        case .brushedSheen: return "拉丝掠光"
        case .chromeEdge: return "双面镜棱"
        case .titaniumBreathe: return "冷冽呼吸"
        case .runningStitch: return "慢针走线"
        case .threadSheen: return "丝线光泽"
        case .cornerKnots: return "四角锁针"
        case .hudBrackets: return "双翼锁角"
        case .tickWave: return "刻度波浪"
        case .pingDot: return "脉冲信标"
        }
    }

    public var cycleDuration: Double {
        switch self {
        case .diagonalGlint: return 3.2
        case .dewdropPulse: return 2.8
        case .dualSlide: return 3.6
        case .cornerBloom: return 3.4
        case .refractionTurn: return 4.4
        case .verticalTide: return 3.0
        case .focusLock: return 2.4
        case .rangeScan: return 2.8
        case .apertureBreathe: return 3.6
        case .silkyDash: return 3.2
        case .penGlider: return 3.6
        case .cornerNodes: return 3.0
        case .pixelMarch: return 2.4
        case .pixelCorners: return 2.0
        case .crtScan: return 2.2
        case .brushedSheen: return 3.0
        case .chromeEdge: return 3.8
        case .titaniumBreathe: return 3.6
        case .runningStitch: return 3.0
        case .threadSheen: return 3.2
        case .cornerKnots: return 3.0
        case .hudBrackets: return 2.4
        case .tickWave: return 2.4
        case .pingDot: return 3.4
        }
    }
}

public enum SelectionBorderPalette: String, CaseIterable, Sendable {
    // 液态玻璃
    case glacier, seasalt, silverMist, warmPearl, titaniumIce, motherOfPearl
    // 光学取景器
    case leica, hasselblad, cinemaCyan, nightAmber
    // 瑞士极简线
    case swissMono, linearIndigo, braunOrange, emerald
    // 精致像素工艺
    case cyberPixel, gameboy, amberTerminal, candyMint
    // 阳极钛金属
    case naturalTi, desertTi, spaceBlack, cobaltTi
    // 匠心缝线
    case saddle, denim, forestCraft, linen
    // 双翼锁角（精密仪表）
    case teOrange, oscGreen, avionics, starship

    public var displayName: String {
        switch self {
        case .glacier: return "冰川白晶"
        case .seasalt: return "海盐薄荷"
        case .silverMist: return "暮雾银紫"
        case .warmPearl: return "香槟珠光"
        case .titaniumIce: return "极夜钛蓝"
        case .motherOfPearl: return "珍珠母贝"
        case .leica: return "徕卡红白"
        case .hasselblad: return "哈苏冷钛"
        case .cinemaCyan: return "电影冷青"
        case .nightAmber: return "夜视琥珀"
        case .swissMono: return "瑞士黑白"
        case .linearIndigo: return "Linear 靛蓝"
        case .braunOrange: return "博朗国际橙"
        case .emerald: return "松石翡翠"
        case .cyberPixel: return "霓虹紫青"
        case .gameboy: return "掌机翠绿"
        case .amberTerminal: return "琥珀终端"
        case .candyMint: return "薄荷桃子"
        case .naturalTi: return "原色钛金"
        case .desertTi: return "沙漠金钛"
        case .spaceBlack: return "深空黑钛"
        case .cobaltTi: return "冰蓝铝钛"
        case .saddle: return "鞍革焦糖"
        case .denim: return "丹宁靛蓝"
        case .forestCraft: return "英伦墨绿"
        case .linen: return "亚麻炭灰"
        case .teOrange: return "TE 工程橘"
        case .oscGreen: return "示波荧光绿"
        case .avionics: return "航电冰蓝"
        case .starship: return "星舰琥珀"
        }
    }
}

public struct SelectionBorderConfiguration: Equatable, Hashable, Sendable {
    public var style: SelectionBorderStyle
    public var motion: SelectionBorderMotion
    public var palette: SelectionBorderPalette

    public init(
        style: SelectionBorderStyle = .liquidGlass,
        motion: SelectionBorderMotion? = nil,
        palette: SelectionBorderPalette? = nil
    ) {
        self.style = style
        if let motion, style.availableMotions.contains(motion) {
            self.motion = motion
        } else {
            self.motion = style.defaultMotion
        }
        if let palette, style.availablePalettes.contains(palette) {
            self.palette = palette
        } else {
            self.palette = style.defaultPalette
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
        private var allowDemoCapture: Bool?
        /// 演示模式：开启后允许系统录屏、第三方录屏或双开 TapSnap 捕获本应用的选区、贴图与工具栏。
        public var allowSelfCapture: Bool {
            get { allowDemoCapture ?? false }
            set { allowDemoCapture = newValue ? true : nil }
        }
        private var selectionBorder: String?
        private var selectionBorderMotionRaw: String?
        private var selectionBorderPaletteRaw: String?
        public var selectionBorderStyle: SelectionBorderStyle {
            get { selectionBorder.flatMap(SelectionBorderStyle.fromPersistedRawValue) ?? .liquidGlass }
            set {
                selectionBorder = newValue == .liquidGlass ? nil : newValue.rawValue
                if !newValue.availableMotions.contains(selectionBorderMotion) {
                    selectionBorderMotionRaw = nil
                }
                if !newValue.availablePalettes.contains(selectionBorderPalette) {
                    selectionBorderPaletteRaw = nil
                }
            }
        }
        public var selectionBorderMotion: SelectionBorderMotion {
            get {
                let style = selectionBorderStyle
                if let raw = selectionBorderMotionRaw,
                   let parsed = SelectionBorderMotion(rawValue: raw),
                   style.availableMotions.contains(parsed) {
                    return parsed
                }
                return style.defaultMotion
            }
            set {
                let style = selectionBorderStyle
                guard style.availableMotions.contains(newValue) else { return }
                selectionBorderMotionRaw = newValue == style.defaultMotion ? nil : newValue.rawValue
            }
        }
        public var selectionBorderPalette: SelectionBorderPalette {
            get {
                let style = selectionBorderStyle
                if let raw = selectionBorderPaletteRaw,
                   let parsed = SelectionBorderPalette(rawValue: raw),
                   style.availablePalettes.contains(parsed) {
                    return parsed
                }
                return style.defaultPalette
            }
            set {
                let style = selectionBorderStyle
                guard style.availablePalettes.contains(newValue) else { return }
                selectionBorderPaletteRaw = newValue == style.defaultPalette ? nil : newValue.rawValue
            }
        }
        public var selectionBorderConfiguration: SelectionBorderConfiguration {
            SelectionBorderConfiguration(
                style: selectionBorderStyle,
                motion: selectionBorderMotion,
                palette: selectionBorderPalette
            )
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
        private var shadowStyleRaw: String?
        private var shadowDepthScale: Double?
        private var shadowSpreadScale: Double?

        public var shadowStyle: PinShadowStyle {
            get { shadowStyleRaw.flatMap(PinShadowStyle.init(rawValue:)) ?? .auroraAmbient }
            set { shadowStyleRaw = newValue == .auroraAmbient ? nil : newValue.rawValue }
        }
        /// 阴影浓淡倍率（0.5 ~ 1.6，默认 1.0）。
        public var shadowIntensity: Double {
            get { min(max(shadowDepthScale ?? 1.0, 0.5), 1.6) }
            set {
                let clamped = min(max(newValue, 0.5), 1.6)
                shadowDepthScale = abs(clamped - 1.0) < 0.001 ? nil : clamped
            }
        }
        /// 阴影扩散范围倍率（0.6 ~ 1.5，默认 1.0）。
        public var shadowSpread: Double {
            get { min(max(shadowSpreadScale ?? 1.0, 0.6), 1.5) }
            set {
                let clamped = min(max(newValue, 0.6), 1.5)
                shadowSpreadScale = abs(clamped - 1.0) < 0.001 ? nil : clamped
            }
        }

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
        private var showsMouseScrollsRaw: Bool?
        private var mouseClickStyleRaw: String?
        private var mouseScrollStyleRaw: String?
        private var mouseEffectPaletteRaw: String?
        private var mouseEffectScaleRaw: Double?

        public var showsMouseScrolls: Bool {
            get { showsMouseScrollsRaw ?? false }
            set { showsMouseScrollsRaw = newValue ? true : nil }
        }
        public var mouseClickStyle: RecordingMouseClickStyle {
            get { mouseClickStyleRaw.flatMap(RecordingMouseClickStyle.init(rawValue:)) ?? .liquidRipple }
            set { mouseClickStyleRaw = newValue == .liquidRipple ? nil : newValue.rawValue }
        }
        public var mouseScrollStyle: RecordingMouseScrollStyle {
            get { mouseScrollStyleRaw.flatMap(RecordingMouseScrollStyle.init(rawValue:)) ?? .glassPill }
            set { mouseScrollStyleRaw = newValue == .glassPill ? nil : newValue.rawValue }
        }
        public var mouseEffectPalette: RecordingMouseEffectPalette {
            get { mouseEffectPaletteRaw.flatMap(RecordingMouseEffectPalette.init(rawValue:)) ?? .glassBlue }
            set { mouseEffectPaletteRaw = newValue == .glassBlue ? nil : newValue.rawValue }
        }
        /// 录屏鼠标动效尺寸倍率（0.75 ~ 1.45，默认 1.0）。
        public var mouseEffectScale: Double {
            get { min(max(mouseEffectScaleRaw ?? 1.0, 0.75), 1.45) }
            set {
                let clamped = min(max(newValue, 0.75), 1.45)
                mouseEffectScaleRaw = abs(clamped - 1.0) < 0.001 ? nil : clamped
            }
        }

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case frameRate, includesCursor, includesMicrophone, includesSystemAudio, format
            case includesCamera, showsKeyPresses, showsMouseClicks
            case showsMouseScrollsRaw = "showsMouseScrolls"
            case mouseClickStyleRaw = "mouseClickStyle"
            case mouseScrollStyleRaw = "mouseScrollStyle"
            case mouseEffectPaletteRaw = "mouseEffectPalette"
            case mouseEffectScaleRaw = "mouseEffectScale"
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
            showsMouseScrollsRaw = try values.decodeIfPresent(Bool.self, forKey: .showsMouseScrollsRaw)
            mouseClickStyleRaw = try values.decodeIfPresent(String.self, forKey: .mouseClickStyleRaw)
            mouseScrollStyleRaw = try values.decodeIfPresent(String.self, forKey: .mouseScrollStyleRaw)
            mouseEffectPaletteRaw = try values.decodeIfPresent(String.self, forKey: .mouseEffectPaletteRaw)
            mouseEffectScaleRaw = try values.decodeIfPresent(Double.self, forKey: .mouseEffectScaleRaw)
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

import Foundation
import TapSnapConfig
import TapSnapIcons

/// 截图工具栏上可出现的动作。
///
/// 左侧是标注工具，右侧是复制、保存等输出操作。
public enum ActionKind: String, Codable, CaseIterable, Sendable {
    // 标注工具
    case arrow
    case rectangle
    case ellipse
    case line
    case pen
    case text
    case mosaic
    case highlight
    case serialNumber
    case magnifier
    case watermark
    case pathTag
    case polygon
    case spotlight
    case eraser

    // 输出动作
    case edit
    case crop
    case save
    case exportImage
    case combineImages
    case copy
    case pin
    case ocr
    case translate
    case qrCode
    case longShot
    case tableRecognize
    case formula
    case print
    case record
    case privacy

    // 工具
    case undo
    case redo
    case cancel
    case confirm

    public var icon: IconSet {
        switch self {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .pen: return .pen
        case .text: return .text
        case .mosaic: return .mosaic
        case .highlight: return .highlight
        case .serialNumber: return .serialNumber
        case .magnifier: return .magnifier
        case .watermark: return .watermark
        case .pathTag: return .pathTag
        case .polygon: return .polygon
        case .spotlight: return .spotlight
        case .eraser: return .eraser
        case .edit: return .edit
        case .crop: return .crop
        case .save: return .save
        case .exportImage: return .save
        case .combineImages: return .copy
        case .copy: return .copy
        case .pin: return .pin
        case .ocr: return .ocr
        case .translate: return .translate
        case .qrCode: return .qrCode
        case .longShot: return .longShot
        case .tableRecognize: return .tableRecognize
        case .formula: return .text
        case .print: return .print
        case .record: return .record
        case .privacy: return .privacy
        case .undo: return .undo
        case .redo: return .redo
        case .cancel: return .close
        case .confirm: return .confirm
        }
    }

    public var title: String {
        switch self {
        case .formula: return "公式识别"
        case .exportImage: return "导出…"
        case .combineImages: return "追加一张图片…"
        default: return icon.accessibilityLabel
        }
    }

    public var exportsImage: Bool {
        switch self {
        case .save, .exportImage, .combineImages, .copy, .pin, .ocr, .translate, .qrCode, .tableRecognize, .formula, .print, .confirm:
            return true
        default:
            return false
        }
    }

    /// 标注类动作：点击后切换当前绘制工具，工具栏不消失。
    public var isAnnotationTool: Bool {
        switch self {
        case .arrow, .rectangle, .ellipse, .line, .pen, .text, .mosaic, .highlight,
             .serialNumber, .magnifier, .watermark, .pathTag, .polygon, .spotlight, .privacy, .eraser:
            return true
        default:
            return false
        }
    }

    /// 标注工具中有样式可调的按钮。
    public var hasOptionsPanel: Bool {
        isAnnotationTool && self != .eraser
    }

    /// 与配置里快捷键动作的映射关系（没有对应项返回 nil）。
    public var shortcutAction: ShortcutAction? {
        switch self {
        case .longShot: return .longShot
        case .record: return .recordScreen
        case .ocr: return .ocrRegion
        default: return nil
        }
    }
}

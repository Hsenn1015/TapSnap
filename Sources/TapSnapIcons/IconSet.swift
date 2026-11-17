import Foundation

/// 图标清单。
///
/// 将应用图标映射到 SF Symbols。
public enum IconSet: String, CaseIterable, Sendable {
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

    // 截图动作
    case edit
    case crop
    case save
    case copy
    case pin
    case ocr
    case translate
    case qrCode
    case longShot
    case record
    case tableRecognize
    case print
    case privacy

    // 通用
    case close
    case confirm
    case undo
    case redo
    case restart
    case delete
    case settings
    case shortcut
    case more
    case loading
    case info

    public var systemName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .pen: return "pencil.tip"
        case .text: return "t.square"
        case .mosaic: return "square.grid.3x3.fill"
        case .highlight: return "highlighter"
        case .serialNumber: return "number"
        case .magnifier: return "magnifyingglass"
        case .watermark: return "drop"
        case .pathTag: return "tag"
        case .polygon: return "pentagon"
        case .spotlight: return "circle.lefthalf.filled"
        case .eraser: return "eraser"
        case .edit: return "square.and.pencil"
        case .crop: return "crop"
        case .save: return "square.and.arrow.down"
        case .copy: return "doc.on.doc"
        case .pin: return "pin"
        case .ocr: return "text.viewfinder"
        case .translate: return "character.bubble"
        case .qrCode: return "qrcode"
        case .longShot: return "arrow.up.and.down"
        case .record: return "record.circle"
        case .tableRecognize: return "tablecells"
        case .print: return "printer"
        case .privacy: return "lock.shield"
        case .close: return "xmark"
        case .confirm: return "checkmark"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .restart: return "arrow.counterclockwise"
        case .delete: return "trash"
        case .settings: return "gearshape"
        case .shortcut: return "command"
        case .more: return "chevron.down"
        case .loading: return "arrow.triangle.2.circlepath"
        case .info: return "info.circle"
        }
    }

    /// 无障碍标签，供工具栏按钮使用。
    public var accessibilityLabel: String {
        switch self {
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .pen: return "画笔"
        case .text: return "文字标注"
        case .mosaic: return "马赛克"
        case .highlight: return "高亮"
        case .serialNumber: return "序号"
        case .magnifier: return "放大镜"
        case .watermark: return "水印"
        case .pathTag: return "路径标注"
        case .polygon: return "多边形"
        case .spotlight: return "聚光灯"
        case .eraser: return "橡皮"
        case .edit: return "编辑"
        case .crop: return "裁剪"
        case .save: return "保存"
        case .copy: return "复制"
        case .pin: return "贴图"
        case .ocr: return "文字识别"
        case .translate: return "翻译"
        case .qrCode: return "二维码"
        case .longShot: return "长截图"
        case .record: return "录制"
        case .tableRecognize: return "表格识别"
        case .print: return "打印"
        case .privacy: return "隐私打码"
        case .close: return "关闭"
        case .confirm: return "确定"
        case .undo: return "撤销"
        case .redo: return "重做"
        case .restart: return "重新录制"
        case .delete: return "删除"
        case .settings: return "设置"
        case .shortcut: return "快捷键"
        case .more: return "更多"
        case .loading: return "加载中"
        case .info: return "说明"
        }
    }
}

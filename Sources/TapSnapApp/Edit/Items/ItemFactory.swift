import Foundation
import TapSnapActionsBar

/// 根据工具栏动作创建对应的标注项。
///
/// 按所选工具创建图元，集中处理各类标注的构造细节。
enum EditItemFactory {
    static func makeSerial(at point: CGPoint, index: Int, style: EditItemStyle, format: SerialItem.Format = .numeric) -> SerialItem {
        SerialItem(index: index,
                   bounds: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22),
                   style: style, format: format)
    }

    static func make(kind: EditItemKind, from start: CGPoint, to end: CGPoint, style: EditItemStyle, options: EditToolOptions = EditToolOptions()) -> (any EditItem)? {
        switch kind {
        case .arrow:
            return ArrowItem(start: start, end: end, style: style, headStyle: options.arrowHead)
        case .line:
            return LineItem(start: start, end: end, style: style)
        case .rectangle, .ellipse:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            return ShapeItem(kind: kind, bounds: rect, style: style)
        case .pen:
            return PenItem(points: [start, end], style: style)
        case .text:
            return TextItem(bounds: CGRect(origin: start, size: CGSize(width: 120, height: 24)), style: style, background: options.textBackground)
        case .mosaic:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            return MosaicItem(bounds: rect, style: style, mode: options.mosaicMode, blockSize: options.mosaicBlockSize)
        case .highlight:
            return HighlightItem(points: start == end ? [start] : [start, end], style: style)
        case .serialNumber:
            return makeSerial(at: start, index: 1, style: style, format: options.serialFormat)
        case .magnifier:
            return MagnifierItem(bounds: CGRect(origin: start, size: CGSize(width: 100, height: 100)), style: style, zoom: options.magnifierZoom)
        case .watermark:
            guard options.watermarkKind != .image || options.watermarkImage != nil else { return nil }
            let dragged = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                 width: abs(end.x - start.x), height: abs(end.y - start.y))
            let bounds = dragged.width > 4 && dragged.height > 4
                ? dragged : CGRect(origin: start, size: CGSize(width: 200, height: 60))
            let item = WatermarkItem(text: options.watermarkText, bounds: bounds, style: style,
                                     angle: options.watermarkAngle, isTiled: options.watermarkTiled,
                                     capturedAt: options.captureDate)
            options.apply(to: item)
            return item
        case .pathTag:
            return PathTagItem(points: [start, end], style: style)
        case .polygon:
            return PolygonItem(points: [start, end], style: style)
        case .spotlight:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(start.x - end.x),
                height: abs(start.y - end.y)
            )
            return SpotlightItem(bounds: rect, style: style)
        case .privacy:
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard rect.width >= 2, rect.height >= 2 else { return nil }
            return PrivacyMaskItem(bounds: rect, appearance: options.privacyAppearance)
        }
    }

    /// 工具栏动作 -> 标注项种类；输出类动作返回 nil。
    static func itemKind(for action: ActionKind) -> EditItemKind? {
        EditItemKind(rawValue: action.rawValue)
    }

    static func action(for kind: EditItemKind) -> ActionKind? {
        ActionKind(rawValue: kind.rawValue)
    }
}

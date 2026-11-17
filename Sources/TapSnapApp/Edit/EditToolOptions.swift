import Foundation
import TapSnapPrivacy

/// 编辑窗口中当前工具的参数；预览、光标和最终图元使用同一份值。
struct EditToolOptions: Equatable {
    var arrowHead: ArrowItem.HeadStyle = .filled
    var textBackground: TextItem.BackgroundStyle = .none
    var mosaicMode: MosaicItem.Mode = .mosaic
    var mosaicBlockSize = 12
    var serialFormat: SerialItem.Format = .numeric
    var magnifierZoom: CGFloat = 2
    var watermarkText = "TapSnap"
    var watermarkAngle: Double = -30
    var watermarkTiled = true
    var privacyAppearance = PrivacyMaskAppearance()

    mutating func read(from item: any EditItem) {
        if let item = item as? ArrowItem { arrowHead = item.headStyle }
        if let item = item as? TextItem { textBackground = item.background }
        if let item = item as? MosaicItem {
            mosaicMode = item.mode
            mosaicBlockSize = item.blockSize
        }
        if let item = item as? SerialItem { serialFormat = item.format }
        if let item = item as? MagnifierItem { magnifierZoom = item.zoom }
        if let item = item as? PrivacyMaskItem { privacyAppearance = item.appearance }
        if let item = item as? WatermarkItem {
            watermarkText = item.text
            watermarkAngle = item.angle
            watermarkTiled = item.isTiled
        }
    }

    func apply(to item: any EditItem) {
        if let item = item as? ArrowItem { item.headStyle = arrowHead }
        if let item = item as? TextItem { item.background = textBackground }
        if let item = item as? MosaicItem {
            item.mode = mosaicMode
            item.blockSize = mosaicBlockSize
        }
        if let item = item as? SerialItem { item.format = serialFormat }
        if let item = item as? MagnifierItem { item.zoom = magnifierZoom }
        if let item = item as? PrivacyMaskItem { item.appearance = privacyAppearance }
        if let item = item as? WatermarkItem {
            item.text = watermarkText
            item.angle = watermarkAngle
            item.isTiled = watermarkTiled
        }
    }
}

import CoreGraphics
import Foundation

/// 写进系统剪贴板的附加元信息。
///
/// 随图像写入剪贴板，供重新粘贴时还原贴图的显示状态。
public struct ClipMetaData: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case screenshot
        case annotatedScreenshot
        case pin
        case ocrText
        case longShot
    }

    public var kind: Kind
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    /// 图像左上角在 Quartz 全局屏幕坐标系中的位置（点）。旧版本和外部图片可能没有位置。
    public var sourceTopLeft: CGPoint?
    public var createdAt: Date
    /// 若是贴图，记录它原本的置顶状态与透明度，粘回来时还原。
    public var isPinned: Bool
    public var opacity: Double

    public init(
        kind: Kind,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double = 1,
        sourceTopLeft: CGPoint? = nil,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        opacity: Double = 1
    ) {
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.sourceTopLeft = sourceTopLeft
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.opacity = opacity
    }

    /// 自定义剪贴板类型名，粘回时按它识别「这是 TapSnap 生成的图」。
    public static let pasteboardType = "com.sensnap.app.clipboard.metadata"

    public var logicalSize: CGSize {
        CGSize(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale)
    }
}

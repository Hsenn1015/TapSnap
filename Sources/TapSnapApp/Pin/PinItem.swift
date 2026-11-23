import AppKit
import Foundation
import TapSnapCore
import TapSnapTheme

/// 贴图数据。
///
/// 记录贴图的位置、尺寸、缩放、旋转、透明度、置顶和鼠标穿透状态。
struct PinItem: Identifiable {
    let id: UUID
    var imageID: UUID
    var image: CGImage
    /// 屏幕全局坐标下的窗口位置与（逻辑）尺寸。
    var frame: CGRect
    var opacity: Double
    var isAlwaysOnTop: Bool
    var isClickThrough: Bool
    var rotationAngle: Double
    var scale: CGFloat
    /// 所属分组的名称。
    var group: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        imageID: UUID = UUID(),
        image: CGImage,
        frame: CGRect,
        opacity: Double = 1,
        isAlwaysOnTop: Bool = true,
        isClickThrough: Bool = false,
        rotationAngle: Double = 0,
        scale: CGFloat = 1,
        group: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.imageID = imageID
        self.image = image
        self.frame = frame
        self.opacity = opacity
        self.isAlwaysOnTop = isAlwaysOnTop
        self.isClickThrough = isClickThrough
        self.rotationAngle = rotationAngle
        self.scale = scale
        self.group = group
        self.createdAt = createdAt
    }

    var clipMeta: ClipMetaData {
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        return ClipMetaData(
            kind: .pin,
            pixelWidth: image.width,
            pixelHeight: image.height,
            scale: scale,
            sourceTopLeft: CGPoint(x: frame.minX, y: desktopTop - frame.maxY),
            createdAt: createdAt,
            isPinned: isAlwaysOnTop,
            opacity: opacity
        )
    }
}

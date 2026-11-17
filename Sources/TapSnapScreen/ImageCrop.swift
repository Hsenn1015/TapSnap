import CoreGraphics
import Foundation
import TapSnapCore

/// 像素级裁剪。
///
/// 屏幕坐标以磅（point）为单位，`CGImage` 以像素为单位；两者相差一个 `scale`。
/// 截图链路上几乎所有坐标换算最后都要落到这里。
public enum ImageCrop {
    /// 从整屏图里裁出 `rect`（相对于该屏幕左上角的磅坐标）。
    public static func crop(_ image: CGImage, to rect: CGRect, scale: CGFloat) -> CGImage? {
        guard scale > 0 else { return nil }

        let scaled = CGRect(
            x: (rect.minX * scale).rounded(.down),
            y: (rect.minY * scale).rounded(.down),
            width: (rect.width * scale).rounded(.down),
            height: (rect.height * scale).rounded(.down)
        )
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = scaled.intersection(bounds)

        guard !pixelRect.isEmpty else { return nil }
        return image.cropping(to: pixelRect)
    }
}

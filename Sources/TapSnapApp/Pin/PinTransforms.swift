import CoreGraphics
import Foundation

/// 贴图的旋转 / 翻转。
///
/// 直接变换位图而不是给窗口加 transform：这样保存出来的文件、复制到剪贴板的
/// 内容、以及鼠标命中区域都跟看到的一致。
extension CGImage {
    func rotated(clockwise: Bool) -> CGImage? {
        let width = self.width
        let height = self.height
        guard let context = CGContext(
            data: nil,
            width: height,
            height: width,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(height) / 2, y: CGFloat(width) / 2)
        context.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        context.draw(self, in: CGRect(
            x: -CGFloat(width) / 2,
            y: -CGFloat(height) / 2,
            width: CGFloat(width),
            height: CGFloat(height)
        ))
        return context.makeImage()
    }

    func flipped(horizontally: Bool) -> CGImage? {
        let width = self.width
        let height = self.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.translateBy(
            x: horizontally ? CGFloat(width) : 0,
            y: horizontally ? 0 : CGFloat(height)
        )
        context.scaleBy(x: horizontally ? -1 : 1, y: horizontally ? 1 : -1)
        context.draw(self, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }
}

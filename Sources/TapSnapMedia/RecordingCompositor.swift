import CoreGraphics
import CoreText
import Foundation
import TapSnapSystem

/// 瞬时显示状态，不存储用户输入文本。
struct RecordingOverlayFrame: @unchecked Sendable {
    var camera: CGImage?
    /// 原点左上的 0...1 坐标，相对于实际录制区域。
    var clicks: [CGPoint] = []
    var shortcut: String?
}

enum RecordingCompositor {
    static func shortcutLabel(keyCode: UInt16, flags: UInt64) -> String? {
        let flags = CGEventFlags(rawValue: flags)
        let specials: Set<UInt16> = [36, 48, 49, 51, 53, 117, 123, 124, 125, 126,
                                    122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        // 不把普通输入或密码逐字显示在录屏中。
        guard !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
                || specials.contains(keyCode) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) { modifiers |= GlobalShortcut.Combo.command }
        if flags.contains(.maskControl) { modifiers |= GlobalShortcut.Combo.control }
        if flags.contains(.maskAlternate) { modifiers |= GlobalShortcut.Combo.option }
        if flags.contains(.maskShift) { modifiers |= GlobalShortcut.Combo.shift }
        return GlobalShortcut.Combo(keyCode: UInt32(keyCode), carbonModifiers: modifiers).displayString
    }

    static func compose(_ image: CGImage, overlay: RecordingOverlayFrame) -> CGImage {
        guard overlay.camera != nil || !overlay.clicks.isEmpty || overlay.shortcut != nil else { return image }
        let size = CGSize(width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let unit = max(0.001, min(size.width / 640, size.height / 360))
        if let camera = overlay.camera {
            let width = min(size.width * 0.27, 320 * unit)
            let height = min(size.height * 0.35, width * 0.75)
            let rect = CGRect(x: size.width - width - 12 * unit, y: 12 * unit, width: width, height: height)
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 12 * unit, cornerHeight: 12 * unit, transform: nil))
            context.clip()
            let scale = max(rect.width / CGFloat(camera.width), rect.height / CGFloat(camera.height))
            let drawn = CGSize(width: CGFloat(camera.width) * scale, height: CGFloat(camera.height) * scale)
            // 镜像自拍画面，编码后和预览惯例一致。
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: -1, y: 1)
            context.draw(camera, in: CGRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height))
            context.restoreGState()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            context.setLineWidth(2 * unit)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 12 * unit, cornerHeight: 12 * unit, transform: nil))
            context.strokePath()
        }
        for click in overlay.clicks {
            let point = CGPoint(x: click.x * size.width, y: (1 - click.y) * size.height)
            let rect = CGRect(x: point.x - 16 * unit, y: point.y - 16 * unit, width: 32 * unit, height: 32 * unit)
            context.setFillColor(CGColor(red: 1, green: 0.66, blue: 0.12, alpha: 0.28))
            context.fillEllipse(in: rect)
            context.setStrokeColor(CGColor(red: 1, green: 0.7, blue: 0.14, alpha: 0.95))
            context.setLineWidth(3 * unit)
            context.strokeEllipse(in: rect)
        }
        if let label = overlay.shortcut {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 18 * unit, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ]))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            let rect = CGRect(x: 12 * unit, y: 12 * unit, width: min(size.width - 24 * unit, bounds.width + 24 * unit), height: 38 * unit)
            context.setFillColor(CGColor(gray: 0.08, alpha: 0.82))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8 * unit, cornerHeight: 8 * unit, transform: nil))
            context.fillPath()
            context.saveGState()
            context.clip(to: rect)
            context.textPosition = CGPoint(x: rect.minX + 12 * unit - bounds.minX, y: rect.midY - bounds.midY)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        return context.makeImage() ?? image
    }
}

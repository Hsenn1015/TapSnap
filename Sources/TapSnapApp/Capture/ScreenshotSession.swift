import CoreGraphics
import Foundation
import TapSnapCore
import TapSnapScreen

/// 一次截图会话的状态。
///
/// 独立记录捕获模式、冻结帧和选区，可在不同窗口之间传递。
struct ScreenshotSession {
    enum Mode: String, Sendable {
        /// 框选区域
        case region
        /// 窗口（鼠标悬停高亮整个窗口）
        case window
        /// 全屏
        case fullScreen
        /// 滚动长截图
        case longShot

        var title: String {
            switch self {
            case .region: return "区域截图"
            case .window: return "窗口截图"
            case .fullScreen: return "全屏截图"
            case .longShot: return "滚动长截图"
            }
        }
    }

    let id = UUID()
    var mode: Mode
    var frames: [CapturedFrame]
    /// 屏幕全局坐标下的选区；nil 表示还没框选。
    var selectionRect: CGRect?
    var targetScreen: ScreenDescriptor?
    var startedAt: Date
    /// 截完是否直接贴图。
    var pinAfterCapture: Bool
    var outputOptions: ScreenshotOutputOptions?

    init(
        mode: Mode,
        pinAfterCapture: Bool = false,
        startedAt: Date = Date(),
        outputOptions: ScreenshotOutputOptions? = nil
    ) {
        self.mode = mode
        self.outputOptions = outputOptions
        self.pinAfterCapture = pinAfterCapture
        self.frames = []
        self.selectionRect = nil
        self.targetScreen = nil
        self.startedAt = startedAt
    }

    func frame(for screen: ScreenDescriptor) -> CapturedFrame? {
        frames.first { $0.screen.id == screen.id }
    }

    var outputScale: CGFloat {
        guard let rect = selectionRect else { return targetScreen?.scale ?? 1 }
        return frames.filter { !$0.screen.frame.intersection(rect).isEmpty }.map(\.screen.scale).max() ?? 1
    }

    /// 三种捕获方式共用框选结果；视图左下坐标转换成屏幕全局左上坐标。
    mutating func select(viewRect: CGRect, on screen: ScreenDescriptor) {
        let flipped = viewRect.flippedVertically(in: CGRect(origin: .zero, size: screen.frame.size))
        selectionRect = flipped.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        targetScreen = screen
    }

    /// 选中区域对应的像素图（从缓存帧里裁）。
    func croppedImage() -> CGImage? {
        guard let rect = selectionRect,
              let screen = targetScreen,
              let frame = frame(for: screen)
        else { return nil }

        if screen.frame.contains(rect) || frames.count == 1 {
            let local = Geometry.localRect(rect, in: screen.frame).snapped(to: screen.scale)
            return ImageCrop.crop(frame.image, to: local, scale: screen.scale)
        }
        let scale = outputScale
        let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Every display uses the same destination grid, including displays above or left of the primary.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for frame in frames where !frame.screen.frame.intersection(rect).isEmpty {
            let bounds = frame.screen.frame
            let x = ((bounds.minX - rect.minX) * scale).rounded()
            let y = ((rect.maxY - bounds.maxY) * scale).rounded()
            context.draw(frame.image, in: CGRect(x: x, y: y, width: bounds.width * scale, height: bounds.height * scale))
        }
        return context.makeImage()
    }
}

/// 截图预设。
///
/// 保存「固定区域 + 固定输出参数」的组合，用于定时截图、重复截同一块区域。
struct ScreenshotPreset: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var rect: CGRect?
    var screenID: UInt32?
    var format: String
    var autoSave: Bool

    init(id: UUID = UUID(), name: String, rect: CGRect? = nil, screenID: UInt32? = nil,
         format: String = "png", autoSave: Bool = false) {
        self.id = id
        self.name = name
        self.rect = rect
        self.screenID = screenID
        self.format = format
        self.autoSave = autoSave
    }
}

/// 仅作用于本次截图的预设输出，不覆盖全局设置。
struct ScreenshotOutputOptions: Equatable, Sendable {
    var format: String
    var autoSave: Bool
}

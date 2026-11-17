import AppKit
import CoreGraphics
import Foundation

/// 一块屏幕的描述信息。
///
/// 记录显示器的坐标、可见区域和缩放比例。
public struct ScreenDescriptor: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    /// 屏幕全局坐标（CGDisplay 坐标系，原点左上）。
    public let frame: CGRect
    /// 去掉菜单栏与 Dock 后的可用区域。
    public let visibleFrame: CGRect
    /// 2.0 表示 Retina。
    public let scale: CGFloat
    public let isMain: Bool
    public let localizedName: String

    public init(
        id: CGDirectDisplayID,
        frame: CGRect,
        visibleFrame: CGRect,
        scale: CGFloat,
        isMain: Bool,
        localizedName: String
    ) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isMain = isMain
        self.localizedName = localizedName
    }

    /// 屏幕像素尺寸。
    public var pixelSize: CGSize {
        CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    /// 供 AppKit 窗口定位使用；转换基准是主显示屏高度，不随当前焦点屏幕改变。
    public func appKitFrame(primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryDisplayHeight - frame.maxY,
               width: frame.width, height: frame.height)
    }

    public func contains(_ point: CGPoint) -> Bool {
        frame.contains(point)
    }
}

/// 屏幕枚举与坐标换算。
public enum ScreenLayout {
    public static func current() -> [ScreenDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return ScreenDescriptor(
                id: displayID,
                frame: CGDisplayBounds(displayID),
                visibleFrame: screen.visibleFrame,
                scale: screen.backingScaleFactor,
                isMain: screen == NSScreen.main,
                localizedName: screen.localizedName
            )
        }
    }

    /// 找出包含指定全局坐标点的屏幕。
    public static func screen(containing point: CGPoint) -> ScreenDescriptor? {
        current().first { $0.contains(point) } ?? current().first { $0.isMain }
    }
}

import AppKit
import CoreGraphics
import ScreenCaptureKit
import TapSnapCore

/// 一次整屏抓取的结果。
public struct CapturedFrame: @unchecked Sendable {
    public var screen: ScreenDescriptor
    public var image: CGImage
    public var timestamp: Date

    public init(screen: ScreenDescriptor, image: CGImage, timestamp: Date = Date()) {
        self.screen = screen
        self.image = image
        self.timestamp = timestamp
    }

    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

public enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case captureFailed(underlying: Error?)

    public static func isPermissionDenied(_ error: Error) -> Bool {
        if case CaptureError.permissionDenied = error { return true }
        return (error as? SCStreamError)?.code == .userDeclined
    }

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "录屏权限尚未开启"
        case .noDisplays:
            return "没有可抓取的屏幕"
        case .captureFailed(let error):
            return error.map { "抓屏失败：\($0.localizedDescription)" } ?? "抓屏失败"
        }
    }
}

/// 整屏/区域抓取。
///
/// 通过 ScreenCaptureKit 获取整屏图像，供选区交互和输出使用。
public final class ScreenCaptureService {
    public struct Options: Sendable {
        public var includeCursor: Bool
        public var captureAllDisplays: Bool
        public var excludingCurrentApplication: Bool
        public var excludedWindowIDs: [CGWindowID]
        public var hideDesktopIcons: Bool

        public init(includeCursor: Bool = false, captureAllDisplays: Bool = true, excludingCurrentApplication: Bool = false,
                    excludedWindowIDs: [CGWindowID] = [], hideDesktopIcons: Bool = false) {
            self.includeCursor = includeCursor
            self.captureAllDisplays = captureAllDisplays
            self.excludingCurrentApplication = excludingCurrentApplication
            self.excludedWindowIDs = excludedWindowIDs
            self.hideDesktopIcons = hideDesktopIcons
        }
    }

    public init() {}

    /// 抓取全部屏幕（每屏一张），进入截图模式时调用。
    public func captureAllScreens(options: Options = Options()) async throws -> [CapturedFrame] {
        try ensureScreenCaptureAccess()

        let content = try await shareableContent()
        let screens = ScreenLayout.current()
        var frames: [CapturedFrame] = []

        for screen in screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.id }) else { continue }
            guard let image = try? await shot(display: display, screen: screen, options: options, content: content) else { continue }
            frames.append(CapturedFrame(screen: screen, image: image))
        }

        guard !frames.isEmpty else { throw CaptureError.noDisplays }
        return frames
    }

    /// 抓取指定屏幕。
    public func capture(screen: ScreenDescriptor, options: Options = Options()) async throws -> CapturedFrame {
        try ensureScreenCaptureAccess()

        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == screen.id }) else {
            throw CaptureError.noDisplays
        }
        let image = try await shot(display: display, screen: screen, options: options, content: content)
        return CapturedFrame(screen: screen, image: image)
    }

    /// 抓取某个全局矩形区域（长截图、局部贴图复用）。
    public func capture(rect: CGRect, options: Options = Options()) async throws -> CGImage {
        guard let screen = ScreenLayout.screen(containing: rect.center) else {
            throw CaptureError.noDisplays
        }
        let frame = try await capture(screen: screen, options: options)
        let localRect = Geometry.localRect(rect, in: screen.frame)
        guard let cropped = ImageCrop.crop(frame.image, to: localRect, scale: screen.scale) else {
            throw CaptureError.captureFailed(underlying: nil)
        }
        return cropped
    }

    // MARK: - ScreenCaptureKit

    /// 由调用此服务的操作决定何时引导用户授权。
    private func ensureScreenCaptureAccess() throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if CaptureError.isPermissionDenied(error) || !CGPreflightScreenCaptureAccess() {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.captureFailed(underlying: error)
        }
    }

    /// 只改变捕获过滤器，不修改 Finder 或桌面显示设置。
    public static func shouldExcludeWindow(id: CGWindowID, processID: pid_t?, layer: Int,
                                           options: Options, currentProcessID: pid_t) -> Bool {
        options.excludedWindowIDs.contains(id)
            || (options.excludingCurrentApplication && processID == currentProcessID)
            || (options.hideDesktopIcons && layer == Int(CGWindowLevelForKey(.desktopIconWindow)))
    }

    private func shot(
        display: SCDisplay,
        screen: ScreenDescriptor,
        options: Options,
        content: SCShareableContent
    ) async throws -> CGImage {
        let excludedWindows = content.windows.filter {
            Self.shouldExcludeWindow(id: $0.windowID, processID: $0.owningApplication?.processID,
                                     layer: $0.windowLayer, options: options,
                                     currentProcessID: ProcessInfo.processInfo.processIdentifier)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.pixelSize.width)
        configuration.height = Int(screen.pixelSize.height)
        configuration.showsCursor = options.includeCursor
        configuration.captureResolution = .best

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw CaptureError.captureFailed(underlying: error)
        }
    }
}

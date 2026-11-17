import Foundation

/// 应用内所有路径的唯一来源。
///
/// 统一管理缓存、临时截图以及 Application Support 中的配置与历史目录。
public enum AppPaths {
    // 更名后沿用原身份，保留系统授权、现有设置和历史数据。
    public static let bundleIdentifier = "com.sensnap.app"

    /// Application Support/com.sensnap.app
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// ~/Library/Caches/com.sensnap.app
    public static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public static var configFile: URL {
        applicationSupport.appendingPathComponent("settings.json")
    }

    public static var clipboardHistoryFile: URL {
        applicationSupport.appendingPathComponent("clipboard-meta.json")
    }

    public static var logsDirectory: URL {
        applicationSupport.appendingPathComponent("logs", isDirectory: true)
    }

    public static var tempCaptureDirectory: URL {
        caches.appendingPathComponent("captures", isDirectory: true)
    }

    /// 创建目录（已存在则忽略）。
    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 默认图片保存位置：~/Pictures/TapSnap
    public static var defaultSaveDirectory: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return base.appendingPathComponent("TapSnap", isDirectory: true)
    }
}

import Foundation

/// 应用内所有路径的唯一来源。
///
/// 统一管理缓存、临时截图以及 Application Support 中的配置与历史目录。
public enum AppPaths {
    private static let developmentIdentifier = "com.sensnap.app.dev"
    public static let isDevelopmentBuild = Bundle.main.bundleIdentifier == developmentIdentifier
    // 正式版沿用原身份，未打包的命令行工具和测试也沿用既有路径。
    public static let bundleIdentifier = isDevelopmentBuild ? developmentIdentifier : "com.sensnap.app"

    /// 按应用身份存放设置、密钥和历史。
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// 当前应用的缓存目录。
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

    /// 将两个版本的默认图片保存到各自的 Pictures 子目录。
    public static var defaultSaveDirectory: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return base.appendingPathComponent(isDevelopmentBuild ? "TapSnap 开发版" : "TapSnap", isDirectory: true)
    }
}

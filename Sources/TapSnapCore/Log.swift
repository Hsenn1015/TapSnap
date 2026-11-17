import Foundation
import OSLog

/// 统一日志出口。
///
/// 写入 macOS 统一日志，可在「控制台」中查看。
public final class Log: @unchecked Sendable {
    public static let shared = Log(subsystem: AppPaths.bundleIdentifier)

    private let logger: Logger

    public init(subsystem: String, category: String = "default") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        write("DEBUG", message)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    public func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        write("WARN", message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    /// 沿用历史日志 `Application Support/com.sensnap.app/logs/sensnap.log`。
    ///
    /// 系统统一日志在 Release 包上不好捞（`log show` 常被过滤掉），排障时
    /// 有个明文文件省事得多。
    public func enableFileLogging() {
        fileURL = AppPaths.applicationSupport
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("sensnap.log")
        if let fileURL {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    private var fileURL: URL?
    private let fileQueue = DispatchQueue(label: "com.sensnap.log-file")

    private func write(_ level: String, _ message: String) {
        guard let fileURL else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        fileQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}

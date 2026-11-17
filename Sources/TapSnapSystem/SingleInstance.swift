import AppKit
import Foundation

/// 单实例约束。
///
/// 通过 `NSRunningApplication` 查找具有同一 Bundle ID 的实例。
public enum SingleInstance {
    /// 若已有其它实例在跑，激活它并返回 false（调用方应退出）。
    @discardableResult
    public static func ensureSingle(activatingExisting: Bool = true) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return true }
        if activatingExisting {
            others.first?.activate(options: [.activateIgnoringOtherApps])
        }
        return false
    }

    public static var currentProcessIdentifier: Int32 {
        ProcessInfo.processInfo.processIdentifier
    }
}

/// 应用自身信息。
public enum AppInfo {
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    public static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    public static var displayName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "TapSnap"
    }
}

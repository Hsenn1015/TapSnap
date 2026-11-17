import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// 系统权限种类。
///
/// 封装屏幕录制和辅助功能权限的状态查询与请求。
public enum SystemPermission: String, Codable, CaseIterable, Sendable {
    case screenCapture
    case accessibility
    case camera
    case microphone

    public var displayName: String {
        switch self {
        case .screenCapture: return "屏幕录制"
        case .accessibility: return "辅助功能"
        case .camera: return "摄像头"
        case .microphone: return "麦克风"
        }
    }
}

public enum PermissionStatus: String, Codable, Sendable {
    case notDetermined
    case denied
    case authorized
    case restricted
}

/// 权限查询与申请。
public enum Permissions {
    /// 只查询，不弹窗。
    public static func status(of permission: SystemPermission) -> PermissionStatus {
        switch permission {
        case .screenCapture:
            // 这个接口只回答「已授权 / 未授权」，没有「被拒绝」的区分。
            return CGPreflightScreenCaptureAccess() ? .authorized : .denied
        case .accessibility:
            return AXIsProcessTrusted() ? .authorized : .denied
        case .camera:
            return map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    }

    /// 触发系统授权流程。屏幕录制权限的系统弹窗只会出现一次，弹过之后
    /// 只能由用户去系统设置里手动勾选。
    @discardableResult
    public static func request(_ permission: SystemPermission) -> Bool {
        switch permission {
        case .screenCapture:
            return CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            return AXIsProcessTrustedWithOptions(options as CFDictionary)
        case .camera, .microphone:
            return requestCaptureDevice(permission == .camera ? .video : .audio)
        }
    }

    /// 打开「系统设置 → 隐私与安全性」里对应的面板。
    public static func openSettingsPanel(for permission: SystemPermission) {
        let anchor: String
        switch permission {
        case .screenCapture: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        if let url { NSWorkspace.shared.open(url) }
    }

    public static var allAuthorized: Bool {
        SystemPermission.allCases.allSatisfy { status(of: $0) == .authorized }
    }

    // MARK: - 私有

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// 摄像头/麦克风的授权是异步回调，这里同步等待结果。
    /// 骨架阶段只在启动检查里用，调用点都在后台线程。
    private static func requestCaptureDevice(_ mediaType: AVMediaType) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: mediaType) { result in
                granted = result
                semaphore.signal()
            }
            semaphore.wait()
            return granted
        @unknown default:
            return false
        }
    }
}

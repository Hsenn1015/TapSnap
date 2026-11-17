import AppKit
import Foundation
import ApplicationServices

/// 监测前台应用全屏状态；只读 AX/窗口几何，不要求新的辅助功能授权。
public final class WindowLayerMonitor {
    public struct Change: Sendable {
        public var applicationBundleID: String?
        public var isFullScreen: Bool
        public var timestamp: Date
    }

    public private(set) var isRunning = false
    public var onChange: ((Change) -> Void)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var previousApplication: String?
    private var previousFullScreen: Bool?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        previousFullScreen = nil
        previousApplication = nil
        isRunning = false
    }

    public var isOtherAppFullScreen: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        if AXIsProcessTrusted() {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.1)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
               let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                let window = unsafeBitCast(focused, to: AXUIElement.self)
                if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success,
                   let fullScreen = value as? Bool { return fullScreen }
            }
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let screens = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(id.uint32Value)
        }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
            return Self.coversScreen(bounds, screens: screens)
        }
    }

    public static func coversScreen(_ bounds: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { screen in
            abs(bounds.minX - screen.minX) <= 2 && abs(bounds.minY - screen.minY) <= 2
                && abs(bounds.width - screen.width) <= 2 && abs(bounds.height - screen.height) <= 2
        }
    }

    private func refresh() {
        guard isRunning else { return }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let fullScreen = isOtherAppFullScreen
        guard app != previousApplication || fullScreen != previousFullScreen else { return }
        previousApplication = app
        previousFullScreen = fullScreen
        onChange?(Change(applicationBundleID: app, isFullScreen: fullScreen, timestamp: Date()))
    }

    deinit { stop() }
}

/// 通过 `NSWindow.sharingType` 控制窗口是否允许共享。
public enum ScreenCaptureProtection {
    public static func protect(_ window: NSWindow) {
        window.sharingType = .none
    }

    public static func unprotect(_ window: NSWindow) {
        window.sharingType = .readOnly
    }
}

import ApplicationServices
import CoreGraphics
import Foundation

enum SelectionAccessibilityTarget {
    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSliderRole, kAXIncrementorRole,
        kAXDisclosureTriangleRole, kAXColorWellRole, kAXMenuItemRole, "AXLink", "AXTab", "AXSwitch",
    ]

    /// 在后台用屏幕左上原点坐标查询窗口内的控件。只读取角色和边界，不请求额外授权。
    static func frame(at point: CGPoint, in window: CGRect, processID: pid_t) -> CGRect? {
        let x = Float(point.x), y = Float(point.y)
        guard x.isFinite, y.isFinite, window.width.isFinite, window.height.isFinite,
              window.contains(point), processID > 0,
              processID != ProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted() else { return nil }

        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        func setTimeout(on element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            return remaining > 0 && AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining))) == .success
        }

        // 按前景窗口的进程查询，避免系统级命中测试选到 TapSnap 的覆盖层。
        let application = AXUIElementCreateApplication(processID)
        var element: AXUIElement?
        guard setTimeout(on: application),
              AXUIElementCopyElementAtPosition(application, x, y, &element) == .success,
              let hit = element else { return nil }
        var hitProcess: pid_t = 0
        guard AXUIElementGetPid(hit, &hitProcess) == .success, hitProcess == processID else { return nil }

        let attributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute] as CFArray
        var imageFrame: CGRect?
        for _ in 0..<8 {
            guard let current = element, setTimeout(on: current) else { break }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(current, attributes, [], &raw) == .success,
                  ProcessInfo.processInfo.systemUptime < deadline,
                  let values = raw as? [AnyObject], values.count == 4,
                  let role = values[0] as? String,
                  role != kAXWindowRole, role != kAXApplicationRole else { break }
            if controlRoles.contains(role) || role == kAXImageRole,
               let bounds = controlFrame(position: values[1], size: values[2], at: point, in: window) {
                if role != kAXImageRole { return bounds }
                // 图片可以单独选中，但如果它是按钮的图标，应选整个按钮。
                if imageFrame == nil { imageFrame = bounds }
            }
            let parent = values[3]
            guard CFGetTypeID(parent) == AXUIElementGetTypeID(), !CFEqual(current, parent) else { break }
            element = (parent as! AXUIElement)
        }
        return imageFrame
    }

    private static func controlFrame(position: AnyObject, size: AnyObject, at point: CGPoint,
                                     in window: CGRect) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = position as! AXValue, sizeValue = size as! AXValue
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &dimensions),
              origin.x.isFinite, origin.y.isFinite,
              dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width >= 12, dimensions.height >= 12 else { return nil }
        let bounds = CGRect(origin: origin, size: dimensions)
        guard bounds.contains(point), window.contains(bounds),
              bounds.width * bounds.height < window.width * window.height * 0.85 else { return nil }
        return bounds
    }
}

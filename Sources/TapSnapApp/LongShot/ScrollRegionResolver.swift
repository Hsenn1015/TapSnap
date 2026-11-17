import ApplicationServices
import CoreGraphics
import Foundation

/// 全局左上原点的屏幕点坐标，与 CGDisplay/截图选区一致。
struct ScrollRegionResolution {
    var viewport: CGRect
    var content: CGRect
    var processID: pid_t? = nil
}

enum ScrollRegionResolver {
    /// 在后台调用；仅查询公开 AX 几何信息，不请求授权或操作目标应用。
    static func resolve(at point: CGPoint, within selection: CGRect) -> ScrollRegionResolution? {
        guard AXIsProcessTrusted(), valid(selection), point.x.isFinite, point.y.isFinite,
              selection.contains(point) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, 0.15) == .success else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func element(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = attribute(element, kAXPositionAttribute),
                  let size = attribute(element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            let positionValue = position as! AXValue, sizeValue = size as! AXValue
            var origin = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
                  AXValueGetValue(positionValue, .cgPoint, &origin),
                  AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
            let rect = CGRect(origin: origin, size: dimensions)
            return valid(rect) ? rect : nil
        }

        var current: AXUIElement? = hit
        var visited: [AXUIElement] = []
        var scrollArea: AXUIElement?
        var viewport: CGRect?
        var clippingRects: [CGRect] = []
        var reachedWindow = false
        for _ in 0..<24 {
            guard let node = current, !visited.contains(where: { CFEqual($0, node) }),
                  let role = attribute(node, kAXRoleAttribute) as? String else { return nil }
            visited.append(node)
            if role == kAXScrollAreaRole {
                guard let bounds = frame(node) else { return nil }
                if scrollArea == nil {
                    scrollArea = node
                    viewport = bounds
                } else {
                    clippingRects.append(bounds)
                }
            } else if role == kAXWindowRole {
                guard let bounds = frame(node) else { return nil }
                clippingRects.append(bounds)
                reachedWindow = true
                break
            }
            current = element(attribute(node, kAXParentAttribute))
        }
        guard reachedWindow, let scrollArea, let viewport else { return nil }

        var contents: [CGRect] = []
        if let children = attribute(scrollArea, kAXContentsAttribute) as? [AnyObject], children.count <= 64 {
            for child in children {
                guard let child = element(child), let bounds = frame(child) else {
                    // 部分几何不能证明滚动条与所有内容独立。
                    contents.removeAll()
                    break
                }
                contents.append(bounds)
            }
        }
        let vertical = element(attribute(scrollArea, kAXVerticalScrollBarAttribute)).flatMap(frame)
        let horizontal = element(attribute(scrollArea, kAXHorizontalScrollBarAttribute)).flatMap(frame)
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        guard var result = clippedResolution(viewport: viewport, contents: contents, clippingRects: clippingRects,
                                             verticalScrollbars: vertical.map { [$0] } ?? [],
                                             horizontalScrollbars: horizontal.map { [$0] } ?? [], selection: selection),
              result.viewport.contains(point) else { return nil }
        result.processID = pid
        return result
    }

    /// 纯几何接缝：AXContents 可能是超过视口的文档，也可能只是窄文字节点。
    /// 不用其包围盒裁正文；仅在它证明滚动条独立位于外侧时扣除该边缘。
    static func clippedResolution(viewport: CGRect, contents: [CGRect] = [], clippingRects: [CGRect] = [],
                                  verticalScrollbars: [CGRect] = [], horizontalScrollbars: [CGRect] = [],
                                  selection: CGRect) -> ScrollRegionResolution? {
        guard valid(viewport), valid(selection), clippingRects.allSatisfy(valid) else { return nil }
        var visible = viewport.intersection(selection)
        for rect in clippingRects { visible = visible.intersection(rect) }
        guard valid(visible) else { return nil }
        var content = visible
        let knownContents = contents.filter(valid).map { $0.intersection(visible) }.filter(valid)
        guard !knownContents.isEmpty, contents.allSatisfy(valid) else {
            return ScrollRegionResolution(viewport: visible, content: content)
        }
        let occupied = knownContents.reduce(CGRect.null) { $0.union($1) }
        for bar in verticalScrollbars.filter(valid) {
            let clipped = bar.intersection(visible)
            guard valid(clipped), !clipped.intersects(occupied) else { continue }
            let candidate: CGRect
            if clipped.minX >= occupied.maxX {
                candidate = CGRect(x: content.minX, y: content.minY,
                                   width: min(content.maxX, clipped.minX) - content.minX, height: content.height)
            } else if clipped.maxX <= occupied.minX {
                candidate = CGRect(x: max(content.minX, clipped.maxX), y: content.minY,
                                   width: content.maxX - max(content.minX, clipped.maxX), height: content.height)
            } else { continue }
            if valid(candidate), candidate.contains(occupied) { content = candidate }
        }
        for bar in horizontalScrollbars.filter(valid) {
            let clipped = bar.intersection(visible)
            guard valid(clipped), !clipped.intersects(occupied) else { continue }
            let candidate: CGRect
            if clipped.minY >= occupied.maxY {
                candidate = CGRect(x: content.minX, y: content.minY, width: content.width,
                                   height: min(content.maxY, clipped.minY) - content.minY)
            } else if clipped.maxY <= occupied.minY {
                candidate = CGRect(x: content.minX, y: max(content.minY, clipped.maxY), width: content.width,
                                   height: content.maxY - max(content.minY, clipped.maxY))
            } else { continue }
            if valid(candidate), candidate.contains(occupied) { content = candidate }
        }
        return ScrollRegionResolution(viewport: visible, content: content)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}

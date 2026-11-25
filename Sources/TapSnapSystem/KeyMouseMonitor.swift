import Foundation
import CoreGraphics

/// 全局键鼠事件监听。
///
/// 用 `CGEventTap` 监听键鼠事件，需要辅助功能权限。
public final class KeyMouseMonitor {
    public struct Event: Sendable {
        public enum Kind: Sendable {
            case leftMouseDown
            case leftMouseUp
            case rightMouseDown
            case scroll
            case keyDown
        }

        public var kind: Kind
        /// 屏幕全局坐标（CGEvent 坐标系，原点左上）。
        public var location: CGPoint
        public var keyCode: UInt16?
        public var modifierFlags: UInt64
        public var timestamp: CFAbsoluteTime
        /// 垂直滚轮增量（macOS 自然滚动或传统滚动像素/行差值，非 0 表示有滚动）。
        public var scrollDeltaY: Double
        /// 水平滚轮增量。
        public var scrollDeltaX: Double

        public init(
            kind: Kind,
            location: CGPoint,
            keyCode: UInt16?,
            modifierFlags: UInt64,
            timestamp: CFAbsoluteTime,
            scrollDeltaY: Double = 0,
            scrollDeltaX: Double = 0
        ) {
            self.kind = kind
            self.location = location
            self.keyCode = keyCode
            self.modifierFlags = modifierFlags
            self.timestamp = timestamp
            self.scrollDeltaY = scrollDeltaY
            self.scrollDeltaX = scrollDeltaX
        }
    }

    public private(set) var isRunning = false
    public var onEvent: ((Event) -> Void)?
    public var observesKeyboard = true
    /// 返回 true 表示吞掉这次事件，不再传给目标应用。
    public var shouldConsume: ((Event) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init() {}

    public func start() {
        stop()
        var types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel]
        if observesKeyboard { types.append(.keyDown) }
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // 录屏旁路监听不改变其它应用收到的输入。
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                         options: shouldConsume == nil ? .listenOnly : .defaultTap,
                                         eventsOfInterest: mask, callback: Self.callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = CGEvent.tapIsEnabled(tap: tap)
        if !isRunning { stop() }
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        isRunning = false
    }

    deinit { stop() }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<KeyMouseMonitor>.fromOpaque(context).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let kind: Event.Kind
        switch type {
        case .leftMouseDown: kind = .leftMouseDown
        case .leftMouseUp: kind = .leftMouseUp
        case .rightMouseDown: kind = .rightMouseDown
        case .scrollWheel: kind = .scroll
        case .keyDown: kind = .keyDown
        default: return Unmanaged.passUnretained(event)
        }
        var scrollDeltaY = 0.0
        var scrollDeltaX = 0.0
        if type == .scrollWheel {
            let ptY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let ptX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            scrollDeltaY = abs(ptY) > 0.001 ? ptY : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10
            scrollDeltaX = abs(ptX) > 0.001 ? ptX : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 10
        }
        let input = Event(kind: kind, location: event.location,
                          keyCode: type == .keyDown ? UInt16(event.getIntegerValueField(.keyboardEventKeycode)) : nil,
                          modifierFlags: event.flags.rawValue, timestamp: CFAbsoluteTimeGetCurrent(),
                          scrollDeltaY: scrollDeltaY, scrollDeltaX: scrollDeltaX)
        monitor.onEvent?(input)
        return monitor.shouldConsume?(input) == true ? nil : Unmanaged.passUnretained(event)
    }
}

/// 全局鼠标位置与修饰键状态。
public enum GlobalPointer {
    public static var location: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    public static var isOptionKeyDown: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }
}

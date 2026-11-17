import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 冲突时优先接收一个组合键。与 GlobalShortcut 一样，生命周期由主线程管理。
/// 只拦截当前 session 的事件，不能覆盖更早的 HID 拦截或安全输入限制。
internal final class PriorityShortcutTap {
    enum Decision: Equatable { case passThrough, consume, trigger }

    private let combo: GlobalShortcut.Combo
    private let modifiers: CGEventFlags
    private let onTrigger: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var secureInputMonitor: Timer?
    private var secureInputEnabled = false
    private var generation = UUID()
    private var pressed = false
    private static let modifierMask: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]

    init(combo: GlobalShortcut.Combo, onTrigger: @escaping () -> Void) {
        self.combo = combo
        self.onTrigger = onTrigger
        var flags: CGEventFlags = []
        if combo.carbonModifiers & GlobalShortcut.Combo.control != 0 { flags.insert(.maskControl) }
        if combo.carbonModifiers & GlobalShortcut.Combo.shift != 0 { flags.insert(.maskShift) }
        if combo.carbonModifiers & GlobalShortcut.Combo.option != 0 { flags.insert(.maskAlternate) }
        if combo.carbonModifiers & GlobalShortcut.Combo.command != 0 { flags.insert(.maskCommand) }
        modifiers = flags
    }

    deinit { stop() }

    var isRunning: Bool {
        guard let eventTap, CFMachPortIsValid(eventTap), CGEvent.tapIsEnabled(tap: eventTap) else { return false }
        return Permissions.status(of: .accessibility) == .authorized
    }

    func start() throws {
        if isRunning { return }
        stop()
        guard Permissions.status(of: .accessibility) == .authorized else {
            throw GlobalShortcut.RegistrationError.accessibilityRequired
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: Self.callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw GlobalShortcut.RegistrationError.priorityCaptureFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw GlobalShortcut.RegistrationError.priorityCaptureFailed
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard isRunning else {
            stop()
            throw GlobalShortcut.RegistrationError.priorityCaptureFailed
        }
        updateSecureInput(secureInputEnabled: IsSecureEventInputEnabled())
        let monitor = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateSecureInput(secureInputEnabled: IsSecureEventInputEnabled())
        }
        RunLoop.main.add(monitor, forMode: .common)
        secureInputMonitor = monitor
    }

    func stop() {
        secureInputMonitor?.invalidate()
        secureInputMonitor = nil
        secureInputEnabled = false
        resetPress()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
    }

    func updateSecureInput(secureInputEnabled: Bool) {
        if self.secureInputEnabled != secureInputEnabled {
            self.secureInputEnabled = secureInputEnabled
            // 系统可能在保护期间拦下抬键事件，恢复后从全新的按压开始。
            resetPress()
        }
        guard !secureInputEnabled, let eventTap, CFMachPortIsValid(eventTap),
              !CGEvent.tapIsEnabled(tap: eventTap), Permissions.status(of: .accessibility) == .authorized else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func resetPress() {
        pressed = false
        generation = UUID()
    }

    /// 纯事件判定入口便于验证，不向系统发送事件，也不执行截图动作。
    func decision(for type: CGEventType, event: CGEvent) -> Decision {
        guard !secureInputEnabled, type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(combo.keyCode) else { return .passThrough }
        if type == .keyUp {
            guard pressed else { return .passThrough }
            pressed = false
            return .consume
        }
        // 已截获的按压要完整消费到 keyUp，避免先松修饰键后泄漏裸键重复。
        if pressed { return .consume }
        guard event.flags.intersection(Self.modifierMask) == modifiers else { return .passThrough }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return .consume }
        pressed = true
        return .trigger
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<PriorityShortcutTap>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard eventTap != nil else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetPress()
            updateSecureInput(secureInputEnabled: IsSecureEventInputEnabled())
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(combo.keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        updateSecureInput(secureInputEnabled: IsSecureEventInputEnabled())
        switch decision(for: type, event: event) {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        case .trigger:
            let token = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !IsSecureEventInputEnabled(), self.isRunning else { return }
                self.onTrigger()
            }
            return nil
        }
    }
}

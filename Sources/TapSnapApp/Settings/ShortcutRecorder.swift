import AppKit
import Carbon.HIToolbox
import Combine
import TapSnapActionsBar
import TapSnapConfig
import TapSnapSystem

/// 只在设置窗口中的一行处于录制状态时接收按键。
final class ShortcutRecorder: ObservableObject {
    enum Input: Equatable {
        case binding(KeyBinding), cancel, clear, invalid, ignore
    }

    enum Target: Hashable {
        case global(ShortcutAction)
        case operation(OperationShortcut)

        var displayName: String {
            switch self {
            case .global(let action): return action.displayName
            case .operation(let operation): return operation.title
            }
        }

        var allowsSingleKey: Bool {
            if case .operation = self { return true }
            return false
        }

        func binding(in config: ConfigStore) -> KeyBinding? {
            switch self {
            case .global(let action): return config.binding(for: action)
            case .operation(let operation): return operation.binding(in: config.settings)
            }
        }
    }

    @Published private(set) var action: Target?
    @Published private(set) var feedbackTarget: Target?
    @Published private(set) var preview = "请按组合键"
    @Published private(set) var message: String?
    @Published private(set) var hasError = false
    private let center: ShortcutCenter
    private weak var window: NSWindow?
    private var pendingKey: UInt16?
    private var pendingBinding: KeyBinding?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var generation = UUID()
    private var feedbackDismissWorkItem: DispatchWorkItem?

    init(center: ShortcutCenter) { self.center = center }

    func begin(_ action: Target) {
        cancel()
        self.action = action
        feedbackTarget = action
        preview = action.allowsSingleKey ? "请按快捷键" : "请按组合键"
        message = nil
        hasError = false
        window = NSApp?.keyWindow
        center.beginRecording()
        // 优先于 Carbon 接收输入，已有 Ctrl+1 被其他应用占用时仍可重新录入。
        // 未授权时使用应用内监听，不触发新的权限弹窗。
        if !installEventTap() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self, self.canReceiveInput else { return event }
                self.handle(event)
                return nil
            }
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            if let window {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.cancel()
                })
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancel()
        })
    }

    func cancel() {
        generation = UUID()
        feedbackDismissWorkItem?.cancel()
        feedbackDismissWorkItem = nil
        removeEventMonitoring()
        pendingKey = nil
        pendingBinding = nil
        action = nil
        feedbackTarget = nil
        message = nil
        hasError = false
        window = nil
        center.endRecording()
    }

    func clear(_ action: Target) {
        cancel()
        let error = save(nil, for: action)
        showFeedback(error ?? "已清除\(action.displayName)快捷键", for: action, isError: error != nil)
    }

    private func showFeedback(_ text: String, for target: Target?, isError: Bool) {
        feedbackDismissWorkItem?.cancel()
        feedbackTarget = target
        message = text
        hasError = isError
        guard !isError else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.action == nil, self.message == text else { return }
            self.message = nil
            self.feedbackTarget = nil
        }
        feedbackDismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    func handle(_ event: NSEvent) {
        guard let action else { return }
        if event.type == .flagsChanged {
            if pendingKey == nil {
                let symbols = Self.modifierSymbols(event.modifierFlags)
                preview = symbols.isEmpty ? (action.allowsSingleKey ? "请按快捷键" : "请按组合键") : symbols + "…"
            }
            return
        }
        if event.type == .keyUp {
            guard pendingKey == event.keyCode else { return }
            pendingKey = nil
            if let error = save(pendingBinding, for: action) {
                message = error
                hasError = true
            } else {
                let result = pendingBinding.map { "\(action.displayName)已设为 \($0.displayString)" }
                    ?? "已清除\(action.displayName)快捷键"
                cancel()
                showFeedback(result, for: action, isError: false)
            }
            return
        }
        switch Self.input(from: event, allowsSingleKey: action.allowsSingleKey) {
        case .binding(let binding):
            pendingKey = event.keyCode
            pendingBinding = binding
            preview = binding.displayString
            message = "松开按键即可保存"
            hasError = false
        case .clear:
            pendingKey = event.keyCode
            pendingBinding = nil
            preview = "清除快捷键"
            message = "松开按键即可清除"
            hasError = false
        case .cancel:
            cancel()
            showFeedback("已取消，原快捷键保留", for: action, isError: false)
        case .invalid:
            pendingKey = nil
            message = action.allowsSingleKey ? "回车和 Tab 用于确认与切换焦点，请换一个键位"
                : "请搭配 ⌘、⌃ 或 ⌥ 使用，也可以单独使用 F1–F20"
            hasError = true
        case .ignore: break
        }
    }

    private func save(_ binding: KeyBinding?, for action: Target) -> String? {
        switch action {
        case .global(let action): return center.setRecordedBinding(binding, for: action)
        case .operation(let operation): return center.setRecordedBinding(binding, for: operation)
        }
    }

    static func input(from event: NSEvent, allowsSingleKey: Bool = false) -> Input {
        guard event.type == .keyDown, !event.isARepeat else { return .ignore }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.isEmpty {
            if event.keyCode == kVK_Escape { return .cancel }
            if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete { return .clear }
            if allowsSingleKey, [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab].contains(Int(event.keyCode)) { return .invalid }
        }
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        guard allowsSingleKey || !flags.intersection([.command, .control, .option]).isEmpty
                || functionKeys.contains(Int(event.keyCode)) else { return .invalid }
        return .binding(KeyBinding(keyCode: UInt32(event.keyCode), flags: flags))
    }

    private static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined()
    }

    private var canReceiveInput: Bool {
        action != nil && NSApp?.isActive == true && window?.isKeyWindow == true
    }

    private func installEventTap() -> Bool {
        guard Permissions.status(of: .accessibility) == .authorized else { return false }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: Self.callback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            removeEventMonitoring()
            return false
        }
        return true
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let recorder = Unmanaged<ShortcutRecorder>.fromOpaque(context).takeUnretainedValue()
        let token = recorder.generation
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak recorder] in
                guard let recorder, recorder.generation == token else { return }
                recorder.cancel()
            }
            return Unmanaged.passUnretained(event)
        }
        guard recorder.canReceiveInput, let input = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        DispatchQueue.main.async { [weak recorder] in
            guard let recorder, recorder.generation == token, recorder.canReceiveInput else { return }
            recorder.handle(input)
        }
        // 修饰键继续传递，让系统保持正确的按下/抬起状态。
        return type == .flagsChanged ? Unmanaged.passUnretained(event) : nil
    }

    private func removeEventMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        removeEventMonitoring()
        center.endRecording()
    }
}

import Carbon.HIToolbox
import Combine
import Foundation
import TapSnapActionsBar
import TapSnapConfig
import TapSnapCore
import TapSnapSystem
import TapSnapToast

protocol ShortcutRegistration: AnyObject {
    var usesPriorityEventTap: Bool { get }
    func register() throws
    func unregister()
}

extension ShortcutRegistration {
    var usesPriorityEventTap: Bool { false }
}

extension GlobalShortcut: ShortcutRegistration {}

/// 把配置里的快捷键绑定注册成系统热键。
final class ShortcutCenter: ObservableObject {
    typealias Factory = (GlobalShortcut.Combo, @escaping () -> Void) -> ShortcutRegistration
    private let config: ConfigStore
    private let makeShortcut: Factory
    private let performAction: (ShortcutAction) -> Void
    private let reportFailure: (String) -> Void
    private var shortcuts: [ShortcutAction: ShortcutRegistration] = [:]
    private var registeredBindings: [ShortcutAction: KeyBinding] = [:]
    private var observation: AnyCancellable?
    private var dispatchGeneration = UUID()
    private(set) var isRecording = false
    @Published private(set) var registrationFailures: [ShortcutAction: String] = [:]
    var onRegistrationFailuresChanged: (([ShortcutAction: String]) -> Void)?

    convenience init(environment: AppEnvironment) {
        self.init(config: environment.config, performAction: { [weak environment] action in
            guard let environment else { return }
            Self.perform(action, environment: environment)
        }, reportFailure: { [weak environment] message in
            environment?.toast.show(ToastMessage(text: message, style: .warning, duration: 6))
        })
    }

    init(config: ConfigStore,
         makeShortcut: @escaping Factory = {
             GlobalShortcut(combo: $0, prefersPriorityOnConflict: !AppPaths.isDevelopmentBuild, onTrigger: $1)
         },
         performAction: @escaping (ShortcutAction) -> Void,
         reportFailure: @escaping (String) -> Void) {
        self.config = config
        self.makeShortcut = makeShortcut
        self.performAction = performAction
        self.reportFailure = reportFailure
    }

    func registerAll() {
        unregisterAll()
        observation = config.$settings
            .map(\.shortcuts)
            .removeDuplicates()
            .sink { [weak self] bindings in
                // @Published 在 willSet 时发送，必须使用发出的值，不能回读 config。
                self?.apply(bindings)
            }
    }

    private func apply(_ bindings: [String: KeyBinding]) {
        guard !isRecording else { return }
        var failures: [ShortcutAction: String] = [:]
        var priorityFailures: Set<ShortcutAction> = []
        var actionsByBinding: [KeyBinding: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases {
            if let binding = bindings[action.rawValue] {
                actionsByBinding[binding, default: []].append(action)
            }
        }
        for actions in actionsByBinding.values where actions.count > 1 {
            for action in actions {
                failures[action] = "与\(actions.filter { $0 != action }.map(\.displayName).joined(separator: "、"))使用相同组合键"
            }
        }

        // 先释放所有变更项，再注册新项，允许两个动作交换快捷键。
        for action in Array(shortcuts.keys) {
            if registeredBindings[action] != bindings[action.rawValue] || failures[action] != nil {
                shortcuts.removeValue(forKey: action)?.unregister()
                registeredBindings.removeValue(forKey: action)
            }
        }
        for action in ShortcutAction.allCases {
            guard let binding = bindings[action.rawValue], failures[action] == nil,
                  shortcuts[action] == nil else { continue }
            let generation = dispatchGeneration
            let shortcut = makeShortcut(binding.combo) { [weak self] in
                guard let self, !self.isRecording,
                      self.dispatchGeneration == generation,
                      self.registeredBindings[action] == binding else { return }
                self.performAction(action)
            }
            do {
                try shortcut.register()
                shortcuts[action] = shortcut
                registeredBindings[action] = binding
                Log.shared.info("已向系统注册快捷键 \(action.rawValue) = \(binding.displayString)")
            } catch {
                shortcut.unregister()
                failures[action] = Self.describe(error)
                switch error as? GlobalShortcut.RegistrationError {
                case .accessibilityRequired, .priorityCaptureFailed: priorityFailures.insert(action)
                default: break
                }
                Log.shared.warn("快捷键注册失败 \(action.rawValue) = \(binding.displayString)：\(failures[action]!)")
            }
        }
        if failures != registrationFailures {
            let previous = registrationFailures
            registrationFailures = failures
            onRegistrationFailuresChanged?(failures)
            // 每项的完整原因保留在设置中。优先响应是可选功能，后台注册时不弹授权提示。
            let newlyFailed = ShortcutAction.allCases.filter { action in
                failures[action] != nil && failures[action] != previous[action] && !priorityFailures.contains(action)
            }
            if newlyFailed.count == 1, let action = newlyFailed.first, let binding = bindings[action.rawValue] {
                reportFailure("\(action.displayName)快捷键 \(binding.displayString) 不可用。详情见「设置 → 快捷键」。")
            } else if !newlyFailed.isEmpty {
                reportFailure("\(newlyFailed.count) 个快捷键不可用。详情见「设置 → 快捷键」。")
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? GlobalShortcut.RegistrationError else {
            return "\(error)"
        }
        switch error {
        case .alreadyRegistered: return "已经注册过"
        case .systemReserved: return "与已启用的 macOS 系统快捷键冲突，请更换组合键"
        case .systemRefused(let status):
            return status == eventHotKeyExistsErr
                ? "已被其他应用占用，请更换组合键"
                : "系统拒绝 OSStatus=\(status)"
        case .handlerInstallFailed(let status): return "事件处理器安装失败 OSStatus=\(status)"
        case .accessibilityRequired: return "组合键已被占用。可更换组合键，或在系统设置中允许 TapSnap 使用辅助功能以启用优先响应"
        case .priorityCaptureFailed: return "组合键已被占用，系统未能启用优先响应。可更换组合键"
        }
    }

    func retryFailedRegistrations() {
        guard !registrationFailures.isEmpty else { return }
        apply(config.settings.shortcuts)
    }

    func isBlockedBySecureInput(_ action: ShortcutAction, secureInputEnabled: Bool) -> Bool {
        secureInputEnabled && shortcuts[action]?.usesPriorityEventTap == true
    }

    /// 释放系统注册，让录制控件收到按键；配置观察保留，结束时应用最新配置。
    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        releaseRegistrations()
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        if observation != nil { apply(config.settings.shortcuts) }
    }

    /// 先验证系统能否接收组合键，成功后才保存。失败不覆盖原绑定。
    /// 返回值直接显示在录制控件内，nil 表示成功（包括清除绑定）。
    func setRecordedBinding(_ binding: KeyBinding?, for action: ShortcutAction) -> String? {
        if let binding,
           let conflict = ShortcutAction.allCases.first(where: {
               $0 != action && config.binding(for: $0) == binding
           }) {
            return "与“\(conflict.displayName)”使用相同组合键，请更换组合键"
        }
        if let binding, let conflict = OperationShortcut.all.first(where: { $0.binding(in: config.settings) == binding }) {
            return "与操作快捷键“\(conflict.title)”相同，请更换组合键"
        }
        let wasRecording = isRecording
        if !wasRecording { beginRecording() }
        defer { if !wasRecording { endRecording() } }
        if let binding {
            let probe = makeShortcut(binding.combo) {}
            defer { probe.unregister() }
            do {
                try probe.register()
            } catch {
                return Self.describe(error)
            }
        }
        config.setBinding(binding, for: action)
        return nil
    }

    func setRecordedBinding(_ binding: KeyBinding?, for operation: OperationShortcut) -> String? {
        if let binding {
            if let conflict = ShortcutAction.allCases.first(where: { config.binding(for: $0) == binding }) {
                return "与全局快捷键“\(conflict.displayName)”相同，请更换组合键"
            }
            if let conflict = OperationShortcut.all.first(where: { $0 != operation && $0.binding(in: config.settings) == binding }) {
                return "与操作快捷键“\(conflict.title)”相同，请更换组合键"
            }
        }
        config.update { settings in
            var keys = OperationShortcut.bindings(in: settings)
            keys[operation.id] = binding
            settings.operationShortcuts = keys
        }
        return nil
    }

    private func releaseRegistrations() {
        dispatchGeneration = UUID()
        shortcuts.values.forEach { $0.unregister() }
        shortcuts.removeAll()
        registeredBindings.removeAll()
    }

    func unregisterAll() {
        observation?.cancel()
        observation = nil
        isRecording = false
        releaseRegistrations()
        if !registrationFailures.isEmpty {
            registrationFailures.removeAll()
            onRegistrationFailuresChanged?([:])
        }
    }

    deinit { unregisterAll() }

    private static func perform(_ action: ShortcutAction, environment: AppEnvironment) {
        Log.shared.info("快捷键执行：\(action.rawValue)")
        switch action {
        case .screenshot:
            environment.captureCoordinator.start(.edit)
        case .screenshotAndPin:
            environment.captureCoordinator.start(.pin)
        case .pinFromClipboard:
            environment.pinTransfer.pinFromPasteboard()
        case .longShot:
            environment.longShot.start()
        case .recordScreen:
            environment.record.start()
        case .ocrRegion:
            environment.ocrCoordinator.captureAndRecognize()
        case .ocrFullScreen:
            environment.ocrCoordinator.recognizeFullScreen()
        case .quickTranslate:
            environment.captureCoordinator.start(.quickTranslate)
        case .showToolBall:
            ToolBallController.shared.toggle()
        case .showHistory:
            environment.clipboardPanel.toggle()
        }
    }
}

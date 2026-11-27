import Combine
import Foundation
import TapSnapSystem

/// 一条 Toast 消息。
///
/// 屏幕底部显示的短提示，多条时纵向堆叠。
public struct ToastMessage: Identifiable, Hashable, Sendable {
    public enum Style: String, Sendable {
        case info
        case success
        case warning
        case error
    }

    public let id = UUID()
    public var text: String
    public var style: Style
    public var duration: TimeInterval
    public var actionTitle: String?

    public init(text: String, style: Style = .info, duration: TimeInterval = 2.2, actionTitle: String? = nil) {
        self.text = text
        self.style = style
        self.duration = duration
        self.actionTitle = actionTitle
    }
}

/// Toast 队列。
public final class ToastCenter: ObservableObject {
    public static let shared = ToastCenter()

    @Published public private(set) var messages: [ToastMessage] = []
    /// 同时最多显示几条，超出时挤掉最早的。
    public var maxVisible = 3
    private var actions: [UUID: () -> Void] = [:]

    public init() {}

    public func show(_ message: ToastMessage, action: (() -> Void)? = nil) {
        if let action { actions[message.id] = action }
        let updated = Array((messages + [message]).suffix(max(0, maxVisible)))
        let retainedIDs = Set(updated.map(\.id))
        actions = actions.filter { retainedIDs.contains($0.key) }
        messages = updated
        let id = message.id
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, message.duration)) { [weak self] in
            self?.dismiss(id)
        }
    }

    public func info(_ text: String) { show(ToastMessage(text: text)) }
    public func success(_ text: String) { show(ToastMessage(text: text, style: .success)) }
    public func warning(_ text: String) { show(ToastMessage(text: text, style: .warning)) }
    public func error(_ text: String) { show(ToastMessage(text: text, style: .error, duration: 3.5)) }

    public func performAction(for id: UUID) {
        let handler = actions.removeValue(forKey: id)
        dismiss(id)
        handler?()
    }

    public func dismiss(_ id: UUID) {
        actions.removeValue(forKey: id)
        guard messages.contains(where: { $0.id == id }) else { return }
        messages.removeAll { $0.id == id }
    }

    public func dismissAll() {
        actions.removeAll()
        messages.removeAll()
    }
}

/// 权限引导弹窗的内容模型。
///
/// 描述申请权限的原因，并提供前往系统设置的入口。
public struct PermissionPrompt: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var permission: SystemPermission
    public var title: String
    public var message: String
    /// 是否已经在系统设置里被拒绝过（需要引导用户手动打开）。
    public var isDenied: Bool

    public init(permission: SystemPermission, title: String, message: String, isDenied: Bool) {
        self.permission = permission
        self.title = title
        self.message = message
        self.isDenied = isDenied
    }

    public func openSystemSettings() {
        Permissions.openSettingsPanel(for: permission)
    }
}

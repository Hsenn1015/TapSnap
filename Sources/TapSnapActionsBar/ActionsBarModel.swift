import Foundation
import TapSnapConfig

/// 工具栏的分组与排序。
///
/// 模型保存工具顺序，并按可用宽度将部分操作收纳到「更多」。
public struct ActionsBarModel: Codable, Hashable, Sendable {
    public var annotationTools: [ActionKind]
    public var outputActions: [ActionKind]
    /// 收进「更多」菜单的动作。
    public var overflow: [ActionKind]

    public init(
        annotationTools: [ActionKind] = ActionsBarModel.defaultAnnotationTools,
        outputActions: [ActionKind] = ActionsBarModel.defaultOutputActions,
        overflow: [ActionKind] = ActionsBarModel.defaultOverflow
    ) {
        self.annotationTools = annotationTools
        self.outputActions = outputActions
        self.overflow = overflow
    }

    public static let defaultAnnotationTools: [ActionKind] = [
        .arrow, .rectangle, .ellipse, .line, .pen, .text, .mosaic, .highlight,
        .serialNumber, .polygon, .spotlight, .eraser, .magnifier,
    ]

    public static let defaultOutputActions: [ActionKind] = [
        .privacy, .crop, .pin, .copy, .save, .print, .ocr, .translate,
    ]

    public static let defaultOverflow: [ActionKind] = [
        .qrCode, .longShot, .tableRecognize, .formula, .record, .watermark, .pathTag,
    ]

    /// Collapse buttons into More without changing their order when the selected annotation changes.
    public func layout(availableWidth: CGFloat? = nil, priorityOutputs: Set<ActionKind> = [.copy, .save],
                       fixedOutputs: Set<ActionKind> = [], showsHistory: Bool = true) -> ActionsBarLayout {
        var annotations = annotationTools
        var outputs = outputActions
        func result() -> ActionsBarLayout {
            let visible = Set(annotations + outputs)
            var seen = Set<ActionKind>()
            let hidden = (annotationTools + outputActions + overflow).filter {
                !visible.contains($0) && seen.insert($0).inserted
            }
            return ActionsBarLayout(annotationTools: annotations, outputActions: outputs,
                                    overflow: hidden, showsHistory: showsHistory)
        }
        guard let availableWidth, availableWidth.isFinite else { return result() }
        // Keep the first drawing tools and common outputs longer than less frequent actions.
        let collapsible = outputActions.reversed().filter { !priorityOutputs.contains($0) }
            + Array(annotationTools.dropFirst(4).reversed())
            + outputActions.reversed().filter { priorityOutputs.contains($0) }
            + Array(annotationTools.prefix(4).reversed())
        for action in collapsible where !fixedOutputs.contains(action) {
            if result().width <= availableWidth { break }
            annotations.removeAll { $0 == action }
            outputs.removeAll { $0 == action }
        }
        return result()
    }

    /// 悬停时的提示文字，带上该动作的快捷键。
    public func toolTip(for action: ActionKind, config: ConfigStore) -> String {
        let operation = OperationShortcut.action(action)
        if OperationShortcut.defaults[operation.id] != nil {
            return operation.displayTitle(in: config.settings)
        }
        guard let shortcut = action.shortcutAction,
              let binding = config.binding(for: shortcut)
        else {
            return action.title
        }
        return "\(action.title) \(binding.displayString)"
    }
}

/// The dock uses these same fixed button, divider, spacing and padding dimensions in its view.
public struct ActionsBarLayout: Equatable, Sendable {
    public let annotationTools: [ActionKind]
    public let outputActions: [ActionKind]
    public let overflow: [ActionKind]
    public let showsAnnotationDivider: Bool
    public let width: CGFloat

    public static let buttonSize: CGFloat = 28
    public static let spacing: CGFloat = 1
    public static let horizontalPadding: CGFloat = 6
    public static let confirmLeadingPadding: CGFloat = 2
    public static let dividerWidth: CGFloat = 7

    init(annotationTools: [ActionKind], outputActions: [ActionKind], overflow: [ActionKind], showsHistory: Bool) {
        self.annotationTools = annotationTools
        self.outputActions = outputActions
        self.overflow = overflow
        showsAnnotationDivider = showsHistory || !annotationTools.isEmpty
        let historyCount = showsHistory ? 2 : 0
        let buttonCount = annotationTools.count + outputActions.count
            + (overflow.isEmpty ? 0 : 1) + historyCount + 2 // Cancel and Confirm never collapse.
        let dividerCount = showsHistory ? 3 : (showsAnnotationDivider ? 2 : 1)
        width = CGFloat(buttonCount) * Self.buttonSize + CGFloat(dividerCount) * Self.dividerWidth
            + CGFloat(buttonCount + dividerCount - 1) * Self.spacing
            + Self.horizontalPadding * 2 + Self.confirmLeadingPadding
    }
}

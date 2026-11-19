import Foundation
import TapSnapActionsBar

enum SelectionToolbar {
    private static let captureModes: [ActionKind] = [.longShot, .record]
    private static let overflow = ActionsBarModel.defaultOverflow.filter { !captureModes.contains($0) }
    private static let standardModel = ActionsBarModel(
        outputActions: captureModes + [.edit] + ActionsBarModel.defaultOutputActions.filter { $0 != .copy },
        overflow: overflow
    )
    private static let editConfirmationModel = ActionsBarModel(
        outputActions: captureModes + ActionsBarModel.defaultOutputActions,
        overflow: overflow
    )
    private static let outputPriority: Set<ActionKind> = [.copy, .edit, .pin, .save]

    static let availableActions = standardModel.annotationTools + standardModel.outputActions + standardModel.overflow

    static func pinnedActions(from identifiers: [String]?) -> [ActionKind]? {
        var seen = Set<ActionKind>()
        return identifiers?.compactMap(ActionKind.init(rawValue:)).filter {
            availableActions.contains($0) && seen.insert($0).inserted
        }
    }

    static func layout(availableWidth: CGFloat, pinned: [ActionKind]? = nil, singleScreen: Bool = true,
                       copiesOnConfirm: Bool = true) -> ActionsBarLayout {
        if copiesOnConfirm, let pinned {
            let available = singleScreen ? availableActions : availableActions.filter { !captureModes.contains($0) }
            let visible = pinned.filter(available.contains)
            return ActionsBarModel(annotationTools: [], outputActions: visible,
                                   overflow: available.filter { !visible.contains($0) })
                .layout(availableWidth: availableWidth, priorityOutputs: [], showsHistory: false)
        }

        var model = copiesOnConfirm ? standardModel : editConfirmationModel
        let fixedModes = singleScreen ? Set(captureModes) : []
        if !singleScreen { model.outputActions.removeAll(where: captureModes.contains) }
        let layout = model.layout(availableWidth: availableWidth, priorityOutputs: outputPriority,
                                  fixedOutputs: copiesOnConfirm ? fixedModes.union([.edit]) : fixedModes,
                                  showsHistory: false)
        if copiesOnConfirm, layout.width > availableWidth {
            return model.layout(availableWidth: availableWidth, priorityOutputs: outputPriority,
                                fixedOutputs: fixedModes, showsHistory: false)
        }
        return layout
    }
}

using System.Collections.Generic;
using System.Linq;

namespace TapSnap.Windows;

internal sealed record OperationShortcut(string Id, string Title, Hotkey Default, AnnotationTool? Tool = null,
    CaptureAction? Output = null)
{
    private const uint Control = 2, Shift = 4;
    internal static readonly OperationShortcut Pin = new("pin", "贴图", new(Shift, 'P'), Output: CaptureAction.Pin);
    internal static readonly OperationShortcut Copy = new("copy", "复制", new(Control, 'C'), Output: CaptureAction.Copy);
    internal static readonly OperationShortcut Save = new("save", "保存", new(Control, 'S'), Output: CaptureAction.Save);
    internal static readonly OperationShortcut Undo = new("undo", "撤销", new(Control, 'Z'));
    internal static readonly OperationShortcut Redo = new("redo", "重做", new(Control, 'Y'));
    internal static readonly OperationShortcut ZoomIn = new("zoomIn", "放大画布", new(Control | Shift, 0xbb)); // VK_OEM_PLUS
    internal static readonly OperationShortcut ZoomOut = new("zoomOut", "缩小画布", new(Control, 0xbd)); // VK_OEM_MINUS
    internal static readonly OperationShortcut FitImage = new("fitImage", "适合窗口", new(Control, '0'));

    internal static readonly OperationShortcut[] All =
    [
        Pin, Copy, Save, Undo, Redo, ZoomIn, ZoomOut, FitImage,
        .. SelectionToolbarModel.EditableTools.Select(item =>
        {
            var tool = item.Tool!.Value;
            return new OperationShortcut(tool.ToString(), item.Title, new(0, SelectionToolbarModel.ToolKeys[tool]), Tool: tool);
        })
    ];

    internal static readonly IReadOnlyDictionary<string, Hotkey> Defaults = All.ToDictionary(action => action.Id, action => action.Default);

    internal Hotkey? Binding(IReadOnlyDictionary<string, Hotkey>? keys) => (keys ?? Defaults).GetValueOrDefault(Id);

    internal static OperationShortcut? ForTool(AnnotationTool tool) => All.FirstOrDefault(action => action.Tool == tool);
    internal static OperationShortcut? ForOutput(CaptureAction capture) => All.FirstOrDefault(action => action.Output == capture);

    internal static OperationShortcut? Match(Hotkey key, IReadOnlyDictionary<string, Hotkey>? keys)
    {
        var operation = All.FirstOrDefault(action => action.Binding(keys) == key);
        if (operation is not null) return operation;

        // Alternate forms of the defaults disappear when the action is rebound or cleared.
        var alternative = (key.Modifiers, key.KeyCode) switch
        {
            (Control, 0xbb or 0x6b) or (Control | Shift, 0x6b) => ZoomIn,
            (Control, 0x6d) => ZoomOut,
            (Control, 0x60) => FitImage,
            (Control | Shift, 'Z') => Redo,
            _ => null
        };
        return alternative is not null && alternative.Binding(keys) == alternative.Default ? alternative : null;
    }
}

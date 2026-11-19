using System;
using System.Collections.Generic;
using System.Linq;

namespace TapSnap.Windows;

internal enum CaptureAction { Edit, Copy, Save, Pin, LongShot, Record, Privacy, Text, Barcode, Table, Translation, Formula, Print }
internal enum AnnotationTool
{
    Arrow, Rectangle, Ellipse, Line, Pen, Text, Mosaic, Highlight, Number, Polygon,
    Spotlight, Eraser, Magnifier, Watermark, PathTag, Privacy, Crop
}

internal sealed record ToolbarItem(string Title, string Symbol, AnnotationTool? Tool = null, CaptureAction Action = CaptureAction.Edit);

internal static class SelectionToolbarModel
{
    internal static readonly IReadOnlyDictionary<AnnotationTool, char> ToolKeys = new Dictionary<AnnotationTool, char>
    {
        [AnnotationTool.Arrow] = 'A',
        [AnnotationTool.Rectangle] = 'R',
        [AnnotationTool.Ellipse] = 'O',
        [AnnotationTool.Line] = 'L',
        [AnnotationTool.Pen] = 'B',
        [AnnotationTool.Text] = 'T',
        [AnnotationTool.Mosaic] = 'M',
        [AnnotationTool.Highlight] = 'H',
        [AnnotationTool.Number] = 'N',
        [AnnotationTool.Polygon] = 'P',
        [AnnotationTool.Spotlight] = 'S',
        [AnnotationTool.Eraser] = 'E',
        [AnnotationTool.Magnifier] = 'G',
        [AnnotationTool.Watermark] = 'W',
        [AnnotationTool.PathTag] = 'U',
        [AnnotationTool.Privacy] = 'D',
        [AnnotationTool.Crop] = 'C',
    };

    internal static readonly ToolbarItem[] DrawingTools = [
        new("箭头", "↗", AnnotationTool.Arrow), new("矩形", "□", AnnotationTool.Rectangle),
        new("椭圆", "○", AnnotationTool.Ellipse), new("直线", "╱", AnnotationTool.Line),
        new("画笔", "✎", AnnotationTool.Pen), new("文字标注", "T", AnnotationTool.Text),
        new("马赛克", "▦", AnnotationTool.Mosaic), new("荧光笔", "▱", AnnotationTool.Highlight),
        new("序号", "#", AnnotationTool.Number), new("多边形", "⬠", AnnotationTool.Polygon),
        new("聚光灯", "◐", AnnotationTool.Spotlight), new("橡皮擦", "◇", AnnotationTool.Eraser),
        new("放大镜", "⌕", AnnotationTool.Magnifier)
    ];
    private static readonly ToolbarItem[] Modes = [
        new("长截图", "↕", Action: CaptureAction.LongShot), new("录屏", "●", Action: CaptureAction.Record)
    ];
    private static readonly ToolbarItem Edit = new("编辑 ↵", "edit");
    private static readonly ToolbarItem Copy = new("复制", "▢", Action: CaptureAction.Copy);
    private static readonly ToolbarItem Privacy = new("隐私打码", "shield", AnnotationTool.Privacy);
    private static readonly ToolbarItem Crop = new("裁剪", "⌗", AnnotationTool.Crop);
    private static readonly ToolbarItem[] Other = [
        new("翻译", "译", Action: CaptureAction.Translation), new("二维码／条码", "码", Action: CaptureAction.Barcode),
        new("表格识别", "表", Action: CaptureAction.Table), new("公式识别", "ƒ", Action: CaptureAction.Formula),
        new("水印", "水", AnnotationTool.Watermark), new("路径标签", "⌁", AnnotationTool.PathTag)
    ];
    internal static readonly ToolbarItem[] EditableTools = [.. DrawingTools, Privacy, Crop, .. Other.Where(item => item.Tool.HasValue)];

    // Two dividers, outer padding, More, Cancel and Confirm use fixed space.
    internal static int Slots(double width) => Math.Max(0, (int)((width - 30) / 29) - 3);

    internal static (ToolbarItem[] Tools, ToolbarItem[] Outputs, ToolbarItem[] More) Layout(int slots, bool singleScreen, bool copyOnConfirm)
    {
        var outputs = new List<ToolbarItem>();
        if (singleScreen) outputs.AddRange(Modes);
        if (copyOnConfirm) outputs.Add(Edit);
        outputs.Add(Privacy);
        outputs.Add(Crop);
        outputs.Add(new("贴图", "pin", Action: CaptureAction.Pin));
        if (!copyOnConfirm) outputs.Add(Copy);
        outputs.Add(new("保存", "↓", Action: CaptureAction.Save));
        outputs.Add(new("打印", "⎙", Action: CaptureAction.Print));
        outputs.Add(new("文字识别", "⌑", Action: CaptureAction.Text));
        var priority = outputs.Where(i => Modes.Contains(i) || i == Edit)
            .Concat(DrawingTools.Take(4)).Concat(outputs.Where(i => i.Action is CaptureAction.Copy or CaptureAction.Pin or CaptureAction.Save))
            .Concat(DrawingTools.Skip(4)).Concat(outputs).Distinct().Take(slots).ToHashSet();
        return (DrawingTools.Where(priority.Contains).ToArray(), outputs.Where(priority.Contains).ToArray(),
                DrawingTools.Concat(outputs).Where(i => !priority.Contains(i)).Concat(Other).ToArray());
    }
}

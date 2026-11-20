using System.Drawing;
using System.Text.Json;
using TapSnap.Windows;

var leftMonitor = new Rectangle(-2560, -180, 2560, 1440);
var selected = new Rectangle(-1900, 10, 500, 250);
var rightMonitor = new Rectangle(0, 0, 3840, 2160);
Check(SelectionGeometry.Create(new(-1400, 260), new(-1900, 10), leftMonitor) == selected,
    "左侧扩展屏从右下往左上拖动");
Check(SelectionGeometry.OffsetToImage(selected, leftMonitor) == new Rectangle(660, 190, 500, 250),
    "左侧扩展屏负坐标转换成抓屏像素");
Check(SelectionGeometry.Create(new(-45, 360), new(700, 260), leftMonitor) == new Rectangle(-45, 260, 45, 100),
    "限定单屏的滚动截图和录屏保留屏幕内选区");
var desktop = Rectangle.Union(leftMonitor, rightMonitor);
var across = Rectangle.FromLTRB(-45, 260, 700, 360);
Check(SelectionGeometry.Create(new(-45, 360), new(700, 260), desktop) == across &&
      SelectionGeometry.Create(new(700, 260), new(-45, 360), desktop) == across, "左右屏双向拖动得到同一物理像素选区");
var above = new Rectangle(300, -1440, 2560, 1440);
var vertical = Rectangle.Union(above, rightMonitor);
Check(SelectionGeometry.Create(new(400, -80), new(520, 100), vertical) == Rectangle.FromLTRB(400, -80, 520, 100),
    "从上屏拖到下屏保留接缝两侧的像素");
Check(SelectionGeometry.Move(across, desktop, -650, 15).Width == across.Width &&
      SelectionGeometry.Resize(across, desktop, 7, -70, 0).Left == -115, "跨屏选区可继续移动和调整边缘");
Check(SelectionGeometry.Create(new(12, 13), new(12, 13), rightMonitor) is null,
    "单击不创建占位选区");
Check(SelectionGeometry.Move(selected, leftMonitor, -1000, -1000) == new Rectangle(-2560, -180, 500, 250),
    "拖动选区遇到显示器边缘保留宽高");
Check(SelectionGeometry.Resize(selected, leftMonitor, 0, -900, -300) == Rectangle.FromLTRB(-2560, -180, -1400, 260),
    "左上控制点只移动左边和上边");
Check(SelectionGeometry.Resize(selected, leftMonitor, 3, 6000, -900) == Rectangle.FromLTRB(-1900, 10, 0, 260),
    "右侧控制点只移动右边");
Check(SelectionGeometry.Resize(selected, leftMonitor, 5, 0, -1000).Height == 2,
    "缩过对边时保留最小有效尺寸");

var laptopWorkArea = new Rectangle(0, 0, 1920, 1040);
var laptopRecording = new Rectangle(280, 150, 1280, 720);
Check(SelectionGeometry.PlaceRecordingControls(laptopWorkArea, laptopRecording, new(244, 58), 5) ==
      new Rectangle(838, 5, 244, 58), "普通屏幕上录屏按钮保留在顶部中央");
var largeWorkArea = new Rectangle(-3840, -2070, 3840, 2070);
var wideRecording = new Rectangle(-3840, -2160, 3840, 1750);
var largeControls = SelectionGeometry.PlaceRecordingControls(largeWorkArea, wideRecording, new(488, 116), 10);
Check(largeWorkArea.Contains(largeControls) && largeControls.Size == new Size(488, 116) &&
      !largeControls.IntersectsWith(wideRecording), "200% 缩放的 4K 副屏上，完整的录屏按钮避开宽选区和任务栏");
var fullHeightRecording = new Rectangle(-3400, -2160, 2800, 2160);
var sideControls = SelectionGeometry.PlaceRecordingControls(largeWorkArea, fullHeightRecording, new(366, 87), 8);
Check(largeWorkArea.Contains(sideControls) && !sideControls.IntersectsWith(fullHeightRecording),
    "150% 缩放时，录满高度的选区旁仍有空间显示录屏按钮");
var fullScreenControls = SelectionGeometry.PlaceRecordingControls(largeWorkArea, largeWorkArea, new(488, 116), 10);
Check(fullScreenControls == new Rectangle(-2164, -2060, 488, 116),
    "录满显示器时，录屏按钮完整地留在录制显示器内");

foreach (bool singleScreen in new[] { true, false })
foreach (bool copies in new[] { true, false })
foreach (int width in new[] { 240, 396, 760, 1600 })
{
    int slots = SelectionToolbarModel.Slots(width);
    var dock = SelectionToolbarModel.Layout(slots, singleScreen, copies);
    var all = dock.Tools.Concat(dock.Outputs).Concat(dock.More).ToList();
    Check(all.Distinct().Count() == all.Count && dock.Tools.Length + dock.Outputs.Length <= slots &&
        SelectionToolbarModel.DrawingTools.All(all.Contains), "框选工具栏缩窄时完整保留标注工具且不重复");
    Check(all.Any(i => i.Action == CaptureAction.Record) == singleScreen &&
          all.Any(i => i.Action == CaptureAction.LongShot) == singleScreen, "跨屏选区从主栏和更多中同时移除单屏录制动作");
    Check(all.Any(i => i.Action == CaptureAction.Edit && i.Tool == null) == copies &&
          all.Any(i => i.Action == CaptureAction.Copy) != copies, "普通截图以勾选复制，预设或隐私截图保留编辑确认");
}

foreach (AnnotationTool tool in Enum.GetValues<AnnotationTool>())
{
    var shortcut = OperationShortcut.ForTool(tool);
    Check(shortcut is { Default.Modifiers: 0 } && OperationShortcut.Match(shortcut.Default, null)?.Tool == tool,
        $"标注工具 {tool} 的提示和单键绑定一致");
}
Check(OperationShortcut.Match(new(0, 'C'), null)?.Tool == AnnotationTool.Crop &&
      OperationShortcut.Match(new(0, 'T'), null)?.Tool == AnnotationTool.Text &&
      OperationShortcut.Match(new(0, '1'), null) is null, "框选识别裁剪和文字单键，忽略未绑定的键");
Check(OperationShortcut.Match(new(4, 'P'), null)?.Output == CaptureAction.Pin &&
      OperationShortcut.Match(new(0, 'P'), null)?.Tool == AnnotationTool.Polygon, "Shift+P 贴图，单按 P 保留多边形工具");
var oldSettings = JsonSerializer.Deserialize<Settings>("{}")!;
Check(oldSettings.SelectionToolbarActions is null, "旧配置继续采用默认框选工具栏");
oldSettings.SelectionToolbarActions = ["action:Text", "tool:Text", "action:Pin", "action:Record", "action:Text", "unknown", "action:Copy"];
var configured = JsonSerializer.Deserialize<Settings>(JsonSerializer.Serialize(oldSettings))!;
var custom = SelectionToolbarModel.Layout(3, true, true, configured.SelectionToolbarActions);
Check(custom.Outputs.Select(item => item.Id).SequenceEqual(new[] { "action:Text", "tool:Text", "action:Pin" }) &&
      custom.More[0].Action == CaptureAction.Record &&
      custom.Outputs.Concat(custom.More).ToHashSet().SetEquals(SelectionToolbarModel.AvailableActions) &&
      custom.Outputs.Length + custom.More.Length == SelectionToolbarModel.AvailableActions.Length,
    "自定义顺序持久化，区分文字识别和文字标注，其余项目收进更多且无重复");
var cross = SelectionToolbarModel.Layout(10, false, true, configured.SelectionToolbarActions);
Check(!cross.Outputs.Concat(cross.More).Any(item => item.Action is CaptureAction.Record or CaptureAction.LongShot),
    "跨屏框选从自定义工具栏和更多中移除录屏与长截图");
var minimal = SelectionToolbarModel.Layout(10, true, true, []);
var presetDock = SelectionToolbarModel.Layout(10, true, false, configured.SelectionToolbarActions);
Check(minimal.Outputs.Length == 0 && minimal.Tools.Length == 0 &&
      minimal.More.Length == SelectionToolbarModel.AvailableActions.Length &&
      presetDock.Outputs.SequenceEqual(SelectionToolbarModel.Layout(10, true, false).Outputs),
    "允许只显示固定操作，预设截图保留自己的确认流程");
Check(OperationShortcut.Pin.Binding(oldSettings.OperationHotkeys) == new Hotkey(4, 'P'),
    "旧配置自动使用默认操作键位");
oldSettings.OperationHotkeys = new(OperationShortcut.Defaults) { [OperationShortcut.Pin.Id] = new(0, 'J') };
oldSettings.OperationHotkeys.Remove(OperationShortcut.Copy.Id);
var reloaded = JsonSerializer.Deserialize<Settings>(JsonSerializer.Serialize(oldSettings))!;
Check(OperationShortcut.Match(new(0, 'J'), reloaded.OperationHotkeys)?.Output == CaptureAction.Pin &&
      OperationShortcut.Match(new(4, 'P'), reloaded.OperationHotkeys) is null &&
      OperationShortcut.Copy.Binding(reloaded.OperationHotkeys) is null &&
      OperationShortcut.Save.Binding(reloaded.OperationHotkeys) == OperationShortcut.Save.Default,
    "自定义键位和清除状态重启后保留");
Check(OperationShortcut.Match(new(6, 'Z'), null) == OperationShortcut.Redo &&
      OperationShortcut.Match(new(2, 0xbb), null) == OperationShortcut.ZoomIn &&
      OperationShortcut.Match(new(2, 0xbb), new Dictionary<string, Hotkey>()) is null,
    "重做和缩放的默认备用键会随清除而停用");

static void Check(bool passed, string description)
{
    if (!passed) throw new InvalidOperationException(description);
    Console.WriteLine($"通过 {description}");
}

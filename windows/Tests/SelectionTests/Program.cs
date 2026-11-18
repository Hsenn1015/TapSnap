using System.Drawing;
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

static void Check(bool passed, string description)
{
    if (!passed) throw new InvalidOperationException(description);
    Console.WriteLine($"通过 {description}");
}

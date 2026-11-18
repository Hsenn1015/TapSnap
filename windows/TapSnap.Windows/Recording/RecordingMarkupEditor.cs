using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TapSnap.Windows;

internal sealed class RecordingMarkupEditor : FrameworkElement
{
    internal static readonly (AnnotationTool Kind, string Title, string Symbol)[] Tools = [
        (AnnotationTool.Arrow, "箭头", "↗"), (AnnotationTool.Rectangle, "方框", "□"),
        (AnnotationTool.Ellipse, "椭圆", "○"), (AnnotationTool.Line, "直线", "╱"),
        (AnnotationTool.Pen, "画笔", "✎"), (AnnotationTool.Highlight, "高亮", "▱"),
        (AnnotationTool.Text, "文字", "T"), (AnnotationTool.Privacy, "打码", "shield") ];
    private readonly BitmapSource reference;
    private readonly SnapPalette palette;
    private readonly double duration;
    private readonly int fps;
    private readonly Dictionary<AnnotationTool, Button> buttons = new();
    private readonly Dictionary<AnnotationTool, AnnotationStyle> styles = new();
    private readonly Stack<(RecordingMark[] Items, int Selection)> undo = new(), redo = new();
    private readonly TextBox startField = Field("标注开始秒数"), endField = Field("标注结束秒数"), textField = Field("标注文字", 118);
    private readonly WrapPanel inspector = new();
    private readonly Button undoButton, redoButton, styleButton;
    private Drawing[] drawings = [];
    private readonly List<Point> path = [];
    private Point? down;
    private bool resizing;
    private Annotation? draft;
    private AnnotationTool? tool;
    private double time, trimEnd;
    internal RecordingMark[] Items { get; private set; }
    internal int Selection { get; private set; } = -1;
    internal StackPanel Controls { get; } = new();
    internal Panel Inspector => inspector;
    internal event Action? Changed, Pause;
    internal event Action<double>? Seek;

    public RecordingMarkupEditor(BitmapSource reference, RecordingMark[] marks, double duration, int fps, SnapPalette palette)
    {
        this.reference = reference;
        this.duration = trimEnd = duration;
        this.fps = fps;
        this.palette = palette;
        Items = marks;
        Focusable = true;
        ClipToBounds = true;
        AutomationProperties.SetName(this, "录屏标注画布");
        var row = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center };
        Controls.Children.Add(row);
        foreach (var (kind, label, symbol) in Tools)
        {
            var button = Icon(row, label, symbol, () => ChooseTool(tool == kind ? null : kind));
            buttons.Add(kind, button);
        }
        row.Children.Add(ToolbarGlyph.Divider(palette));
        undoButton = Icon(row, "撤销", "↶", () => History(false));
        redoButton = Icon(row, "重做", "↷", () => History(true));
        styleButton = Icon(row, "标注样式", "settings", ShowStyles);
        inspector.HorizontalAlignment = HorizontalAlignment.Center;
        Label(inspector, "标注时段");
        inspector.Children.Add(startField);
        Label(inspector, "至");
        inspector.Children.Add(endField);
        Label(inspector, "秒");
        var single = RecordingWindow.Button("仅此帧", SingleFrame);
        inspector.Children.Add(single);
        inspector.Children.Add(textField);
        Icon(inspector, "删除标注", "delete", DeleteSelection);
        BindField(startField, CommitRange);
        BindField(endField, CommitRange);
        BindField(textField, CommitText);
        Refresh();
    }

    private static TextBox Field(string label, int width = 61)
    {
        var box = new TextBox { Width = width, Margin = new Thickness(3, 1, 3, 1), VerticalContentAlignment = VerticalAlignment.Center, ToolTip = label };
        AutomationProperties.SetName(box, label);
        return box;
    }
    private static void BindField(TextBox box, Action commit)
    {
        box.LostKeyboardFocus += (_, _) => commit();
        box.PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter) { commit(); e.Handled = true; } };
    }
    private static void Label(Panel row, string text) => row.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(3) });
    private Button Icon(Panel row, string label, string symbol, Action run)
    {
        var button = ToolbarGlyph.CreateButton(label, symbol, palette);
        button.Click += (_, _) => run();
        row.Children.Add(button);
        return button;
    }

    private AnnotationStyle StyleFor(AnnotationTool kind)
    {
        if (styles.TryGetValue(kind, out var style)) return style;
        double factor = Math.Min(reference.PixelWidth, reference.PixelHeight) / 720d;
        return new AnnotationStyle { Color = kind switch {
            AnnotationTool.Text => Colors.White, AnnotationTool.Highlight => Color.FromRgb(252, 217, 102), AnnotationTool.Privacy => Colors.Black,
            _ => Color.FromRgb(87, 227, 189) }, LineWidth = Math.Max(1, 5 * factor),
            FontSize = Math.Max(1, 36 * factor), Bold = true, TextBackground = Color.FromRgb(24, 24, 24) };
    }

    private void ShowStyles()
    {
        var kind = Selection >= 0 ? Items[Selection].Shape.Tool : tool;
        if (kind == null) return;
        var style = Selection >= 0 ? Items[Selection].Shape.Style : StyleFor(kind.Value);
        var menu = new ContextMenu { PlacementTarget = styleButton };
        void Option(string label, AnnotationStyle next, bool active)
        {
            var item = new MenuItem { Header = label, IsChecked = active };
            item.Click += (_, _) => {
                styles[kind.Value] = next;
                if (Selection >= 0) Replace(Items[Selection] with { Shape = Items[Selection].Shape with { Style = next } });
            };
            menu.Items.Add(item);
        }
        foreach (var (name, color) in new[] { ("薄荷绿", Color.FromRgb(87, 227, 189)), ("红色", Colors.Red), ("黄色", Colors.Gold), ("白色", Colors.White), ("黑色", Colors.Black) })
            Option(name, style with { Color = color }, style.Color == color);
        double scale = Math.Min(reference.PixelWidth, reference.PixelHeight) / 720d;
        if (kind != AnnotationTool.Privacy) menu.Items.Add(new Separator());
        foreach (int n in kind switch { AnnotationTool.Text => new[] { 18, 24, 36, 48 }, AnnotationTool.Privacy => Array.Empty<int>(), _ => new[] { 2, 5, 8, 12 } })
        {
            double size = Math.Max(1, n * scale);
            bool isText = kind == AnnotationTool.Text;
            Option((isText ? "字号 " : "线宽 ") + n, isText ? style with { FontSize = size } : style with { LineWidth = size },
                Math.Abs((isText ? style.FontSize : style.LineWidth) - size) < .01);
        }
        if (kind is AnnotationTool.Arrow or AnnotationTool.Line or AnnotationTool.Rectangle or AnnotationTool.Ellipse or AnnotationTool.Pen)
        {
            menu.Items.Add(new Separator());
            foreach (var (label, pattern) in new[] { ("实线", StrokePattern.Solid), ("虚线", StrokePattern.Dash), ("点线", StrokePattern.Dot) })
                Option(label, style with { Pattern = pattern }, style.Pattern == pattern);
        }
        if (kind is AnnotationTool.Rectangle or AnnotationTool.Ellipse)
            Option("填充", style with { Fill = style.Fill == ShapeFill.Outline ? ShapeFill.Both : ShapeFill.Outline }, style.Fill != ShapeFill.Outline);
        if (kind == AnnotationTool.Text)
        {
            Option("粗体", style with { Bold = !style.Bold }, style.Bold);
            Option("文字底色", style with { TextBackground = style.TextBackground == null ? Color.FromRgb(24, 24, 24) : null }, style.TextBackground != null);
        }
        menu.IsOpen = true;
    }

    internal bool CancelTool()
    {
        if (tool == null && down == null) return false;
        if (IsMouseCaptured) ReleaseMouseCapture();
        ChooseTool(null);
        return true;
    }
    private void ChooseTool(AnnotationTool? value)
    {
        Pause?.Invoke();
        tool = value;
        Selection = -1;
        Cursor = value == null ? Cursors.Arrow : Cursors.Cross;
        Refresh();
    }

    internal void SelectMark(int index, bool reveal)
    {
        Pause?.Invoke();
        tool = null;
        Cursor = Cursors.Arrow;
        Selection = index;
        if (reveal && index >= 0 && !Items[index].Active(time)) Seek?.Invoke(Items[index].Start);
        Refresh();
    }
    internal void SetTime(double value, double end)
    {
        trimEnd = end;
        bool changed = Items.Any(m => m.Active(time) != m.Active(value));
        time = value;
        if (changed) InvalidateVisual();
    }
    private double FrameStart => Math.Floor(Math.Min(time, Math.BitDecrement(duration)) * fps + 1e-7) / fps;
    private void SingleFrame()
    {
        if (Selection < 0) return;
        Pause?.Invoke();
        double start = Math.Min(FrameStart, (Math.Ceiling(duration * fps) - 1) / fps);
        Replace(Items[Selection] with { Start = start, End = Math.Min(duration, start + 1d / fps) });
    }
    private void CommitText()
    {
        if (Selection < 0 || Items[Selection].Shape.Tool != AnnotationTool.Text) return;
        var mark = Items[Selection];
        if (!string.IsNullOrWhiteSpace(textField.Text)) Replace(mark with { Shape = mark.Shape with { Text = textField.Text } });
        else textField.Text = mark.Shape.Text;
    }
    private static string Seconds(double value) => value.ToString("0.###", CultureInfo.CurrentCulture);
    private void CommitRange()
    {
        if (Selection < 0) return;
        var old = Items[Selection];
        // Preserve exact frame boundaries if only the other text field was edited.
        double Parse(TextBox box, double prior) => box.Text == Seconds(prior) ? prior :
            double.TryParse(box.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out var n) ? n : double.NaN;
        double from = Parse(startField, old.Start), to = Parse(endField, old.End);
        if (from == old.Start && to == old.End) return;
        if (from >= 0 && to <= duration && from < to)
        {
            Replace(old with { Start = from, End = to });
            if (!Items[Selection].Active(time)) Seek?.Invoke(from);
        }
        else { startField.Text = Seconds(old.Start); endField.Text = Seconds(old.End); }
    }

    internal void ChangeRange(int index, double start, double end)
    {
        if (start < 0 || end > duration || end <= start) return;
        Selection = index;
        Replace(Items[index] with { Start = start, End = end });
    }
    internal void History(bool forward)
    {
        if (IsMouseCaptured) ReleaseMouseCapture();
        var source = forward ? redo : undo;
        if (!source.TryPop(out var state)) return;
        (forward ? undo : redo).Push((Items, Selection));
        (Items, Selection) = state;
        Refresh();
    }
    internal void DeleteSelection()
    {
        if (IsMouseCaptured) ReleaseMouseCapture();
        if (Selection >= 0) Change(Items.Where((_, i) => i != Selection).ToArray(), -1);
    }
    private void Replace(RecordingMark mark)
    {
        if (mark == Items[Selection]) return;
        var next = (RecordingMark[])Items.Clone();
        next[Selection] = mark;
        Change(next, Selection);
    }
    private void Change(RecordingMark[] next, int index)
    {
        undo.Push((Items, Selection));
        redo.Clear();
        Items = next;
        Selection = index;
        Refresh();
    }
    private void Refresh()
    {
        drawings = Items.Select(m => m.Drawing(reference)).ToArray();
        foreach (var pair in buttons) pair.Value.Background = pair.Key == tool ? palette.Hover : Brushes.Transparent;
        undoButton.IsEnabled = undo.Count > 0;
        redoButton.IsEnabled = redo.Count > 0;
        var current = Selection >= 0 ? Items[Selection] : null;
        var kind = current?.Shape.Tool ?? tool;
        styleButton.IsEnabled = kind != null;
        inspector.Visibility = current == null ? Visibility.Collapsed : Visibility.Visible;
        if (current != null)
        {
            startField.Text = Seconds(current.Start);
            endField.Text = Seconds(current.End);
            textField.Visibility = kind == AnnotationTool.Text ? Visibility.Visible : Visibility.Collapsed;
            textField.Text = current.Shape.Text;
        }
        InvalidateVisual();
        Changed?.Invoke();
    }

    private double Scale => Math.Max(.000001, Math.Min(ActualWidth / reference.PixelWidth, ActualHeight / reference.PixelHeight));
    private Rect Picture => new((ActualWidth - reference.PixelWidth * Scale) / 2, (ActualHeight - reference.PixelHeight * Scale) / 2,
        reference.PixelWidth * Scale, reference.PixelHeight * Scale);
    private Point SourcePoint(Point p) => new(Math.Clamp((p.X - Picture.X) / Scale, 0, reference.PixelWidth),
        Math.Clamp((p.Y - Picture.Y) / Scale, 0, reference.PixelHeight));

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        dc.PushClip(new RectangleGeometry(Picture));
        dc.PushTransform(new MatrixTransform(Scale, 0, 0, Scale, Picture.X, Picture.Y));
        for (int i = 0; i < Items.Length; i++)
            if (Items[i].Active(time) && !(draft != null && tool == null && i == Selection)) dc.DrawDrawing(drawings[i]);
        if (draft != null) dc.DrawDrawing(new RecordingMark(draft, 0, duration).Drawing(reference));
        if (Selection >= 0 && Items[Selection].Active(time))
        {
            var bounds = (draft ?? Items[Selection].Shape).Bounds;
            dc.DrawRectangle(null, new Pen(palette.Ring, 1 / Scale) { DashStyle = DashStyles.Dash }, bounds);
            double size = 6 / Scale;
            dc.DrawRectangle(Brushes.White, null, new Rect(bounds.Right - size / 2, bounds.Bottom - size / 2, size, size));
        }
        dc.Pop();
        dc.Pop();
    }
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        var mouse = e.GetPosition(this);
        if (!Picture.Contains(mouse)) return;
        Focus();
        Pause?.Invoke();
        Point point = SourcePoint(mouse);
        resizing = false;
        if (tool == null)
        {
            resizing = Selection >= 0 && Items[Selection].Active(time) && (Items[Selection].Shape.Bounds.BottomRight - point).Length <= 8 / Scale;
            if (!resizing) SelectMark(Array.FindLastIndex(Items, m => m.Active(time) && m.Shape.Hit(point, 5 / Scale)), false);
            if (Selection < 0) return;
        }
        if (!CaptureMouse()) return;
        down = point;
        path.Clear();
        path.Add(point);
        e.Handled = true;
    }
    private Annotation Draft(Point point)
    {
        var origin = down!.Value;
        if (tool == null)
        {
            var shape = Items[Selection].Shape;
            var bounds = shape.Bounds;
            if (resizing) return shape.Resize(new Rect(bounds.TopLeft, new Point(Math.Max(bounds.Left + 1, point.X), Math.Max(bounds.Top + 1, point.Y))));
            var offset = point - origin;
            return shape.Move(new Vector(Math.Clamp(offset.X, -bounds.Left, reference.PixelWidth - bounds.Right),
                Math.Clamp(offset.Y, -bounds.Top, reference.PixelHeight - bounds.Bottom)));
        }
        var kind = tool.Value;
        var style = StyleFor(kind);
        if (kind is AnnotationTool.Pen or AnnotationTool.Highlight)
        {
            if (path[^1] != point) path.Add(point);
            return new(kind, path.Count > 1 ? path.ToArray() : new[] { origin, point }, style);
        }
        if (kind == AnnotationTool.Text && (Math.Abs(point.X - origin.X) * Scale < 5 || Math.Abs(point.Y - origin.Y) * Scale < 5))
        {
            double w = Math.Min(reference.PixelWidth, style.FontSize * 6), h = Math.Min(reference.PixelHeight, style.FontSize * 1.7);
            origin = new Point(Math.Min(origin.X, reference.PixelWidth - w), Math.Min(origin.Y, reference.PixelHeight - h));
            point = new Point(origin.X + w, origin.Y + h);
        }
        return new(kind, new[] { origin, point }, style, kind == AnnotationTool.Text ? "文字" : "");
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (down != null) { draft = Draft(SourcePoint(e.GetPosition(this))); InvalidateVisual(); }
    }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (down is not Point origin) return;
        var last = SourcePoint(e.GetPosition(this));
        var shape = Draft(last);
        bool moved = (last - origin).Length * Scale >= 2 || path.Count > 2;
        ReleaseMouseCapture();
        if (tool == null) { if (moved) Replace(Items[Selection] with { Shape = shape }); }
        else if ((moved || tool == AnnotationTool.Text) &&
                 (tool is not (AnnotationTool.Privacy or AnnotationTool.Rectangle or AnnotationTool.Ellipse) || shape.Bounds is { Width: >= 1, Height: >= 1 }))
        {
            bool mask = tool == AnnotationTool.Privacy;
            double start = mask ? 0 : Math.Min(FrameStart, (Math.Ceiling(trimEnd * fps) - 1) / fps);
            Change(Items.Append(new(shape, start, mask ? duration : Math.Min(trimEnd, start + 2))).ToArray(), Items.Length);
            if (tool == AnnotationTool.Text) { textField.Focus(); textField.SelectAll(); }
        }
        e.Handled = true;
    }
    protected override void OnLostMouseCapture(MouseEventArgs e) { down = null; draft = null; InvalidateVisual(); }
}

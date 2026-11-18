using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TapSnap.Windows;

internal sealed class RecordingTimeline : FrameworkElement
{
    private const double Inset = 9, FilmHeight = 40, LaneHeight = 16;
    private readonly double duration;
    private readonly double frameDuration;
    private readonly SnapPalette palette;
    private ImageBrush[] film = [];
    private RecordingMark[] marks = [];
    private FormattedText[] labels = [];
    private int selected = -1;
    private double start, end, head, grabOffset;
    private enum Target { None, Start, End, Playhead, MarkStart, MarkEnd, MarkBody }
    private Target drag;
    private int draggedMark = -1;
    private double markStart, markEnd;
    internal event Action<double>? Seek;
    internal event Action<bool, double>? Trim;
    internal event Action<int>? SelectMark;
    internal event Action<int, double, double>? MarkRange;

    public RecordingTimeline(double duration, int fps, SnapPalette palette)
    {
        this.duration = end = duration;
        frameDuration = 1d / fps;
        this.palette = palette;
        Height = FilmHeight + 6;
        Cursor = Cursors.Cross;
        AutomationProperties.SetName(this, "录屏时间轴");
        ToolTip = "点击缩略图定位，拖动两端裁剪";
    }

    internal void SetFilm(BitmapSource[] source)
    {
        film = Array.ConvertAll(source, image => {
            var brush = new ImageBrush(image) { Stretch = Stretch.UniformToFill };
            brush.Freeze();
            return brush;
        });
        InvalidateVisual();
    }

    internal void Range(double from, double to) { start = from; end = to; InvalidateVisual(); }
    internal void Playhead(double seconds) { head = seconds; InvalidateVisual(); }
    internal void Marks(RecordingMark[] items, int selection)
    {
        if (marks == items && selected == selection) return;
        marks = items;
        selected = selection;
        labels = marks.Select(m => new FormattedText(RecordingMarkupEditor.Tools.First(t => t.Kind == m.Shape.Tool).Title,
            CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 10,
            palette.PrimaryForeground, VisualTreeHelper.GetDpi(this).PixelsPerDip)).ToArray();
        Height = FilmHeight + 6 + LaneHeight * marks.Length;
        InvalidateVisual();
        if (selected >= 0 && IsLoaded) BringIntoView(new Rect(0, FilmHeight + 6 + LaneHeight * selected, 1, LaneHeight));
    }

    private double TrackWidth => Math.Max(1, ActualWidth - 2 * Inset);
    private double X(double time) => Inset + TrackWidth * time / duration;
    private double Time(double x) => duration * Math.Clamp((x - Inset) / TrackWidth, 0, 1);

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        var track = new Rect(Inset, 3, TrackWidth, FilmHeight);
        dc.DrawRoundedRectangle(palette.Input, null, track, 4, 4);
        for (int i = 0; i < film.Length; i++)
        {
            double cell = TrackWidth / film.Length;
            dc.DrawRectangle(film[i], null, new Rect(Inset + i * cell, 3, cell, FilmHeight));
        }
        double left = X(start), right = X(end);
        dc.DrawRectangle(SnapTheme.Brush(0, 145), null, new Rect(Inset, 3, Math.Max(0, left - Inset), FilmHeight));
        dc.DrawRectangle(SnapTheme.Brush(0, 145), null, new Rect(right, 3, Math.Max(0, X(duration) - right), FilmHeight));
        dc.DrawRectangle(null, new Pen(palette.Ring, 2), new Rect(left, 4, Math.Max(0, right - left), FilmHeight - 2));
        foreach (double x in new[] { left - Inset, right })
        {
            dc.DrawRoundedRectangle(palette.Ring, null, new Rect(x, 3, Inset, FilmHeight), 3, 3);
            dc.DrawLine(new Pen(palette.Background, 1.5), new Point(x + Inset / 2, 18), new Point(x + Inset / 2, 28));
        }
        for (int i = 0; i < marks.Length; i++)
        {
            var m = marks[i];
            double a = X(i == draggedMark ? markStart : m.Start), b = X(i == draggedMark ? markEnd : m.End);
            var lane = new Rect(a, FilmHeight + 7 + i * LaneHeight, Math.Max(3, b - a), 12);
            dc.DrawRoundedRectangle(i == selected ? palette.Primary : palette.Muted, null, lane, 3, 3);
            if (lane.Width > labels[i].Width + 16) dc.DrawText(labels[i], new Point(lane.X + 7, lane.Y - 1));
            if (i == selected && lane.Width > 12)
                foreach (double x in new[] { lane.Left + 3, lane.Right - 3 })
                    dc.DrawLine(new Pen(palette.PrimaryForeground, 1), new Point(x, lane.Top + 3), new Point(x, lane.Bottom - 3));
        }
        dc.DrawLine(new Pen(Brushes.Black, 4), new Point(X(head), 1), new Point(X(head), FilmHeight + 5));
        dc.DrawLine(new Pen(Brushes.White, 2), new Point(X(head), 1), new Point(X(head), FilmHeight + 5));
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        var point = e.GetPosition(this);
        if (point.Y > FilmHeight + 5)
        {
            int i = (int)((point.Y - FilmHeight - 6) / LaneHeight);
            if (i < 0 || i >= marks.Length || point.X < X(marks[i].Start) - 3 || point.X > X(marks[i].End) + 3) return;
            SelectMark?.Invoke(i);
            if (!CaptureMouse()) return;
            draggedMark = i;
            markStart = marks[i].Start;
            markEnd = marks[i].End;
            double left = Math.Abs(point.X - X(markStart)), right = Math.Abs(point.X - X(markEnd));
            drag = Math.Min(left, right) > 5 ? Target.MarkBody : left <= right ? Target.MarkStart : Target.MarkEnd;
            grabOffset = Time(point.X);
            e.Handled = true;
            return;
        }
        double l = point.X - X(start), r = point.X - X(end);
        drag = Math.Min(Math.Abs(l), Math.Abs(r)) > Inset ? Target.Playhead : Math.Abs(l) <= Math.Abs(r) ? Target.Start : Target.End;
        grabOffset = drag == Target.Start ? l : drag == Target.End ? r : 0;
        CaptureMouse();
        Scrub(point.X);
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (IsMouseCaptured) Scrub(e.GetPosition(this).X);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (!IsMouseCaptured) return;
        Scrub(e.GetPosition(this).X);
        if (draggedMark >= 0) MarkRange?.Invoke(draggedMark, markStart, markEnd);
        ReleaseMouseCapture();
        e.Handled = true;
    }

    protected override void OnLostMouseCapture(MouseEventArgs e) { drag = Target.None; draggedMark = -1; InvalidateVisual(); }
    private void Scrub(double x)
    {
        if (draggedMark >= 0)
        {
            var m = marks[draggedMark];
            double delta = Time(x) - grabOffset;
            double min = Math.Min(frameDuration, m.End - m.Start);
            if (drag == Target.MarkStart) markStart = Math.Clamp(m.Start + delta, 0, Math.Max(0, m.End - min));
            else if (drag == Target.MarkEnd) markEnd = Math.Clamp(m.End + delta, Math.Min(duration, m.Start + min), duration);
            else { delta = Math.Clamp(delta, -m.Start, duration - m.End); markStart = m.Start + delta; markEnd = m.End + delta; }
            InvalidateVisual();
            return;
        }
        double seconds = Time(x - grabOffset);
        if (drag == Target.Playhead) Seek?.Invoke(seconds);
        else if (drag != Target.None) Trim?.Invoke(drag == Target.Start, seconds);
    }
}

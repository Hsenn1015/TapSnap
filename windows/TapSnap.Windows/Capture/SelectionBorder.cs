using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Media;

namespace TapSnap.Windows;

internal sealed class SelectionBorder : FrameworkElement
{
    private static readonly uint[] Aurora = [0x1fe0ff, 0x855cff, 0xff52cc, 0x61a6ff, 0x47ffcf];
    private static readonly uint[] Mint = [0x68e1f7, 0x93acff, 0xb49bff, 0x6cebc2];
    private const int GradientSegments = 64;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private Rect rim = Rect.Empty;
    private string style;
    private bool handles;
    private bool listening;
    private Geometry[]? gradientPath;

    public SelectionBorder(string style)
    {
        this.style = style;
        IsHitTestVisible = false;
        Unloaded += (_, _) => Listen(false);
        IsVisibleChanged += (_, _) => Refresh();
    }

    public static Rect Outline(Rect selection, Rect bounds)
    {
        if (selection.IsEmpty || bounds.Width < 10 || bounds.Height < 10) return Rect.Empty;
        selection.Inflate(8, 8);
        bounds.Inflate(-5, -5);
        return Rect.Intersect(selection, bounds);
    }

    // Clockwise, starting at the top-left corner. Odd indices are the side handles.
    public static Point[] Handles(Rect r) =>
    [
        r.TopLeft, new((r.Left + r.Right) / 2, r.Top), r.TopRight,
        new(r.Right, (r.Top + r.Bottom) / 2), r.BottomRight,
        new((r.Left + r.Right) / 2, r.Bottom), r.BottomLeft, new(r.Left, (r.Top + r.Bottom) / 2)
    ];

    public void Update(Rect outline, bool showsHandles, string? nextStyle = null)
    {
        if (rim != outline) gradientPath = null;
        rim = outline;
        handles = showsHandles;
        if (nextStyle != null) style = nextStyle;
        Refresh();
    }

    private void Refresh()
    {
        Listen(!rim.IsEmpty && IsVisible && SystemParameters.ClientAreaAnimation && style is ("极光" or "冷白追光"));
        InvalidateVisual();
    }

    private void Listen(bool enable)
    {
        if (listening == enable) return;
        listening = enable;
        if (enable) CompositionTarget.Rendering += Animate;
        else CompositionTarget.Rendering -= Animate;
    }

    private void Animate(object? sender, EventArgs args) => InvalidateVisual();

    protected override void OnRender(DrawingContext context)
    {
        if (rim.IsEmpty || rim.Width < 1 || rim.Height < 1) return;
        var path = new RectangleGeometry(rim);
        var rounded = new RectangleGeometry(rim, 2, 2);
        void Stroke(Geometry geometry, uint color, double width, double alpha = 1, double[]? dashes = null) =>
            context.DrawGeometry(null, PenFor(color, width, alpha, dashes), geometry);
        Rect Offset(double x, double y)
        {
            var rect = rim;
            rect.Offset(x, y);
            return rect;
        }

        double elapsed = listening ? clock.Elapsed.TotalSeconds : 0;
        switch (style)
        {
            case "极光":
                Stroke(rounded, 0x855cff, 20, 0.08);
                Stroke(rounded, 0x855cff, 14, 0.12);
                Stroke(rounded, 0x0d0816, 4, 0.25);
                DrawGradient(context, Aurora, elapsed / 4.8, 2.5,
                    listening ? 0.26 + 0.08 * Math.Cos(elapsed * Math.PI / 1.8) : 0.26);
                if (listening) DrawSweeps(context, elapsed / 2.8, two: true);
                break;
            case "冷白追光":
                Stroke(rounded, 0x294257, 3);
                Stroke(rounded, 0xb2d9ef, 1);
                if (listening) DrawSweeps(context, elapsed / 4.5, two: false);
                break;
            case "像素阶梯":
                Stroke(path, 0x1e2345, 3);
                Stroke(path, 0xbfb7fb, 1.3);
                break;
            case "双色套印":
                Stroke(path, 0x203138, 4.2, 0.66);
                Stroke(new RectangleGeometry(Offset(-1.8, -1.5)), 0x56d7d9, 1.65);
                Stroke(new RectangleGeometry(Offset(1.8, 1.5)), 0xff876f, 1.65);
                break;
            case "布纹缝线":
                Stroke(path, 0xe5dfca, 8);
                Stroke(path, 0x284b5b, 6);
                Stroke(path, 0xeee0bc, 1.1, dashes: [3.5, 3]);
                break;
            case "冰蓝薄荷":
                Stroke(rounded, 0x4bcbea, 12, 0.12);
                Stroke(rounded, 0x153245, 3.5, 0.75);
                DrawGradient(context, Mint, 0, 2, 0);
                break;
            case "黑白双线":
                Stroke(path, 0x171c20, 3);
                var inset = rim;
                inset.Inflate(-0.65, -0.65);
                if (!inset.IsEmpty) Stroke(new RectangleGeometry(inset), 0xffffff, 1);
                break;
            case "四角取景":
                Stroke(path, 0x223742, 3, 0.52);
                Stroke(path, 0xdcf0f4, 1, 0.55);
                break;
            case "琥珀虚线":
                Stroke(path, 0x422d18, 3.8, 0.74);
                Stroke(path, 0xffcd81, 2, dashes: [5, 3]);
                break;
        }

        DrawHandles(context);
    }

    private void DrawGradient(DrawingContext context, uint[] colors, double phase, double width, double halo)
    {
        if (gradientPath == null)
        {
            double perimeter = 2 * (rim.Width + rim.Height);
            gradientPath = new Geometry[GradientSegments];
            for (int i = 0; i < gradientPath.Length; i++)
            {
                var segment = Segment(i * perimeter / GradientSegments, (i + 1) * perimeter / GradientSegments + .65);
                segment.Freeze();
                gradientPath[i] = segment;
            }
        }
        for (int i = 0; i < gradientPath.Length; i++)
        {
            var path = gradientPath[i];
            double progress = (i / (double)GradientSegments + phase) % 1 * colors.Length;
            int left = (int)progress;
            uint color = Blend(colors[left], colors[(left + 1) % colors.Length], progress - left);
            if (halo > 0) context.DrawGeometry(null, PenFor(color, 12, halo), path);
            context.DrawGeometry(null, PenFor(color, width), path);
        }
    }

    private void DrawSweeps(DrawingContext context, double phase, bool two)
    {
        double perimeter = 2 * (rim.Width + rim.Height);
        double spacing = two ? perimeter / 2 : perimeter;
        double length = Math.Min(two ? 80 : 76, spacing * (two ? 0.22 : 0.17));
        for (int i = 0; i < (two ? 2 : 1); i++)
        {
            double end = (phase % 1 + i) * spacing;
            var glow = Segment(end - length, end);
            var trail = Segment(end - length * .6, end);
            var head = Segment(end - length * .20, end);
            context.DrawGeometry(null, PenFor(two ? 0x1fe0ffu : 0x5cbcedu, two ? 16 : 8, .19), glow);
            context.DrawGeometry(null, PenFor(two ? 0x73f2ffu : 0x5cbcedu, two ? 5 : 2.6, .60), glow);
            context.DrawGeometry(null, PenFor(two ? 0xc4deffu : 0xb3edffu, two ? 3 : 1.8, .8), trail);
            context.DrawGeometry(null, PenFor(0xffffff, two ? 2 : 1.4), head);
        }
    }

    private Geometry Segment(double start, double end)
    {
        double perimeter = 2 * (rim.Width + rim.Height);
        double Distance(double length) => ((length % perimeter) + perimeter) % perimeter;
        Point At(double length)
        {
            double value = Distance(length);
            if (value <= rim.Width) return new(rim.Left + value, rim.Top);
            value -= rim.Width;
            if (value <= rim.Height) return new(rim.Right, rim.Top + value);
            value -= rim.Height;
            if (value <= rim.Width) return new(rim.Right - value, rim.Bottom);
            return new(rim.Left, rim.Bottom - (value - rim.Width));
        }
        var geometry = new StreamGeometry();
        using (var path = geometry.Open())
        {
            path.BeginFigure(At(start), false, false);
            double cycle = Math.Floor(start / perimeter) * perimeter;
            double[] corners = [rim.Width, rim.Width + rim.Height, 2 * rim.Width + rim.Height, perimeter];
            for (var offset = cycle; offset < end; offset += perimeter)
                foreach (double corner in corners)
                    if (offset + corner > start && offset + corner < end) path.LineTo(At(offset + corner), true, false);
            path.LineTo(At(end), true, false);
        }
        return geometry;
    }

    private void DrawHandles(DrawingContext context)
    {
        var colors = style switch
        {
            "像素阶梯" => (0xc9bbffu, 0x25294eu), "双色套印" => (0xfff0d7u, 0x334c4eu),
            "布纹缝线" => (0xecdcb7u, 0x203b48u), "冰蓝薄荷" => (0xb7e9fau, 0x255e75u),
            "黑白双线" => (0xffffffu, 0x171c20u), "四角取景" => (0xe0f8ffu, 0x102735u),
            "琥珀虚线" => (0xffe1acu, 0x6b4823u), "冷白追光" => (0xd4edf8u, 0x294257u),
            _ => (0xffffffu, 0x9454e0u)
        };
        var points = Handles(rim);
        double extent = Math.Min(rim.Width, rim.Height) * .4;
        for (int i = 0; i < points.Length; i++)
        {
            var point = points[i];
            if (i % 2 != 0 && !handles) continue;
            if (i % 2 == 0)
            {
                double xAxis = i is 0 or 6 ? 1 : -1, yAxis = i is 0 or 2 ? 1 : -1;
                Point Relative(double x, double y) => new(point.X + x * xAxis, point.Y + y * yAxis);
                if (style == "四角取景")
                {
                    double length = Math.Min(18, extent);
                    var path = Poly([Relative(0, length), point, Relative(length, 0)], false);
                    context.DrawGeometry(null, PenFor(colors.Item2, 4.6), path);
                    context.DrawGeometry(null, PenFor(i == 4 ? 0x84e9c8u : colors.Item1, 3), path);
                    continue;
                }
                if (style == "像素阶梯")
                {
                    double s = Math.Min(1, extent / 16);
                    var path = Poly([Relative(-2*s,-2*s), Relative(16*s,-2*s), Relative(16*s,2*s),
                        Relative(9*s,2*s), Relative(9*s,5*s), Relative(5*s,5*s), Relative(5*s,9*s),
                        Relative(2*s,9*s), Relative(2*s,16*s), Relative(-2*s,16*s)], true);
                    context.DrawGeometry(BrushFor(i == 0 ? 0xa9dafau : i == 4 ? 0x9ee8cbu : 0xc3b3ffu), PenFor(colors.Item2, 1.2), path);
                    continue;
                }
                if (style == "双色套印")
                {
                    context.DrawRectangle(BrushFor(0x62dbdc), null, new Rect(point.X-4,point.Y-4,5,5));
                    context.DrawRectangle(BrushFor(0xff876f), null, new Rect(point.X,point.Y,4,4));
                    continue;
                }
                if (style == "布纹缝线")
                {
                    context.DrawRectangle(BrushFor(0x284b5b), null, new Rect(point.X-3.5,point.Y-3.5,7,7));
                    var stitch = PenFor(i == 4 ? 0xffc475u : 0xf3e3bcu, 1.15);
                    context.DrawLine(stitch, Relative(-2.7,-2.7), Relative(2.7,2.7));
                    context.DrawLine(stitch, Relative(-2.7,2.7), Relative(2.7,-2.7));
                    continue;
                }
                if (!handles) continue;
            }
            double size = style == "极光" || i % 2 == 0 ? 7 : 6;
            var bounds = new Rect(point.X-size/2, point.Y-size/2, size, size);
            context.DrawRoundedRectangle(BrushFor(style == "冰蓝薄荷" && i == 4 ? 0x83f2ccu : colors.Item1),
                PenFor(colors.Item2, style == "极光" ? 1.5 : 1), bounds, 1.5, 1.5);
        }
    }

    private static Geometry Poly(Point[] points, bool closed)
    {
        var path = new StreamGeometry();
        using (var output = path.Open())
        {
            output.BeginFigure(points[0], closed, closed);
            for (int i = 1; i < points.Length; i++) output.LineTo(points[i], true, false);
        }
        return path;
    }

    internal static SolidColorBrush BrushFor(uint rgb, double opacity = 1)
    {
        var brush = new SolidColorBrush(Color.FromArgb((byte)(opacity * 255), (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        brush.Freeze();
        return brush;
    }

    private static Pen PenFor(uint rgb, double width, double opacity = 1, double[]? dashes = null)
    {
        var pen = new Pen(BrushFor(rgb, opacity), width) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        if (dashes != null) pen.DashStyle = new DashStyle(Array.ConvertAll(dashes, length => length / width), 0);
        pen.Freeze();
        return pen;
    }

    private static uint Blend(uint a, uint b, double t)
    {
        uint Channel(int shift) => (uint)Math.Round(((a >> shift) & 255) * (1 - t) + ((b >> shift) & 255) * t);
        return Channel(16) << 16 | Channel(8) << 8 | Channel(0);
    }
}

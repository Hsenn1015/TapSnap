using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TapSnap.Windows;

internal enum AnnotationTool
{
    Arrow, Rectangle, Ellipse, Line, Pen, Text, Mosaic, Highlight, Number, Polygon,
    Spotlight, Eraser, Magnifier, Watermark, PathTag, Privacy, Crop
}

internal enum StrokePattern { Solid, Dash, Dot }
internal enum ShapeFill { Outline, Fill, Both }
internal enum ArrowHead { Solid, Hollow, Open }
internal enum MaskStyle { Frosted, Erase, Mosaic, Graphite, Mist, Stripes, Solid }
internal enum NumberStyle { Arabic, Circled, Uppercase, Lowercase }

internal sealed record AnnotationStyle
{
    public Color Color { get; init; } = Color.FromRgb(255, 59, 48);
    public double LineWidth { get; init; } = 3;
    public double FontSize { get; init; } = 14;
    public double Opacity { get; init; } = 1;
    public double CornerRadius { get; init; }
    public StrokePattern Pattern { get; init; }
    public ShapeFill Fill { get; init; }
    public Color? FillColor { get; init; }
    public ArrowHead Arrow { get; init; }
    public string FontFamily { get; init; } = "Microsoft YaHei UI";
    public bool Bold { get; init; }
    public bool Italic { get; init; }
    public bool Underline { get; init; }
    public bool Strikethrough { get; init; }
    public TextAlignment Alignment { get; init; }
    public Color? TextBackground { get; init; }
    public bool RoundedBackground { get; init; } = true;
    public double Zoom { get; init; } = 2;
    public int BlockSize { get; init; } = 12;
    public MaskStyle? Mask { get; init; }
    public bool MosaicBlur { get; init; }
    public bool DetectFaces { get; init; }
    public bool DetectText { get; init; }
    public NumberStyle Number { get; init; }
    public bool NumberOutlined { get; init; }
    public double Angle { get; init; } = -20;
    public bool Tiled { get; init; }
}

internal sealed record Annotation(AnnotationTool Tool, IReadOnlyList<Point> Points, AnnotationStyle Style,
                                  string Text = "", int Number = 0)
{
    public bool IsPrivacyMask => Tool == AnnotationTool.Privacy || Tool == AnnotationTool.Mosaic && Style.Mask is not null;

    public Rect Bounds
    {
        get
        {
            if (Tool == AnnotationTool.Number)
            {
                double radius = Math.Max(10, Style.FontSize * 0.8);
                return new Rect(Points[0].X - radius, Points[0].Y - radius, radius * 2, radius * 2);
            }

            var bounds = new Rect(Points[0], Points[0]);
            foreach (Point point in Points) bounds.Union(point);
            return bounds;
        }
    }

    public Annotation Move(Vector offset) => this with { Points = Points.Select(point => point + offset).ToArray() };

    public Annotation Resize(Rect next)
    {
        Rect old = Bounds;
        return this with
        {
            Points = Points.Select(p => new Point(
                next.X + (p.X - old.X) * next.Width / Math.Max(1, old.Width),
                next.Y + (p.Y - old.Y) * next.Height / Math.Max(1, old.Height))).ToArray()
        };
    }

    public bool Hit(Point point, double tolerance)
    {
        if (Tool is AnnotationTool.Arrow or AnnotationTool.Line or AnnotationTool.Pen or AnnotationTool.Highlight or AnnotationTool.PathTag)
            return Points.Zip(Points.Skip(1), (a, b) => Distance(point, a, b))
                .Any(distance => distance <= tolerance + Style.LineWidth / 2);
        Rect bounds = Bounds;
        bounds.Inflate(tolerance, tolerance);
        return bounds.Contains(point);
    }

    private static double Distance(Point point, Point start, Point end)
    {
        Vector direction = end - start;
        double at = direction.LengthSquared == 0 ? 0 :
            Math.Clamp(Vector.Multiply(point - start, direction) / direction.LengthSquared, 0, 1);
        return (point - (start + direction * at)).Length;
    }
}

internal static class AnnotationDrawing
{
    public static void Draw(DrawingContext context, Annotation item, BitmapSource source, Rect imageBounds)
    {
        AnnotationStyle style = item.Style;
        Rect bounds = item.Bounds;
        var ink = Brush(style.Color);
        var pen = new Pen(ink, style.LineWidth)
        {
            StartLineCap = PenLineCap.Round,
            EndLineCap = PenLineCap.Round,
            LineJoin = PenLineJoin.Round,
            DashStyle = style.Pattern switch
            {
                StrokePattern.Dash => DashStyles.Dash,
                StrokePattern.Dot => DashStyles.Dot,
                _ => DashStyles.Solid
            }
        };
        Brush? fill = style.Fill switch
        {
            ShapeFill.Fill => style.FillColor is Color filled ? Brush(filled) : ink,
            ShapeFill.Both => style.FillColor is Color shaded ? Brush(shaded) : Brush(style.Color, 0.25),
            _ => null
        };
        Pen? outline = style.Fill == ShapeFill.Fill ? null : pen;
        context.PushOpacity(style.Opacity);
        switch (item.Tool)
        {
            case AnnotationTool.Arrow:
                DrawArrow(context, item, pen);
                break;
            case AnnotationTool.PathTag:
                DrawArrow(context, item, pen);
                break;
            case AnnotationTool.Line:
                context.DrawLine(pen, item.Points[0], item.Points[^1]);
                break;
            case AnnotationTool.Rectangle:
                context.DrawRoundedRectangle(fill, outline, bounds, style.CornerRadius, style.CornerRadius);
                break;
            case AnnotationTool.Ellipse:
                context.DrawEllipse(fill, outline, Center(bounds), bounds.Width / 2, bounds.Height / 2);
                break;
            case AnnotationTool.Pen:
                context.DrawGeometry(null, pen, Polygon(item.Points, false));
                break;
            case AnnotationTool.Highlight:
                context.DrawGeometry(null, new Pen(Brush(style.Color, 0.4), Math.Max(8, style.LineWidth * 4))
                { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round },
                    Polygon(item.Points, false));
                break;
            case AnnotationTool.Polygon:
                context.DrawGeometry(fill, outline, Polygon(item.Points, true));
                break;
            case AnnotationTool.Text:
                DrawText(context, item, ink);
                break;
            case AnnotationTool.Number:
                DrawNumber(context, item, ink);
                break;
            case AnnotationTool.Watermark:
                DrawWatermark(context, item, ink);
                break;
            case AnnotationTool.Mosaic:
                DrawMosaic(context, item, source, imageBounds);
                break;
            case AnnotationTool.Magnifier:
                DrawMagnifier(context, item, source, imageBounds, pen);
                break;
            case AnnotationTool.Spotlight:
                context.DrawGeometry(Brush(Colors.Black, 0.55), null, new CombinedGeometry(GeometryCombineMode.Exclude,
                    new RectangleGeometry(imageBounds), new EllipseGeometry(bounds)));
                break;
        }
        context.Pop();
    }

    public static Point Center(Rect bounds) => new(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2);
    public static SolidColorBrush Brush(Color color, double opacity = 1)
    {
        var brush = new SolidColorBrush(color) { Opacity = opacity };
        brush.Freeze();
        return brush;
    }

    private static StreamGeometry Polygon(IReadOnlyList<Point> points, bool close)
    {
        var geometry = new StreamGeometry();
        using (StreamGeometryContext context = geometry.Open())
        {
            context.BeginFigure(points[0], close, close);
            context.PolyLineTo(points.Skip(1).ToArray(), true, false);
        }
        geometry.Freeze();
        return geometry;
    }

    private static void DrawArrow(DrawingContext context, Annotation item, Pen pen)
    {
        Point start = item.Points[^2], tip = item.Points[^1];
        Vector forward = tip - start;
        if (forward.Length < 0.5) return;
        double length = Math.Min(forward.Length, Math.Max(9, pen.Thickness * 4));
        forward.Normalize();
        Vector across = new(-forward.Y, forward.X);
        Point left = tip - forward * length + across * (length * 0.46);
        Point right = tip - forward * length - across * (length * 0.46);
        Point tail = item.Style.Arrow == ArrowHead.Open ? tip : tip - forward * (length * 0.9);
        context.DrawGeometry(null, pen, Polygon(item.Points.Take(item.Points.Count - 1).Append(tail).ToArray(), false));
        if (item.Style.Arrow == ArrowHead.Open)
        {
            context.DrawLine(pen, left, tip);
            context.DrawLine(pen, tip, right);
        }
        else
        {
            Geometry head = Polygon(new[] { left, tip, right }, true);
            if (item.Style.Arrow == ArrowHead.Hollow)
                context.DrawGeometry(null, new Pen(pen.Brush, Math.Max(1, pen.Thickness / 1.5)), head);
            else context.DrawGeometry(pen.Brush, null, head);
        }
    }

    private static FormattedText Text(Annotation item, string value, Brush ink)
    {
        AnnotationStyle style = item.Style;
        var type = new Typeface(new FontFamily(style.FontFamily), style.Italic ? FontStyles.Italic : FontStyles.Normal,
            style.Bold ? FontWeights.Bold : FontWeights.Normal, FontStretches.Normal);
        var formatted = new FormattedText(value, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            type, style.FontSize, ink, 1);
        formatted.TextAlignment = style.Alignment;
        if (style.Underline || style.Strikethrough)
        {
            var decorations = new TextDecorationCollection();
            if (style.Underline) decorations.Add(TextDecorations.Underline);
            if (style.Strikethrough) decorations.Add(TextDecorations.Strikethrough);
            formatted.SetTextDecorations(decorations);
        }
        return formatted;
    }

    private static void DrawText(DrawingContext context, Annotation item, Brush ink)
    {
        Rect bounds = item.Bounds;
        Brush? background = item.Style.TextBackground is Color color ? Brush(color) : null;
        if (background is not null)
        {
            if (item.Style.RoundedBackground) context.DrawRoundedRectangle(background, null, bounds, 6, 6);
            else context.DrawRectangle(background, null, bounds);
        }
        FormattedText text = Text(item, item.Text, ink);
        text.MaxTextWidth = Math.Max(1, bounds.Width - 8);
        text.MaxTextHeight = Math.Max(item.Style.FontSize * 1.2, bounds.Height - 4);
        context.PushClip(new RectangleGeometry(bounds));
        context.DrawText(text, new Point(bounds.X + 4, bounds.Y + 2));
        context.Pop();
    }

    private static void DrawNumber(DrawingContext context, Annotation item, Brush ink)
    {
        Rect bounds = item.Bounds;
        Point center = Center(bounds);
        double radius = bounds.Width / 2;
        bool outlined = item.Style.NumberOutlined;
        context.DrawEllipse(outlined ? Brushes.White : ink, outlined ? new Pen(ink, 2) : null, center, radius, radius);
        string label = item.Style.Number switch
        {
            NumberStyle.Uppercase => Letters(item.Number),
            NumberStyle.Lowercase => Letters(item.Number).ToLowerInvariant(),
            NumberStyle.Circled when item.Number is >= 1 and <= 20 => char.ConvertFromUtf32(0x245F + item.Number),
            NumberStyle.Circled => $"({item.Number})",
            _ => item.Number.ToString(CultureInfo.InvariantCulture)
        };
        FormattedText text = Text(item, label, outlined ? ink : Brushes.White);
        if (text.Width > radius * 1.75) text.SetFontSize(item.Style.FontSize * radius * 1.75 / text.Width);
        context.DrawText(text, new Point(center.X - text.Width / 2, center.Y - text.Height / 2));
    }

    private static string Letters(int number)
    {
        string result = "";
        while (number > 0)
        {
            --number;
            result = (char)('A' + number % 26) + result;
            number /= 26;
        }
        return result;
    }

    private static void DrawWatermark(DrawingContext context, Annotation item, Brush ink)
    {
        Rect bounds = item.Bounds;
        FormattedText text = Text(item, item.Text, ink);
        Point center = Center(bounds);
        context.PushClip(new RectangleGeometry(bounds));
        context.PushTransform(new RotateTransform(item.Style.Angle, center.X, center.Y));
        if (item.Style.Tiled)
        {
            double length = Math.Sqrt(bounds.Width * bounds.Width + bounds.Height * bounds.Height);
            for (double y = center.Y - length / 2; y < center.Y + length / 2; y += text.Height + 18)
            for (double x = center.X - length / 2; x < center.X + length / 2; x += text.Width + 30)
                context.DrawText(text, new Point(x, y));
        }
        else context.DrawText(text, new Point(center.X - text.Width / 2, center.Y - text.Height / 2));
        context.Pop();
        context.Pop();
    }

    private static void DrawMagnifier(DrawingContext context, Annotation item, BitmapSource source, Rect imageBounds, Pen pen)
    {
        Rect bounds = item.Bounds;
        if (bounds.Width < 1 || bounds.Height < 1) return;
        Point center = Center(bounds);
        context.PushClip(new EllipseGeometry(bounds));
        context.DrawRectangle(Brushes.White, null, bounds);
        context.PushTransform(new ScaleTransform(item.Style.Zoom, item.Style.Zoom, center.X, center.Y));
        context.DrawImage(source, imageBounds);
        context.Pop();
        context.Pop();
        context.DrawEllipse(null, pen, center, bounds.Width / 2, bounds.Height / 2);
    }

    private static void DrawMosaic(DrawingContext context, Annotation item, BitmapSource source, Rect imageBounds)
    {
        Rect rect = Rect.Intersect(item.Bounds, imageBounds);
        if (rect.IsEmpty) return;
        int left = (int)Math.Floor(rect.Left), top = (int)Math.Floor(rect.Top);
        int width = (int)Math.Ceiling(rect.Right) - left, height = (int)Math.Ceiling(rect.Bottom) - top;
        if (width <= 0 || height <= 0) return;
        int cols = Math.Max(1, (int)Math.Ceiling((double)width / item.Style.BlockSize));
        int rows = Math.Max(1, (int)Math.Ceiling((double)height / item.Style.BlockSize));
        var crop = new CroppedBitmap(source, new Int32Rect(left, top, width, height));
        var tiny = new TransformedBitmap(crop, new ScaleTransform((double)cols / width, (double)rows / height));
        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, item.Style.MosaicBlur ? BitmapScalingMode.HighQuality : BitmapScalingMode.NearestNeighbor);
        using (var draw = visual.RenderOpen()) draw.DrawImage(tiny, new Rect(0, 0, width, height));
        var output = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        output.Render(visual);
        context.DrawImage(output, new Rect(left, top, width, height));
    }
}

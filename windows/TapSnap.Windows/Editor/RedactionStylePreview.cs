using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TapSnap.Windows;

internal static class RedactionStylePreview
{
    public const int Width = 98;
    public const int Height = 56;
    private static readonly Rect Bounds = new(0, 0, Width, Height);
    private static readonly Rect Demo = new(13, 33, 72, 15);
    private static BitmapSource? sample;

    public static BitmapSource Render(AnnotationStyle style)
    {
        BitmapSource source = sample ??= BuildSample();
        var visual = new DrawingVisual();
        var annotation = new Annotation(AnnotationTool.Mosaic, [Demo.TopLeft, Demo.BottomRight], style);
        using (var context = visual.RenderOpen())
        {
            context.DrawImage(source, Bounds);
            if (annotation.IsPrivacyMask)
            {
                var masks = new PrivacyMaskDrawing(source);
                masks.UpdateMasks([Demo]);
                masks.Draw(context, annotation);
            }
            else AnnotationDrawing.Draw(context, annotation, source, Bounds);
        }
        return Image(visual);
    }

    private static BitmapSource BuildSample()
    {
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            Brush Ink(byte r, byte g, byte b) => AnnotationDrawing.Brush(Color.FromRgb(r, g, b));
            context.DrawRectangle(Ink(240, 242, 247), null, Bounds);
            context.DrawRectangle(Ink(181, 194, 214), null, new Rect(Width / 2d, 0, Width / 2d, Height));
            context.DrawRectangle(Ink(219, 226, 237), null, new Rect(6, 27.5, Width - 12, 0.5));
            var line = new FormattedText("DEMO 4281", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface(new FontFamily("Consolas"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                9, Ink(36, 56, 89), 1);
            foreach (int center in new[] { 15, 41 })
            {
                context.DrawEllipse(Ink(48, 115, 212), null, new Point(18.5, center), 2.5, 2.5);
                context.DrawEllipse(Ink(214, 107, 56), null, new Point(79.5, center), 2.5, 2.5);
                context.DrawText(line, new Point(25, center - line.Height / 2));
            }
        }
        return Image(visual);
    }

    private static BitmapSource Image(DrawingVisual visual)
    {
        var bitmap = new RenderTargetBitmap(Width, Height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }
}

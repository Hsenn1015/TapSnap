using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TapSnap.Windows;

internal sealed class PrivacyMaskDrawing(BitmapSource source)
{
    private const double Feather = 5;
    private readonly Dictionary<(Rect, MaskStyle, int, Color), Brush> patches = new();
    private Rect[] previousMasks = Array.Empty<Rect>();
    private BitmapSource? coveredImage;

    public BitmapSource SourceForEffects(IReadOnlyList<Rect> masks)
    {
        UpdateMasks(masks);
        if (masks.Count == 0) return source;
        if (coveredImage is not null) return coveredImage;

        var visual = new DrawingVisual();
        using (DrawingContext context = visual.RenderOpen())
        {
            context.DrawImage(source, new Rect(0, 0, source.PixelWidth, source.PixelHeight));
            foreach (Rect mask in masks) context.DrawRectangle(Brushes.Black, null, mask);
        }
        var bitmap = new RenderTargetBitmap(source.PixelWidth, source.PixelHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return coveredImage = bitmap;
    }

    public void UpdateMasks(IReadOnlyList<Rect> masks)
    {
        if (previousMasks.SequenceEqual(masks)) return;
        previousMasks = masks.ToArray();
        coveredImage = null;
        patches.Clear();
    }

    public Rect IntegralBounds(Rect rect)
    {
        var pixelBounds = new Rect(Math.Floor(rect.Left), Math.Floor(rect.Top),
            Math.Ceiling(rect.Right) - Math.Floor(rect.Left), Math.Ceiling(rect.Bottom) - Math.Floor(rect.Top));
        return Rect.Intersect(pixelBounds, new Rect(0, 0, source.PixelWidth, source.PixelHeight));
    }

    public void Draw(DrawingContext context, Annotation mask)
    {
        Rect bounds = IntegralBounds(mask.Bounds);
        if (bounds.IsEmpty || bounds.Width == 0 || bounds.Height == 0) return;
        Brush ink = GetPatch(bounds, mask.Style.Mask ?? MaskStyle.Frosted, mask.Style.BlockSize, mask.Style.Color);
        double previousOpacity = 0;
        for (int i = 8; i >= 1; i--)
        {
            double progress = i / 9d;
            double expansion = Feather * progress;
            double opacity = 1 - progress * progress * (3 - 2 * progress);
            Rect outline = bounds;
            outline.Inflate(expansion, expansion);
            double radius = Math.Min(Math.Min(expansion * 1.8, Feather), Math.Min(outline.Width, outline.Height) / 2);
            // Composite just the extra opacity needed to match the Mac feather curve.
            context.PushOpacity((opacity - previousOpacity) / (1 - previousOpacity));
            context.DrawRoundedRectangle(ink, null, outline, radius, radius);
            context.Pop();
            previousOpacity = opacity;
        }
        context.PushGuidelineSet(new GuidelineSet([bounds.Left, bounds.Right], [bounds.Top, bounds.Bottom]));
        context.DrawRectangle(ink, null, bounds);
        context.Pop();
    }

    private Brush GetPatch(Rect bounds, MaskStyle style, int blockSize, Color customColor)
    {
        if (style == MaskStyle.Graphite) return AnnotationDrawing.Brush(Color.FromRgb(33, 37, 46));
        if (style == MaskStyle.Solid) return AnnotationDrawing.Brush(Color.FromRgb(customColor.R, customColor.G, customColor.B));
        var key = (bounds, style, blockSize, customColor);
        if (patches.TryGetValue(key, out Brush? existing)) return existing;

        Rect effect = bounds;
        effect.Inflate(Feather, Feather);
        int patternSize = Math.Clamp(blockSize, 3, 24);
        int step = style == MaskStyle.Mosaic ? patternSize : 2;
        int width = Math.Clamp((int)Math.Ceiling(effect.Width / step), 1, 192);
        int height = Math.Clamp((int)Math.Ceiling(effect.Height / step), 1, 192);
        byte[] pixels = new byte[width * height * 4];
        double depth = Math.Ceiling(Math.Min(8, Math.Max(2, bounds.Height * 0.28)));
        Rect above = new(effect.X, bounds.Y - depth, effect.Width, depth);
        Rect below = new(effect.X, bounds.Bottom, effect.Width, depth);
        Rect left = new(bounds.X - depth, effect.Y, depth, effect.Height);
        Rect right = new(bounds.Right, effect.Y, depth, effect.Height);
        Color[]? top = Sample(above, width, true);
        Color[]? bottom = Sample(below, width, true);
        Color[]? leading = Sample(left, height, false);
        Color[]? trailing = Sample(right, height, false);
        double across = bounds.Height / (bounds.Width + bounds.Height);

        for (int y = 0; y < height; y++)
        {
            double py = (y + 0.5) * effect.Height / height;
            double v = Math.Clamp((py - Feather) / bounds.Height, 0, 1);
            double center = Math.Exp(-Math.Pow((v - 0.5) / 0.29, 2));
            for (int x = 0; x < width; x++)
            {
                double px = (x + 0.5) * effect.Width / width;
                double u = Math.Clamp((px - Feather) / bounds.Width, 0, 1);
                Color? vertical = Mix(top?[x], bottom?[x], v);
                Color? horizontal = Mix(leading?[y], trailing?[y], u);
                Color basis = Mix(vertical, horizontal, across) ?? Color.FromRgb(208, 212, 218);
                double luminance = 0.21 * basis.R + 0.72 * basis.G + 0.07 * basis.B;
                double edge = Math.Min(1, Math.Min(u, 1 - u) / 0.24);
                double contrast = (128 - luminance) * center * edge;
                double amount = style switch
                {
                    MaskStyle.Frosted => contrast * 0.28,
                    MaskStyle.Mosaic => (((x * 41 + y * 17 + x * y * 7) % 19 - 9) * 1.4 + contrast * 0.12) * center,
                    MaskStyle.Mist => (255 - luminance) * center * edge * 0.09,
                    MaskStyle.Stripes => (((px + py) / (patternSize * 2)) % 1 < 0.38 ? 11 : -4) * center,
                    _ => 0
                };
                int pixel = (y * width + x) * 4;
                pixels[pixel] = Channel(basis.B + amount);
                pixels[pixel + 1] = Channel(basis.G + amount);
                pixels[pixel + 2] = Channel(basis.R + amount);
                pixels[pixel + 3] = byte.MaxValue;
            }
        }

        var patch = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
        patch.Freeze();
        var brush = new ImageBrush(patch) { Stretch = Stretch.Fill, ViewportUnits = BrushMappingMode.Absolute, Viewport = effect };
        RenderOptions.SetBitmapScalingMode(brush, style == MaskStyle.Mosaic ? BitmapScalingMode.NearestNeighbor : BitmapScalingMode.HighQuality);
        brush.Freeze();
        patches.Add(key, brush);
        return brush;
    }

    // Sampling strips never include any protected pixels, including adjacent masks.
    private Color[]? Sample(Rect strip, int count, bool horizontal)
    {
        Rect clipped = IntegralBounds(strip);
        if (clipped.IsEmpty || clipped.Width == 0 || clipped.Height == 0 ||
            previousMasks.Any(mask =>
            {
                Rect overlap = Rect.Intersect(mask, clipped);
                return !overlap.IsEmpty && overlap.Width > 0 && overlap.Height > 0;
            })) return null;

        var crop = new CroppedBitmap(source, new Int32Rect((int)clipped.Left, (int)clipped.Top, (int)clipped.Width, (int)clipped.Height));
        int width = horizontal ? count : 1, height = horizontal ? 1 : count;
        var pixels = new byte[count * 4];
        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
        using (DrawingContext context = visual.RenderOpen()) context.DrawImage(crop, new Rect(0, 0, width, height));
        var sample = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        sample.Render(visual);
        sample.CopyPixels(pixels, width * 4, 0);
        return Enumerable.Range(0, count).Select(i => Color.FromRgb(pixels[i * 4 + 2], pixels[i * 4 + 1], pixels[i * 4])).ToArray();
    }

    private static byte Channel(double value) => (byte)Math.Clamp(Math.Round(value), 0, 255);

    private static Color? Mix(Color? first, Color? second, double amount)
    {
        if (first is not Color a || second is not Color b) return first ?? second;
        return Color.FromRgb(Channel(a.R + (b.R - a.R) * amount), Channel(a.G + (b.G - a.G) * amount), Channel(a.B + (b.B - a.B) * amount));
    }
}

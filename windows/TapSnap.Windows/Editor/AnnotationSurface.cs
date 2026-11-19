using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TapSnap.Windows;

internal sealed class AnnotationSurface : FrameworkElement
{
    private readonly BitmapSource image;
    private readonly PrivacyMaskDrawing privacyMasks;
    private readonly Rect imageRect;
    private readonly Brush backdrop;
    internal const double Padding = 6;
    internal IReadOnlyList<Annotation> Items { get; set; } = Array.Empty<Annotation>();
    internal IReadOnlyList<PendingRedaction> Candidates { get; set; } = Array.Empty<PendingRedaction>();
    internal Annotation? Draft { get; set; }
    internal int Selected { get; set; } = -1;
    internal int Editing { get; set; } = -1;
    internal Rect? Crop { get; set; }
    internal Rect? DraftCrop { get; set; }
    internal bool IsCropping { get; set; }
    internal Guid? SelectedCandidate { get; set; }
    internal double? ZoomScale { get; private set; }
    internal double Scale { get; private set; } = 1;
    internal Point Origin { get; private set; }
    internal Rect ImageRect => imageRect;

    public AnnotationSurface(BitmapSource image, Brush backdrop)
    {
        this.image = image;
        this.backdrop = backdrop;
        privacyMasks = new PrivacyMaskDrawing(image);
        imageRect = new Rect(0, 0, image.PixelWidth, image.PixelHeight);
        Focusable = true;
        ClipToBounds = true;
    }

    internal Point ToImage(Point point)
    {
        return new Point((point.X - Origin.X) / Scale, (point.Y - Origin.Y) / Scale);
    }

    internal Point ToWindow(Point point)
    {
        return new Point(Origin.X + point.X * Scale, Origin.Y + point.Y * Scale);
    }

    protected override Size ArrangeOverride(Size size)
    {
        double scale = ZoomScale ?? FitScale(size);
        var origin = new Point((size.Width - imageRect.Width * scale) / 2, (size.Height - imageRect.Height * scale) / 2);
        if (scale != Scale || origin != Origin) InvalidateVisual();
        Scale = scale;
        Origin = origin;
        return size;
    }

    internal double FitScale(Size size) => Math.Max(0.001, Math.Min((size.Width - 2 * Padding) / imageRect.Width,
                                                                   (size.Height - 2 * Padding) / imageRect.Height));

    internal void SetZoom(double? scale)
    {
        ZoomScale = scale;
        InvalidateArrange();
    }

    protected override void OnRender(DrawingContext context)
    {
        context.DrawRectangle(backdrop, null, new Rect(new Point(), RenderSize));
        context.PushTransform(new TranslateTransform(Origin.X, Origin.Y));
        context.PushTransform(new ScaleTransform(Scale, Scale));
        context.PushClip(new RectangleGeometry(imageRect));
        DrawDocument(context, preview: true);
        if ((DraftCrop ?? Crop) is Rect crop && crop.Width > 0 && crop.Height > 0)
        {
            if (IsCropping)
            {
                var remainder = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(imageRect), new RectangleGeometry(crop));
                context.DrawGeometry(AnnotationDrawing.Brush(Colors.Black, 0.45), null, remainder);
                DrawHandles(context, crop);
            }
            else
            {
                var outline = new Pen(AnnotationDrawing.Brush(Color.FromRgb(60, 146, 255), 0.8), 1 / Scale) { DashStyle = DashStyles.Dash };
                context.DrawRectangle(null, outline, crop);
            }
        }

        if (Selected >= 0 && Selected != Editing && Selected < Items.Count && Items[Selected].Tool != AnnotationTool.Number)
            DrawHandles(context, SelectionBounds(Items[Selected]));
        foreach (PendingRedaction candidate in Candidates)
        {
            bool selected = candidate.Id == SelectedCandidate;
            var pen = new Pen(Brushes.DarkOrange, (selected ? 2 : 1) / Scale) { DashStyle = DashStyles.Dash };
            context.DrawRectangle(AnnotationDrawing.Brush(Colors.Orange, 0.08), pen, candidate.Bounds);
        }

        context.Pop();
        context.Pop();
        context.Pop();
    }

    internal BitmapSource Render(bool crop)
    {
        var width = image.PixelWidth;
        var height = image.PixelHeight;
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen()) DrawDocument(context, preview: false);
        var result = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        result.Render(visual);
        result.Freeze();
        if (!crop || Crop is not Rect requested) return result;
        Rect selection = privacyMasks.IntegralBounds(requested);
        if (selection.IsEmpty || selection.Width == 0 || selection.Height == 0) return result;
        var cropped = new CroppedBitmap(result, new Int32Rect(
            (int)selection.X, (int)selection.Y, (int)selection.Width, (int)selection.Height));
        cropped.Freeze();
        return cropped;
    }

    private void DrawDocument(DrawingContext context, bool preview)
    {
        var visible = Items.Where((_, index) => !preview || index != Editing);
        if (preview && Draft is Annotation draft) visible = visible.Append(draft);
        Annotation[] annotations = visible.ToArray();
        Annotation[] masks = annotations.Where(item => item.IsPrivacyMask).ToArray();
        Rect[] bounds = masks.Select(mask => privacyMasks.IntegralBounds(mask.Bounds))
            .Where(rect => !rect.IsEmpty && rect.Width > 0 && rect.Height > 0).ToArray();
        BitmapSource effectSource = annotations.Any(item => item.Tool is AnnotationTool.Mosaic or AnnotationTool.Magnifier)
            ? privacyMasks.SourceForEffects(bounds)
            : image;
        if (ReferenceEquals(effectSource, image)) privacyMasks.UpdateMasks(bounds);
        context.DrawImage(image, imageRect);
        foreach (Annotation item in annotations.Where(item => !item.IsPrivacyMask))
            AnnotationDrawing.Draw(context, item, effectSource, imageRect);
        foreach (Annotation mask in masks) privacyMasks.Draw(context, mask);
    }

    internal Rect SelectionBounds(Annotation item)
    {
        Rect bounds = item.Bounds;
        if (bounds.Width < 1 || bounds.Height < 1) bounds.Inflate(1 / Scale, 1 / Scale);
        return bounds;
    }

    internal AnnotationHandle? HitHandle(Annotation item, Point point) => HitHandle(SelectionBounds(item), point);

    internal AnnotationHandle? HitHandle(Rect bounds, Point point)
    {
        double tolerance = 7 / Scale;
        return Handles.Select(handle => (Handle: handle, Distance: (handle.Position(bounds) - point).Length))
            .Where(item => item.Distance <= tolerance).OrderBy(item => item.Distance)
            .Select(item => (AnnotationHandle?)item.Handle).FirstOrDefault();
    }

    private void DrawHandles(DrawingContext context, Rect bounds)
    {
        if (bounds.IsEmpty) return;
        var ink = AnnotationDrawing.Brush(Color.FromRgb(60, 146, 255));
        var pen = new Pen(ink, 1 / Scale) { DashStyle = DashStyles.Dash };
        context.DrawRectangle(null, pen, bounds);
        var handlePen = new Pen(ink, 1 / Scale);
        double radius = 3 / Scale;
        foreach (AnnotationHandle handle in Handles)
        {
            Point point = handle.Position(bounds);
            context.DrawRoundedRectangle(Brushes.White, handlePen,
                new Rect(point.X - radius, point.Y - radius, radius * 2, radius * 2), 1, 1);
        }
    }

    private static readonly AnnotationHandle[] Handles =
    [
        new(-1, -1), new(0, -1), new(1, -1), new(-1, 0), new(1, 0),
        new(-1, 1), new(0, 1), new(1, 1)
    ];
}

internal readonly record struct AnnotationHandle(int X, int Y)
{
    public Point Position(Rect bounds) => new(bounds.Left + (X + 1) * bounds.Width / 2,
        bounds.Top + (Y + 1) * bounds.Height / 2);

    public Cursor RotationFreeCursor => (X, Y) switch
    {
        (0, _) => Cursors.SizeNS, (_, 0) => Cursors.SizeWE,
        _ when X == Y => Cursors.SizeNWSE, _ => Cursors.SizeNESW
    };

    public Rect Resize(Rect bounds, Vector delta)
    {
        double left = X < 0 ? Math.Min(bounds.Left + delta.X, bounds.Right - 1) : bounds.Left;
        double right = X > 0 ? Math.Max(bounds.Right + delta.X, left + 1) : bounds.Right;
        double top = Y < 0 ? Math.Min(bounds.Top + delta.Y, bounds.Bottom - 1) : bounds.Top;
        double bottom = Y > 0 ? Math.Max(bounds.Bottom + delta.Y, top + 1) : bounds.Bottom;
        return new Rect(new Point(left, top), new Point(right, bottom));
    }
}

internal sealed record PendingRedaction(Guid Id, string Label, Rect Bounds);

using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TapSnap.Windows;

// Shape coordinates and time ranges always refer to the original recording.
internal sealed record RecordingMark(Annotation Shape, double Start, double End)
{
    public bool Active(double time) => Start <= time && time < End;

    public Drawing Drawing(BitmapSource reference)
    {
        var result = new DrawingGroup();
        using (var dc = result.Open())
        {
            if (Shape.Tool == AnnotationTool.Privacy)
            {
                var color = Shape.Style.Color;
                dc.DrawRectangle(AnnotationDrawing.Brush(Color.FromRgb(color.R, color.G, color.B)), null, Shape.Bounds);
            }
            else AnnotationDrawing.Draw(dc, Shape, reference, new Rect(0, 0, reference.PixelWidth, reference.PixelHeight));
        }
        result.Freeze();
        return result;
    }
}

// Rasterize only the mark's bounds once per export. Encoding threads then composite
// immutable premultiplied BGRA into their own frame buffers, independently of WPF.
internal sealed record RecordingOverlay(RecordingMark Mark, Int32Rect Area, byte[]? Ink)
{
    public static RecordingOverlay[] Prepare(RecordingMark[] marks, BitmapSource reference, double from, double to,
        int width, int height, bool resize)
    {
        double sx = resize ? (double)width / reference.PixelWidth : 1, sy = resize ? (double)height / reference.PixelHeight : 1;
        var result = new List<RecordingOverlay>();
        foreach (var mark in marks.Where(m => m.Start < to && m.End > from))
        {
            var drawing = mark.Drawing(reference);
            var bounds = drawing.Bounds;
            if (bounds.IsEmpty) continue;
            int x = Math.Clamp((int)Math.Floor(bounds.Left * sx), 0, width), y = Math.Clamp((int)Math.Floor(bounds.Top * sy), 0, height);
            int right = Math.Clamp((int)Math.Ceiling(bounds.Right * sx), 0, width), bottom = Math.Clamp((int)Math.Ceiling(bounds.Bottom * sy), 0, height);
            if (right <= x || bottom <= y) continue;
            var area = new Int32Rect(x, y, right - x, bottom - y);
            byte[]? pixels = null;
            if (mark.Shape.Tool != AnnotationTool.Privacy)
            {
                var visual = new DrawingVisual();
                using (var dc = visual.RenderOpen())
                {
                    dc.PushTransform(new MatrixTransform(sx, 0, 0, sy, -x, -y));
                    dc.DrawDrawing(drawing);
                    dc.Pop();
                }
                var raster = new RenderTargetBitmap(area.Width, area.Height, 96, 96, PixelFormats.Pbgra32);
                raster.Render(visual);
                pixels = new byte[checked(area.Width * area.Height * 4)];
                raster.CopyPixels(pixels, area.Width * 4, 0);
            }
            result.Add(new(mark, area, pixels));
        }
        return result.ToArray();
    }

    public void Paint(byte[] frame, int stride)
    {
        int src = 0;
        for (int y = 0; y < Area.Height; y++)
        {
            int dest = (Area.Y + y) * stride + Area.X * 4;
            if (Ink == null)
            {
                var color = Mark.Shape.Style.Color;
                uint solid = 0xff000000u | (uint)color.R << 16 | (uint)color.G << 8 | color.B;
                MemoryMarshal.Cast<byte, uint>(frame.AsSpan(dest, Area.Width * 4)).Fill(solid);
                continue;
            }
            for (int x = 0; x < Area.Width; x++, src += 4, dest += 4)
            {
                int alpha = Ink[src + 3];
                if (alpha == 0) continue;
                for (int c = 0; c < 3; c++)
                    frame[dest + c] = (byte)(Ink[src + c] + (frame[dest + c] * (255 - alpha) + 127) / 255);
                frame[dest + 3] = 255;
            }
        }
    }

    public static IEnumerable<(double Time, ushort Delay)> GifSamples(double from, double to, int fps, RecordingOverlay[] overlays)
    {
        // Include mark boundaries between regular samples (e.g. a single 60 fps
        // frame at 10 fps GIF output). Coalesce times that share one GIF clock tick.
        var edges = overlays.SelectMany(o => new[] { o.Mark.Start, o.Mark.End })
            .Where(t => t > from && t < to).Distinct().Order().ToArray();
        int edge = 0, index = 1, previousTick = 0;
        int total = Math.Max(1, (int)Math.Round((to - from) * 100));
        double previous = from;
        while (true)
        {
            double next = from + (double)index / fps;
            if (edge < edges.Length && edges[edge] <= next) next = edges[edge++];
            else index++;
            if (next >= to) break;
            int tick = (int)Math.Round((next - from) * 100);
            if (tick >= total) break;
            if (tick > previousTick) yield return (previous, (ushort)(tick - previousTick));
            previous = next;
            previousTick = tick;
        }
        yield return (previous, (ushort)(total - previousTick));
    }
}

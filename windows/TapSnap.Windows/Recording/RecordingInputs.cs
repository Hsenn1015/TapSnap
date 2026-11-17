using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using global::Windows.Graphics.Imaging;
using global::Windows.Media.Capture;
using global::Windows.Media.Capture.Frames;
using global::Windows.Media.MediaProperties;
using global::Windows.Security.Cryptography;
using CaptureBuffer = global::Windows.Storage.Streams.Buffer;

namespace TapSnap.Windows;

internal sealed class RecordingCamera : IAsyncDisposable
{
    private readonly MediaCapture camera = new();
    private MediaFrameReader? reader;
    private BitmapSource? latest;
    public BitmapSource? Latest => Volatile.Read(ref latest);

    public async Task StartAsync()
    {
        foreach (var group in await MediaFrameSourceGroup.FindAllAsync())
        {
            foreach (var info in group.SourceInfos)
            {
                if (info.SourceKind != MediaFrameSourceKind.Color) continue;
                await camera.InitializeAsync(new MediaCaptureInitializationSettings
                {
                    SourceGroup = group, SharingMode = MediaCaptureSharingMode.SharedReadOnly,
                    StreamingCaptureMode = StreamingCaptureMode.Video, MemoryPreference = MediaCaptureMemoryPreference.Cpu
                });
                reader = await camera.CreateFrameReaderAsync(camera.FrameSources[info.Id], MediaEncodingSubtypes.Bgra8);
                reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
                reader.FrameArrived += OnFrame;
                if (await reader.StartAsync() != MediaFrameReaderStartStatus.Success)
                    throw new InvalidOperationException("无法启动摄像头。");
                return;
            }
        }
        throw new InvalidOperationException("找不到可用摄像头。");
    }

    private void OnFrame(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        try
        {
            using var frame = sender.TryAcquireLatestFrame();
            using var cameraBitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (cameraBitmap == null) return;
            using var bitmap = SoftwareBitmap.Convert(cameraBitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
            int stride = checked(bitmap.PixelWidth * 4);
            uint size = checked((uint)(stride * bitmap.PixelHeight));
            var buffer = new CaptureBuffer(size) { Length = size };
            bitmap.CopyToBuffer(buffer);
            CryptographicBuffer.CopyToByteArray(buffer, out var pixels);
            var output = BitmapSource.Create(bitmap.PixelWidth, bitmap.PixelHeight, 96, 96, PixelFormats.Bgr32, null, pixels, stride);
            output.Freeze();
            Volatile.Write(ref latest, output);
        }
        catch (ObjectDisposedException) { }
        catch (COMException) { }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (reader != null)
            {
                reader.FrameArrived -= OnFrame;
                try { await reader.StopAsync(); }
                catch (COMException) { }
                finally { reader.Dispose(); }
            }
        }
        finally { camera.Dispose(); }
    }
}

internal sealed class RecordingInputOverlay(bool cursor, bool keys, bool clicks)
{
    private string? keyCaption;
    private TimeSpan keyTime;
    private Point clickPoint;
    private TimeSpan clickTime;
    private readonly HashSet<int> pressed = [];
    private bool clicked;

    public BitmapSource Render(BitmapSource frame, System.Drawing.Rectangle screen, TimeSpan time, BitmapSource? camera)
    {
        Point pointer = new(Desktop.Cursor.X - screen.X, Desktop.Cursor.Y - screen.Y);
        if (clicks)
        {
            bool down = IsDown(1) || IsDown(2);
            if (down && !clicked && screen.Contains(Desktop.Cursor)) { clickPoint = pointer; clickTime = time; }
            clicked = down;
        }
        if (keys)
        {
            ModifierKeys modifiers = (IsDown(0x11) ? ModifierKeys.Control : 0) | (IsDown(0x10) ? ModifierKeys.Shift : 0) |
                (IsDown(0x12) ? ModifierKeys.Alt : 0) | (IsDown(0x5b) || IsDown(0x5c) ? ModifierKeys.Windows : 0);
            for (int vk = 8; vk <= 0xde; vk++)
            {
                var key = KeyInterop.KeyFromVirtualKey(vk);
                if (key is Key.None or Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) continue;
                if (!IsDown(vk)) { pressed.Remove(vk); continue; }
                if (!pressed.Add(vk)) continue;
                string display = key.ToString();
                if (display.Length == 2 && display[0] == 'D' && char.IsAsciiDigit(display[1])) display = display[1..];
                keyCaption = (modifiers == ModifierKeys.None ? "" : modifiers.ToString().Replace(", ", "+").Replace("Control", "Ctrl") + "+") + display;
                keyTime = time;
            }
        }

        bool drawClick = clicks && clickTime != TimeSpan.Zero && time - clickTime < TimeSpan.FromMilliseconds(430);
        bool drawKey = keys && keyCaption != null && time - keyTime < TimeSpan.FromMilliseconds(1350);
        bool drawCursor = cursor && screen.Contains(Desktop.Cursor);
        if (camera == null && !drawClick && !drawKey && !drawCursor) return frame;
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            dc.DrawImage(frame, new Rect(0, 0, frame.PixelWidth, frame.PixelHeight));
            if (camera != null)
            {
                int w = Math.Min(300, frame.PixelWidth / 4);
                int h = Math.Min(frame.PixelHeight / 4, w * camera.PixelHeight / camera.PixelWidth);
                int x = Math.Max(0, frame.PixelWidth - w - 12), y = Math.Max(0, frame.PixelHeight - h - 12);
                if (w > 0 && h > 0)
                {
                    var box = new Rect(x, y, w, h);
                    dc.PushClip(new RectangleGeometry(box, 7, 7));
                    dc.DrawImage(camera, box);
                    dc.Pop();
                    dc.DrawRoundedRectangle(null, new Pen(Brushes.White, 2), box, 7, 7);
                }
            }
            if (drawClick)
            {
                double radius = 9 + (time - clickTime).TotalMilliseconds / 22;
                dc.DrawEllipse(null, new Pen(Brushes.Orange, 3), clickPoint, radius, radius);
            }
            if (drawCursor && TryCursor(out var image, out var hotspot))
                dc.DrawImage(image, new Rect(pointer.X - hotspot.X, pointer.Y - hotspot.Y, image.PixelWidth, image.PixelHeight));
            if (drawKey)
            {
                var text = new FormattedText(keyCaption!, System.Globalization.CultureInfo.InvariantCulture,
                    FlowDirection.LeftToRight, new Typeface("Segoe UI Semibold"), 19, Brushes.White, 1);
                double x = (frame.PixelWidth - text.Width) / 2, y = Math.Max(4, frame.PixelHeight - text.Height - 24);
                dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(210, 22, 24, 28)), null,
                    new Rect(x - 12, y - 6, text.Width + 24, text.Height + 12), 8, 8);
                dc.DrawText(text, new Point(x, y));
            }
        }
        var rendered = new RenderTargetBitmap(frame.PixelWidth, frame.PixelHeight, 96, 96, PixelFormats.Pbgra32);
        rendered.Render(visual);
        rendered.Freeze();
        return rendered;
    }

    private static bool TryCursor(out BitmapSource image, out Point hotspot)
    {
        image = null!;
        hotspot = default;
        var info = new CursorInfo { Size = Marshal.SizeOf<CursorInfo>() };
        if (!GetCursorInfo(ref info) || (info.Flags & 1) == 0 || !GetIconInfo(info.Handle, out var icon)) return false;
        try
        {
            image = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(info.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            hotspot = new Point(icon.HotspotX, icon.HotspotY);
            return true;
        }
        finally
        {
            if (icon.Mask != IntPtr.Zero) DeleteObject(icon.Mask);
            if (icon.Color != IntPtr.Zero) DeleteObject(icon.Color);
        }
    }

    private static bool IsDown(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;
    [StructLayout(LayoutKind.Sequential)]
    private struct CursorInfo { public int Size, Flags; public IntPtr Handle; public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct IconInfo { public int IsIcon; public uint HotspotX, HotspotY; public IntPtr Mask, Color; }
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern bool GetCursorInfo(ref CursorInfo info);
    [DllImport("user32.dll")] private static extern bool GetIconInfo(IntPtr icon, out IconInfo info);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr handle);
}

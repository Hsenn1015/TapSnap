using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Forms = System.Windows.Forms;
using Point = System.Drawing.Point;
using Rectangle = System.Drawing.Rectangle;

namespace TapSnap.Windows;

internal static class Desktop
{
    public static Rectangle CursorMonitor => Forms.Screen.FromPoint(Forms.Cursor.Position).Bounds;
    public static Point Cursor => Forms.Cursor.Position;

    public static IReadOnlyList<(string Name, Rectangle Bounds)> Monitors()
    {
        var monitors = new List<(string, Rectangle)>();
        foreach (var screen in Forms.Screen.AllScreens)
            monitors.Add((screen.DeviceName, screen.Bounds));
        return monitors;
    }

    public static BitmapSource Capture(Rectangle region)
    {
        if (region.Width <= 0 || region.Height <= 0)
            throw new ArgumentException("截图区域为空。", nameof(region));

        using var bitmap = new Bitmap(region.Width, region.Height, PixelFormat.Format32bppRgb);
        var sourceDc = GetDC(IntPtr.Zero);
        if (sourceDc == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            using var graphics = Graphics.FromImage(bitmap);
            var destinationDc = graphics.GetHdc();
            try
            {
                if (!BitBlt(destinationDc, 0, 0, region.Width, region.Height, sourceDc, region.X, region.Y, 0x40CC0020))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { graphics.ReleaseHdc(destinationDc); }
        }
        finally { ReleaseDC(IntPtr.Zero, sourceDc); }
        var data = bitmap.LockBits(new Rectangle(Point.Empty, bitmap.Size), ImageLockMode.ReadOnly, bitmap.PixelFormat);
        try
        {
            var source = BitmapSource.Create(region.Width, region.Height, 96, 96,
                System.Windows.Media.PixelFormats.Bgr32, null, data.Scan0, data.Stride * data.Height, data.Stride);
            source.Freeze();
            return source;
        }
        finally { bitmap.UnlockBits(data); }
    }

    public static BitmapSource CaptureDesktop(Rectangle region, bool hideDesktopIcons) =>
        CaptureDesktop([region], hideDesktopIcons)[0];

    public static BitmapSource[] CaptureDesktop(IReadOnlyList<Rectangle> regions, bool hideDesktopIcons)
    {
        IntPtr icons = IntPtr.Zero;
        if (hideDesktopIcons)
        {
            for (var window = GetTopWindow(IntPtr.Zero); window != IntPtr.Zero; window = GetWindow(window, 2))
            {
                var view = FindWindowExW(window, IntPtr.Zero, "SHELLDLL_DefView", null);
                if (view == IntPtr.Zero) continue;
                var list = FindWindowExW(view, IntPtr.Zero, "SysListView32", null);
                if (list == IntPtr.Zero || !IsWindowVisible(list)) continue;
                icons = list;
                ShowWindow(icons, 0);
                Flush();
                break;
            }
        }
        try
        {
            var frames = new BitmapSource[regions.Count];
            for (int i = 0; i < regions.Count; i++) frames[i] = Capture(regions[i]);
            return frames;
        }
        finally { if (icons != IntPtr.Zero) ShowWindow(icons, 8); }
    }

    public static BitmapSource CaptureWindow(IntPtr window, Rectangle bounds)
    {
        var requested = WindowBounds(window, 0) ?? bounds;
        if (!requested.Contains(bounds)) return Capture(bounds);
        using var bitmap = new Bitmap(requested.Width, requested.Height, PixelFormat.Format32bppRgb);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            IntPtr dc = graphics.GetHdc();
            bool printed;
            try { printed = PrintWindow(window, dc, 2); }
            finally { graphics.ReleaseHdc(dc); }
            if (!printed) return Capture(bounds);
        }
        using var stream = new MemoryStream();
        using var cropped = requested == bounds ? null : bitmap.Clone(
            new Rectangle(bounds.X - requested.X, bounds.Y - requested.Y, bounds.Width, bounds.Height),
            bitmap.PixelFormat);
        (cropped ?? bitmap).Save(stream, ImageFormat.Png);
        stream.Position = 0;
        var image = BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        image.Freeze();
        return image;
    }

    public static (IntPtr Handle, Rectangle Bounds)? WindowUnder(Point point, IntPtr excluded)
    {
        for (IntPtr window = GetTopWindow(IntPtr.Zero); window != IntPtr.Zero; window = GetWindow(window, 2))
        {
            if (window == excluded || !IsWindowVisible(window) || IsIconic(window) ||
                (GetWindowLongW(window, -20) & 0x20) != 0 ||
                DwmGetWindowAttribute(window, 14, out int cloaked, 4) == 0 && cloaked != 0 ||
                GetWindowThreadProcessId(window, out uint pid) == 0 || pid == Environment.ProcessId)
                continue;
            var bounds = WindowBounds(window, 9);
            if (bounds is { Width: > 2, Height: > 2 } rect && rect.Contains(point))
                return (window, rect);
        }
        return null;
    }

    private static Rectangle? WindowBounds(IntPtr window, int attribute)
    {
        NativeRect bounds;
        if (attribute != 0 && DwmGetWindowAttribute(window, attribute, out bounds, 16) == 0 ||
            GetWindowRect(window, out bounds))
            return Rectangle.FromLTRB(bounds.Left, bounds.Top, bounds.Right, bounds.Bottom);
        return null;
    }

    public static void Place(Window window, Rectangle bounds, bool keepSize = false, bool raiseTopmost = false)
    {
        IntPtr handle = new WindowInteropHelper(window).EnsureHandle();
        if (!SetWindowPos(handle, raiseTopmost ? new IntPtr(-1) : IntPtr.Zero, bounds.X, bounds.Y, bounds.Width, bounds.Height,
                          0x0010 | (raiseTopmost ? 0 : 0x0004u) | (keepSize ? 0x0001u : 0)))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public static double ScaleForMonitor(Rectangle bounds)
    {
        var monitor = MonitorFromPoint(new Point(bounds.X + 1, bounds.Y + 1), 2);
        return GetDpiForMonitor(monitor, 0, out uint x, out _) == 0 ? x / 96d : 1;
    }

    public static bool TryWindowBounds(Window window, out Rectangle bounds)
    {
        var result = WindowBounds(new WindowInteropHelper(window).Handle, 0);
        bounds = result.GetValueOrDefault();
        return result.HasValue;
    }

    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(Point point, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint x, out uint y);

    public static bool AllowSelfCapture { get; set; }

    public static bool Exclude(Window window)
        => SetWindowDisplayAffinity(new WindowInteropHelper(window).EnsureHandle(), AllowSelfCapture ? 0u : 0x11u);

    public static void ApplyCaptureVisibility(Window window) => _ = Exclude(window);

    public static void RefreshCaptureVisibility(Application app)
    {
        foreach (Window window in app.Windows)
        {
            if (window.IsLoaded && window.WindowStyle == WindowStyle.None)
                _ = Exclude(window);
        }
    }

    public static void RemoveFromCapture(Window window)
        => SetWindowDisplayAffinity(new WindowInteropHelper(window).EnsureHandle(), 0);

    public static void Flush() => DwmFlush();

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool BitBlt(IntPtr destination, int x, int y, int width, int height,
        IntPtr source, int sourceX, int sourceY, uint rasterOperation);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr relative, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    private static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
    [DllImport("dwmapi.dll")]
    private static extern int DwmFlush();
    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out NativeRect result, int size);
    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int result, int size);
    [DllImport("user32.dll")]
    private static extern IntPtr GetTopWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    private static extern int GetWindowLongW(IntPtr window, int index);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint id);
    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string className, string? title);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);
}

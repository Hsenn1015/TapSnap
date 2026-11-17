using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;

namespace TapSnap.Windows;

// The sRGB equivalents of TapSnapTheme/Tokens.swift and EditCanvasView.swift.
internal sealed record SnapPalette(SolidColorBrush Background, SolidColorBrush Panel, SolidColorBrush Sidebar,
    SolidColorBrush Foreground, SolidColorBrush Muted, SolidColorBrush Primary, SolidColorBrush PrimaryForeground,
    SolidColorBrush Hover, SolidColorBrush Border, SolidColorBrush Input, SolidColorBrush Ring,
    SolidColorBrush EditorChrome, SolidColorBrush Canvas)
{
    private static readonly SnapPalette Dark = new(Gray(10), Gray(23), Gray(23), Gray(250), Gray(163), Gray(229), Gray(23),
        Gray(38), Gray(255, 26), Gray(255, 38), Gray(115), SnapTheme.Brush(0x24262b), SnapTheme.Brush(0x191b20));
    private static readonly SnapPalette Light = new(Gray(255), Gray(255), Gray(250), Gray(10), Gray(115), Gray(23), Gray(250),
        Gray(245), Gray(229), Gray(229), Gray(163), SnapTheme.Brush(0xeceef2), SnapTheme.Brush(0xdde1e7));

    public static SnapPalette For(bool dark) => dark ? Dark : Light;
    private static SolidColorBrush Gray(byte shade, byte opacity = 255) => SnapTheme.Brush(shade * 0x010101u, opacity);
}

internal static class SnapTheme
{
    private const int ImmersiveDarkMode = 20, CaptionColor = 35, CaptionTextColor = 36;
    public static bool IsDark { get; private set; }

    public static void Initialize(Application app, bool dark)
    {
        Apply(app, dark);
        app.Resources.MergedDictionaries.Add(new ResourceDictionary
        {
            Source = new Uri("pack://application:,,,/TapSnap;component/UI/Controls.xaml")
        });
    }

    public static void Apply(Application app, bool dark)
    {
        IsDark = dark;
        var palette = SnapPalette.For(dark);
        var resources = app.Resources;
        resources["Snap.Background"] = palette.Background;
        resources["Snap.Panel"] = palette.Panel;
        resources["Snap.Sidebar"] = palette.Sidebar;
        resources["Snap.Foreground"] = palette.Foreground;
        resources["Snap.Muted"] = palette.Muted;
        resources["Snap.Primary"] = palette.Primary;
        resources["Snap.PrimaryForeground"] = palette.PrimaryForeground;
        resources["Snap.Hover"] = palette.Hover;
        resources["Snap.Border"] = palette.Border;
        resources["Snap.Input"] = palette.Input;
        resources["Snap.Ring"] = palette.Ring;
        resources[SystemColors.WindowBrushKey] = palette.Panel;
        resources[SystemColors.WindowTextBrushKey] = palette.Foreground;
        resources[SystemColors.ControlBrushKey] = palette.Hover;
        resources[SystemColors.ControlTextBrushKey] = palette.Foreground;
        resources[SystemColors.HighlightBrushKey] = palette.Primary;
        resources[SystemColors.HighlightTextBrushKey] = palette.PrimaryForeground;
        resources[SystemColors.MenuBrushKey] = palette.Panel;
        resources[SystemColors.MenuTextBrushKey] = palette.Foreground;
        resources[SystemColors.GrayTextBrushKey] = palette.Muted;
        foreach (Window window in app.Windows)
            if (window.IsLoaded) UpdateCaption(window);
    }

    public static void StyleWindow(Window window)
    {
        if (window.ReadLocalValue(Control.BackgroundProperty) == DependencyProperty.UnsetValue)
            window.SetResourceReference(Control.BackgroundProperty, "Snap.Background");
        if (window.ReadLocalValue(Control.ForegroundProperty) == DependencyProperty.UnsetValue)
            window.SetResourceReference(Control.ForegroundProperty, "Snap.Foreground");
        if (window.ReadLocalValue(Control.FontSizeProperty) == DependencyProperty.UnsetValue) window.FontSize = 13;
        window.SourceInitialized += (_, _) => UpdateCaption(window);
    }

    private static void UpdateCaption(Window window)
    {
        if (window.WindowStyle == WindowStyle.None) return;
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        var palette = SnapPalette.For(IsDark);
        Color background = (window.Background as SolidColorBrush ?? palette.Background).Color;
        Color foreground = (window.Foreground as SolidColorBrush ?? palette.Foreground).Color;
        int dark = background.R < 128 ? 1 : 0;
        int caption = ColorRef(background), text = ColorRef(foreground);
        _ = DwmSetWindowAttribute(hwnd, ImmersiveDarkMode, ref dark, sizeof(int));
        _ = DwmSetWindowAttribute(hwnd, CaptionColor, ref caption, sizeof(int));
        _ = DwmSetWindowAttribute(hwnd, CaptionTextColor, ref text, sizeof(int));
    }

    public static SolidColorBrush Brush(uint rgb, byte opacity = 255)
    {
        var brush = new SolidColorBrush(Color.FromArgb(opacity, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        brush.Freeze();
        return brush;
    }

    private static int ColorRef(Color color) => color.R | color.G << 8 | color.B << 16;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}

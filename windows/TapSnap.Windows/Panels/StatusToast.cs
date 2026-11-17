using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using DrawingRect = System.Drawing.Rectangle;
using Forms = System.Windows.Forms;

namespace TapSnap.Windows;

internal sealed class StatusToast
{
    private Window? current;

    public void Show(string message)
    {
        Dismiss();
        var monitor = Desktop.CursorMonitor;
        var area = Forms.Screen.FromPoint(new System.Drawing.Point(monitor.Left + 1, monitor.Top + 1)).WorkingArea;
        double dpi = Desktop.ScaleForMonitor(monitor);
        bool dark = SnapTheme.IsDark;
        var palette = SnapPalette.For(dark);
        var accent = SnapTheme.Brush(dark ? 0x72e5bcu : 0x087858);
        var icon = new Border
        {
            Width = 24, Height = 24, CornerRadius = new CornerRadius(12), Margin = new Thickness(0, 0, 9, 0),
            Background = SnapTheme.Brush(dark ? 0x72e5bcu : 0x087858, dark ? (byte)43 : (byte)26),
            Child = new ContentControl { Content = ToolbarGlyph.Make("✓", 13), Foreground = accent,
                HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center }
        };
        var label = new TextBlock
        {
            Text = message, Foreground = palette.Foreground, FontSize = 13, FontWeight = FontWeights.Medium,
            VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
            LineHeight = 18, LineStackingStrategy = LineStackingStrategy.BlockLineHeight, MaxHeight = 54
        };
        var row = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        row.Children.Add(label);
        var movement = new TranslateTransform();
        var card = new Border
        {
            Background = new LinearGradientBrush(SnapTheme.Brush(dark ? 0x28303bu : 0xfcfdff).Color,
                SnapTheme.Brush(dark ? 0x1e252eu : 0xf1f4f8).Color, 90),
            BorderBrush = SnapTheme.Brush(dark ? 0xfafafau : 0x0a0a0a, 28),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(18), Padding = new Thickness(8, 7, 15, 7),
            Margin = new Thickness(14), Child = row, RenderTransform = movement,
            Effect = new DropShadowEffect { BlurRadius = 16, ShadowDepth = 3, Direction = 270, Opacity = .19 }
        };
        card.Measure(new Size(Math.Min(408, Math.Max(80, area.Width / dpi - 24)), double.PositiveInfinity));
        var window = new Window
        {
            WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
            ShowActivated = false, Topmost = true, Width = Math.Ceiling(card.DesiredSize.Width),
            Height = Math.Ceiling(card.DesiredSize.Height), Focusable = false,
            AllowsTransparency = true, Background = Brushes.Transparent, IsHitTestVisible = false,
            WindowStartupLocation = WindowStartupLocation.Manual, Content = card
        };
        bool animate = SystemParameters.ClientAreaAnimation;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.45) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (!animate) { window.Close(); return; }
            var exit = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(160));
            exit.Completed += (_, _) => { if (current == window) window.Close(); };
            window.BeginAnimation(UIElement.OpacityProperty, exit);
        };
        window.Closed += (_, _) => { timer.Stop(); if (current == window) current = null; };
        window.SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(window).Handle;
            int style = GetWindowLongW(handle, -20);
            _ = SetWindowLongW(handle, -20, style | 0x08000000 | 0x20);
            Desktop.Exclude(window);
            int width = (int)Math.Round(window.Width * dpi), height = (int)Math.Round(window.Height * dpi);
            Desktop.Place(window, new DrawingRect(area.Left + (area.Width - width) / 2,
                area.Bottom - height - (int)Math.Round(22 * dpi), width, height));
        };
        current = window;
        if (animate)
        {
            var duration = TimeSpan.FromMilliseconds(200);
            window.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, duration));
            movement.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(7, 0, duration)
                { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
        }
        window.Show();
        timer.Start();
    }

    public void Dismiss() => current?.Close();

    [System.Runtime.InteropServices.DllImport("user32.dll", ExactSpelling = true)]
    private static extern int GetWindowLongW(IntPtr window, int index);
    [System.Runtime.InteropServices.DllImport("user32.dll", ExactSpelling = true)]
    private static extern int SetWindowLongW(IntPtr window, int index, int style);
}

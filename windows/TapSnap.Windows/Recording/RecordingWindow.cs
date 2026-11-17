using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using Ellipse = System.Windows.Shapes.Ellipse;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using ScreenRect = System.Drawing.Rectangle;

namespace TapSnap.Windows;

internal sealed class RecordingWindow : Window
{
    private readonly int rate;
    private readonly DispatcherTimer timer;
    private readonly Stopwatch clock = new();
    private readonly RecordingFrames frames;
    private readonly ScreenRect captureRegion;
    private readonly ScreenRect monitor;
    private readonly Action<RecordingPreview> done;
    private readonly TextBlock status = new()
    {
        MinWidth = 53, VerticalAlignment = VerticalAlignment.Center, FontFamily = new FontFamily("Consolas"),
        FontSize = 13, FontWeight = FontWeights.SemiBold, Text = "正在开始…"
    };
    private readonly Button pause;
    private readonly Button confirm;
    private readonly Button cancel;
    private readonly Ellipse indicator = new() { Width = 8, Height = 8, Fill = Brushes.IndianRed };
    private readonly Ellipse pulse = new() { Width = 12, Height = 12, Stroke = Brushes.IndianRed, StrokeThickness = 2 };
    private bool started;
    private bool finishing;
    private Window? outline;
    private GraphicsCapture? nativeCapture;
    private RecordingCamera? camera;
    private readonly RecordingInputOverlay input;
    private readonly string borderStyle;
    private readonly CancellationTokenSource stopWork = new();
    private RecordingAudio? audio;
    private bool closed;

    public RecordingWindow(ScreenRect region, Settings settings, Action<RecordingPreview> done)
    {
        captureRegion = region;
        monitor = Desktop.Monitors().FirstOrDefault(m => m.Bounds.Contains(region)).Bounds;
        this.done = done;
        rate = settings.RecordFrameRate >= 60 ? 60 : 30;
        frames = new RecordingFrames(region.Width, region.Height);
        borderStyle = settings.SelectionBorder;
        var palette = SnapPalette.For(settings.DarkTheme);
        status.Foreground = palette.Foreground;
        timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1d / rate) };
        input = new RecordingInputOverlay(settings.RecordCursor, settings.RecordShowKeys, settings.RecordShowClicks);
        Title = "TapSnap 录屏";
        Width = 244;
        Height = 58;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        var layout = new Grid { HorizontalAlignment = HorizontalAlignment.Center };
        foreach (int width in new[] { 24, 65, 13, 31, 31, 56 })
            layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(width) });
        void PlaceControl(UIElement control, int column)
        {
            Grid.SetColumn(control, column);
            layout.Children.Add(control);
        }
        var dot = new Grid { Width = 20, Height = 20, HorizontalAlignment = HorizontalAlignment.Center };
        dot.Children.Add(pulse);
        dot.Children.Add(indicator);
        PlaceControl(dot, 0);
        PlaceControl(status, 1);
        PlaceControl(new Border
        {
            Width = 1, Height = 16, VerticalAlignment = VerticalAlignment.Center,
            Background = palette.Border
        }, 2);
        pause = Control("pause", "暂停录制", TogglePause);
        pause.IsEnabled = false;
        PlaceControl(pause, 3);
        cancel = Control("×", "取消录制", Close);
        PlaceControl(cancel, 4);
        confirm = Control("完成", "完成录制", Finish, primary: true);
        confirm.IsEnabled = false;
        PlaceControl(confirm, 5);
        Content = new Border
        {
            Height = 44, Margin = new Thickness(7), CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1), BorderBrush = palette.Border,
            Background = palette.Panel, Child = layout,
            Effect = new DropShadowEffect { BlurRadius = 12, ShadowDepth = 3, Direction = 270, Opacity = 0.24 }
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && !finishing) { Close(); e.Handled = true; }
            else if (e.Key == Key.Enter && started && !finishing) { Finish(); e.Handled = true; }
        };
        SourceInitialized += (_, _) => Desktop.Exclude(this);
        Loaded += async (_, _) =>
        {
            try
            {
                var screen = monitor.IsEmpty ? Desktop.CursorMonitor : monitor;
                var area = System.Windows.Forms.Screen.FromPoint(new System.Drawing.Point(screen.X + 1, screen.Y + 1)).WorkingArea;
                double dpi = Desktop.ScaleForMonitor(screen);
                int width = (int)Math.Round(Width * dpi), height = (int)Math.Round(Height * dpi);
                int x = area.Left + Math.Max(0, (area.Width - width) / 2);
                int y = area.Top + (int)Math.Round(5 * dpi);
                Desktop.Place(this, new ScreenRect(x, y, width, height));
                if (settings.RecordCamera)
                {
                    var pendingCamera = new RecordingCamera();
                    try { await pendingCamera.StartAsync(); }
                    catch { await pendingCamera.DisposeAsync(); throw; }
                    if (closed) { await pendingCamera.DisposeAsync(); return; }
                    camera = pendingCamera;
                }
                if (settings.RecordMicrophone || settings.RecordSystemAudio)
                    audio = new RecordingAudio(settings.RecordMicrophone, settings.RecordSystemAudio, frames.Folder);
                if (!monitor.IsEmpty) nativeCapture = GraphicsCapture.StartMonitor(monitor);
                ShowOutline(region);
                clock.Start();
                audio?.SetPaused(false);
                timer.Start();
                started = true;
                status.Text = "00:00";
                pause.IsEnabled = confirm.IsEnabled = true;
                UpdateIndicator(true);
                CaptureFrame();
            }
            catch (Exception error)
            {
                if (!closed) { MessageBox.Show(this, error.Message, "无法开始录屏", MessageBoxButton.OK, MessageBoxImage.Error); Close(); }
            }
        };
        Closed += async (_, _) =>
        {
            closed = true;
            timer.Stop();
            nativeCapture?.Dispose();
            outline?.Close();
            frames.Stop();
            stopWork.Cancel();
            nativeCapture = null;
            try
            {
                if (!finishing) audio?.Dispose();
                if (camera != null) await camera.DisposeAsync();
                if (!finishing) await frames.Completion;
            }
            catch (Exception error) { Trace.WriteLine(error); }
            finally
            {
                if (!finishing)
                {
                    frames.Clean();
                    stopWork.Dispose();
                }
            }
        };
        timer.Tick += (_, _) => CaptureFrame();
    }

    private void TogglePause()
    {
        if (!started || finishing) return;
        if (clock.IsRunning) { clock.Stop(); timer.Stop(); audio?.SetPaused(true); }
        else { clock.Start(); timer.Start(); audio?.SetPaused(false); }
        pause.Content = ToolbarGlyph.Make(clock.IsRunning ? "pause" : "play");
        pause.ToolTip = clock.IsRunning ? "暂停录制" : "继续录制";
        if (outline != null) outline.Opacity = clock.IsRunning ? 1 : 0.45;
        UpdateIndicator(clock.IsRunning);
    }

    private void UpdateIndicator(bool running)
    {
        indicator.Opacity = running ? 1 : 0.4;
        pulse.BeginAnimation(OpacityProperty, null);
        pulse.Opacity = running ? 0.45 : 0;
        if (running && SystemParameters.ClientAreaAnimation)
            pulse.BeginAnimation(OpacityProperty, new DoubleAnimation(0.25, 0.7, TimeSpan.FromSeconds(0.7))
            {
                RepeatBehavior = RepeatBehavior.Forever, AutoReverse = true
            });
    }

    private static Button Control(string label, string title, Action action, bool primary = false)
    {
        var button = Button(label, action);
        button.ToolTip = title;
        System.Windows.Automation.AutomationProperties.SetName(button, title);
        button.Margin = new Thickness(2);
        button.Height = 28;
        button.Padding = new Thickness(0);
        button.Cursor = Cursors.Hand;
        button.FontSize = 12;
        if (!primary) button.Content = ToolbarGlyph.Make(label);
        button.SetResourceReference(StyleProperty, primary ? "SnapPrimary" : "SnapGhost");
        return button;
    }

    private void ShowOutline(ScreenRect region)
    {
        var border = new SelectionBorder(borderStyle);
        outline = new Window
        {
            WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
            AllowsTransparency = true, Background = Brushes.Transparent, ShowActivated = false, Topmost = true,
            Content = border
        };
        double scale = Desktop.ScaleForMonitor(monitor.IsEmpty ? Desktop.CursorMonitor : monitor);
        int inset = (int)Math.Round(14 * scale);
        var expanded = ScreenRect.Inflate(region, inset, inset);
        var frame = monitor.IsEmpty ? expanded : ScreenRect.Intersect(expanded, monitor);
        void UpdateOutline()
        {
            if (border.ActualWidth <= 0 || border.ActualHeight <= 0) return;
            double x = border.ActualWidth / frame.Width, y = border.ActualHeight / frame.Height;
            var local = new Rect((region.Left - frame.Left) * x, (region.Top - frame.Top) * y,
                region.Width * x, region.Height * y);
            border.Update(SelectionBorder.Outline(local, new Rect(0, 0, border.ActualWidth, border.ActualHeight)), false);
        }
        outline.SizeChanged += (_, _) => UpdateOutline();
        outline.Loaded += (_, _) => UpdateOutline();
        outline.SourceInitialized += (_, _) =>
        {
            var window = outline;
            if (window == null) return;
            Desktop.Place(window, frame);
            var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
            SetWindowLongW(hwnd, -20, GetWindowLongW(hwnd, -20) | 0x20 | 0x08000000);
            Desktop.Exclude(window);
        };
        outline.Show();
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int SetWindowLongW(IntPtr window, int index, int value);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int GetWindowLongW(IntPtr window, int index);

    private void CaptureFrame()
    {
        try
        {
            BitmapSource source;
            if (nativeCapture?.LatestFrame is { } frame && frame.PixelWidth == monitor.Width && frame.PixelHeight == monitor.Height)
                source = new CroppedBitmap(frame, new Int32Rect(captureRegion.X - monitor.X, captureRegion.Y - monitor.Y,
                    captureRegion.Width, captureRegion.Height));
            else
            {
                bool overlaps = Desktop.TryWindowBounds(this, out var bounds) && bounds.IntersectsWith(captureRegion);
                double opacity = Opacity;
                if (overlaps) { Opacity = 0; Desktop.Flush(); }
                try { source = Desktop.Capture(captureRegion); }
                finally { if (overlaps) Opacity = opacity; }
            }
            source = input.Render(source, captureRegion, clock.Elapsed, camera?.Latest);
            frames.Add(clock.Elapsed, source);
            status.Text = $"{(int)clock.Elapsed.TotalMinutes:00}:{clock.Elapsed.Seconds:00}";
        }
        catch (Exception error)
        {
            timer.Stop();
            if (!closed)
            {
                MessageBox.Show(this, error.Message, "录屏失败", MessageBoxButton.OK, MessageBoxImage.Error);
                Close();
            }
        }
    }

    public async void Finish()
    {
        if (!started || finishing) return;
        finishing = true;
        clock.Stop();
        timer.Stop();
        audio?.SetPaused(true);
        frames.Stop();
        UpdateIndicator(false);
        status.Text = "正在结束…";
        pause.IsEnabled = confirm.IsEnabled = cancel.IsEnabled = false;
        outline?.Hide();
        try
        {
            await frames.Completion;
            if (frames.Count == 0) { frames.Clean(); Close(); return; }
            string? sound = audio == null ? null : await Task.Run(() => audio.Mix(Path.Combine(frames.Folder, "sound.pcm"), stopWork.Token));
            if (closed) { frames.Clean(); return; }
            var session = new RecordingPreview(frames, clock.Elapsed + TimeSpan.FromSeconds(1d / rate), rate, sound);
            Close();
            done(session);
        }
        catch (Exception error)
        {
            frames.Clean();
            if (!closed) { MessageBox.Show(this, error.Message, "录屏失败", MessageBoxButton.OK, MessageBoxImage.Error); Close(); }
        }
        finally { audio?.Dispose(); stopWork.Dispose(); }
    }

    internal static Button Button(string title, Action action)
    {
        var button = new Button { Content = title, Padding = new Thickness(9, 4, 9, 4), Margin = new Thickness(3) };
        button.Click += (_, _) => action();
        return button;
    }
}


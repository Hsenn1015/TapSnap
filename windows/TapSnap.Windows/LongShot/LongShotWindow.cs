using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using PixelRect = System.Drawing.Rectangle;
using WinButton = System.Windows.Controls.Button;
using WinImage = System.Windows.Controls.Image;
using WinLabel = System.Windows.Controls.TextBlock;
using WinPoint = System.Windows.Point;

namespace TapSnap.Windows;

internal sealed class LongShotWindow : Window
{
    private readonly PixelRect selection;
    private readonly Func<PixelRect, BitmapSource> capture;
    private readonly Action<BitmapSource> finish;
    private readonly Settings settings;
    private readonly ScrollViewer scroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto
    };
    private readonly Grid imageLayer = new() { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    private readonly Border liveViewport = new() { BorderBrush = Brushes.DodgerBlue, BorderThickness = new Thickness(1),
        IsHitTestVisible = false, Visibility = Visibility.Collapsed };
    private readonly WinImage image = new() { Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Top };
    private readonly WinLabel status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly WinLabel dimensions = new();
    private readonly WinButton autoScroll;
    private readonly WinButton select;
    private readonly WinButton complete;
    private readonly DispatcherTimer timer = new(DispatcherPriority.Background);
    private readonly ComboBox step = new() { Width = 106, ToolTip = "每次自动滚动的幅度", SelectedIndex = 0 };
    private readonly ComboBox interval = new() { Width = 98, ToolTip = "自动滚动间隔", SelectedIndex = 0 };
    private ScrollStitcher? stitcher;
    private ScrollInput? input;
    private PixelRect? viewport;
    private ScrollTarget? target;
    private bool processing;
    private bool resolving;
    private bool attemptedResolution;
    private bool auto;
    private bool startAutomatically;
    private bool finished;
    private bool finalizing;
    private int stationaryFrames;
    private DateTimeOffset nextAutoScroll;
    private DateTimeOffset settleUntil;
    private bool pendingAutomaticFrame;
    private IntPtr hwnd;

    public LongShotWindow(PixelRect physicalRegion, Func<PixelRect, BitmapSource> capture, Action<BitmapSource> finish,
                          Settings? settings = null)
    {
        selection = physicalRegion;
        this.capture = capture;
        this.finish = finish;
        this.settings = settings ?? new Settings();
        startAutomatically = this.settings.LongShotAutoScroll;
        Title = "正在截取长图";
        Width = 430;
        Height = 520;
        MinWidth = 390;
        MinHeight = 240;
        Topmost = true;
        ShowActivated = false;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.Manual;
        SnapTheme.StyleWindow(this);

        var palette = SnapPalette.For(this.settings.DarkTheme);
        var panel = new DockPanel { Margin = new Thickness(12) };
        var footer = new StackPanel();
        var controls = new WrapPanel();
        step.Items.Add($"{this.settings.LongShotStepPixels} 像素");
        step.Items.Add("步长：小");
        step.Items.Add("步长：大");
        step.SelectedIndex = 0;
        interval.Items.Add($"{this.settings.LongShotIntervalMilliseconds:N0} 毫秒");
        interval.Items.Add("0.65 秒");
        interval.Items.Add("1.5 秒");
        interval.SelectedIndex = 0;
        controls.Children.Add(step);
        controls.Children.Add(interval);
        footer.Children.Add(controls);
        footer.Children.Add(dimensions);
        footer.Children.Add(status);
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        autoScroll = Button("自动滚动", ToggleAutomatic);
        select = Button("滚动区域…", SelectViewport);
        complete = Button("完成", Complete);
        complete.SetResourceReference(StyleProperty, "SnapPrimary");
        actions.Children.Add(autoScroll);
        actions.Children.Add(select);
        actions.Children.Add(Button("取消", Close));
        actions.Children.Add(complete);
        footer.Children.Add(actions);
        DockPanel.SetDock(footer, Dock.Bottom);
        panel.Children.Add(footer);
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
        scroll.Background = palette.Canvas;
        imageLayer.Children.Add(image);
        imageLayer.Children.Add(liveViewport);
        scroll.Content = imageLayer;
        scroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        scroll.SizeChanged += (_, _) => LayoutPreview();
        panel.Children.Add(new Border { Child = scroll, BorderBrush = palette.Border, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 0, 0, 8) });
        Content = panel;
        Status("在正文上向下滚动。也可以点「滚动区域…」手动指定。");

        SourceInitialized += (_, _) =>
        {
            hwnd = new WindowInteropHelper(this).Handle;
            PlaceWindow();
            Desktop.Exclude(this);
        };
        Loaded += (_, _) =>
        {
            if (stitcher != null)
                return;
            try
            {
                stitcher = new ScrollStitcher(ReadFrame());
                UpdatePreview(ToBitmap(stitcher.Preview()), stitcher.Width, stitcher.Height);
                input = new ScrollInput(
                    point => Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => UserScrolled(point))),
                    point => Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
                    {
                        if (auto && !OverPanel(point)) PauseAutomatic("检测到鼠标操作，自动滚动已暂停。");
                    })));
                timer.Start();
            }
            catch (Exception error)
            {
                Status($"无法开始长截图：{error.Message}", warning: true);
                complete.IsEnabled = autoScroll.IsEnabled = select.IsEnabled = false;
            }
        };
        Closed += (_, _) =>
        {
            finished = true;
            timer.Stop();
            input?.Dispose();
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
                e.Handled = true;
            }
            else if (e.Key == Key.Enter && e.OriginalSource is not ComboBox && e.OriginalSource is not WinButton)
            {
                Complete();
                e.Handled = true;
            }
        };
        timer.Interval = TimeSpan.FromMilliseconds(190);
        timer.Tick += async (_, _) => await Tick();
    }

    private async Task Tick()
    {
        if (finished || stitcher == null || processing || resolving || finalizing)
            return;

        if (viewport == null)
        {
            if (input?.IsAvailable != true && !attemptedResolution && Native.GetCursorPos(out var position) &&
                selection.Contains(position.X, position.Y) && !OverPanel(position))
                await ResolveViewport(new WinPoint(position.X, position.Y));
            return;
        }

        var activeStitcher = stitcher;
        processing = true;
        try
        {
            var now = DateTimeOffset.UtcNow;
            if (auto && pendingAutomaticFrame && now < settleUntil)
                return;
            if (auto && !pendingAutomaticFrame && now >= nextAutoScroll)
            {
                if ((Native.GetAsyncKeyState(0x01) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x02) & 0x8000) != 0)
                {
                    PauseAutomatic("检测到鼠标操作，自动滚动已暂停。");
                }
                else
                {
                    bool moved = await ScrollOnce();
                    if (finished || finalizing)
                        return;
                    if (!moved)
                        PauseAutomatic("无法继续自动滚动。可以手动滚动或完成截图。");
                    else
                    {
                        var afterScroll = DateTimeOffset.UtcNow;
                        nextAutoScroll = afterScroll.AddSeconds(interval.SelectedIndex switch
                        {
                            1 => 0.65,
                            2 => 1.5,
                            _ => Math.Clamp(settings.LongShotIntervalMilliseconds, 300, 5000) / 1000.0
                        });
                        settleUntil = afterScroll.AddMilliseconds(140);
                        pendingAutomaticFrame = true;
                        return;
                    }
                }
            }

            var frame = ReadFrame();
            var result = await Task.Run(() =>
            {
                var outcome = activeStitcher.Append(frame);
                var preview = outcome == ScrollAppendStatus.Added
                    ? ToBitmap(activeStitcher.Preview()) : null;
                return (outcome, preview);
            });
            if (finished)
                return;
            if (finalizing)
                return;

            switch (result.outcome)
            {
                case ScrollAppendStatus.Added:
                    pendingAutomaticFrame = false;
                    stationaryFrames = 0;
                    if (result.preview is { } preview)
                        UpdatePreview(preview, activeStitcher.Width, activeStitcher.Height);
                    select.IsEnabled = false;
                    Status(viewport.Value.Size != selection.Size
                        ? "固定区域保留一次，其下留白。"
                        : "继续向下滚动，结束时点击「完成」。");
                    break;
                case ScrollAppendStatus.Unchanged:
                    if (auto && pendingAutomaticFrame && DateTimeOffset.UtcNow >= nextAutoScroll)
                    {
                        pendingAutomaticFrame = false;
                        if (++stationaryFrames >= 3)
                            PauseAutomatic("页面已停止移动，可完成截图。");
                    }
                    break;
                case ScrollAppendStatus.Reversed:
                    PauseAutomatic("向下滚动可继续。请回到刚才的页面位置。");
                    break;
                case ScrollAppendStatus.Mismatch:
                    if (!auto || !pendingAutomaticFrame || DateTimeOffset.UtcNow >= nextAutoScroll)
                        PauseAutomatic("两屏重叠不足或页面仍在变化，请回到上一屏并减小滚动步长。");
                    break;
                case ScrollAppendStatus.LimitReached:
                    PauseAutomatic("已达到 6400 万像素上限，可以完成截图。");
                    break;
            }
        }
        catch (Exception error)
        {
            if (!finished)
            {
                PauseAutomatic($"长截图暂时中断：{error.Message}");
                timer.Stop();
            }
        }
        finally
        {
            processing = false;
            if (finalizing && !finished)
                FinishImage();
        }
    }

    private async void UserScrolled(WinPoint point)
    {
        if (finished || finalizing || !selection.Contains((int)point.X, (int)point.Y) || OverPanel(point))
            return;
        if (auto) PauseAutomatic("已切换为手动滚动。");
        if (viewport is { } region && !region.Contains((int)point.X, (int)point.Y) && stitcher?.AddedRows > 0)
        {
            Status("滚动目标已改变，正在保留现有长图。");
            Complete();
        }
        else if (viewport == null && !resolving && !attemptedResolution)
            await ResolveViewport(point);
    }

    private async Task ResolveViewport(WinPoint point)
    {
        resolving = true;
        attemptedResolution = true;
        try
        {
            Status("正在识别滚动区域…");
            target = await Task.Run(() => FindScrollTarget(point)).WaitAsync(TimeSpan.FromSeconds(1.4));
            if (finished || finalizing)
                return;
            if (target is { } found)
                ConfigureViewport(found.Bounds);
            else
            {
                timer.Stop();
                Status("可以手动指定页面中会滚动的区域。");
            }
        }
        catch (TimeoutException)
        {
            if (!finished)
            {
                timer.Stop();
                Status("识别超时，请点「滚动区域…」手动指定。");
            }
        }
        catch (Exception error)
        {
            if (!finished)
            {
                timer.Stop();
                Status($"无法识别滚动区域：{error.Message}。请手动指定。", warning: true);
            }
        }
        finally
        {
            resolving = false;
        }
        if (!finished && !finalizing && target is null && viewport is null) SelectViewport();
    }

    private ScrollTarget? FindScrollTarget(WinPoint point)
    {
        try
        {
            var walker = TreeWalker.RawViewWalker;
            var current = AutomationElement.FromPoint(point);
            for (int i = 0; current != null && i < 24; i++, current = walker.GetParent(current))
            {
                if (!current.TryGetCurrentPattern(ScrollPattern.Pattern, out var pattern) ||
                    pattern is not ScrollPattern scrollPattern || !scrollPattern.Current.VerticallyScrollable)
                    continue;

                var bounds = current.Current.BoundingRectangle;
                if (bounds.IsEmpty || !bounds.Contains(point))
                    continue;
                var rectangle = PixelBounds(bounds);
                for (var parent = walker.GetParent(current); parent != null; parent = walker.GetParent(parent))
                {
                    var limits = parent.Current.BoundingRectangle;
                    if (!limits.IsEmpty && limits.Contains(point))
                        rectangle = PixelRect.Intersect(rectangle, PixelBounds(limits));
                    if (parent.Current.ControlType == ControlType.Window)
                        break;
                }
                rectangle = PixelRect.Intersect(selection, ExcludeIndependentScrollBar(current, rectangle));
                if (rectangle.Width > 16 && rectangle.Height > 32)
                    return new ScrollTarget(rectangle, point);
            }
        }
        catch (Exception e) when (e is ElementNotAvailableException or COMException or InvalidOperationException)
        {
        }
        return null;
    }

    private static PixelRect ExcludeIndependentScrollBar(AutomationElement viewport, PixelRect bounds)
    {
        var walker = TreeWalker.ControlViewWalker;
        var bar = walker.GetFirstChild(viewport);
        for (int i = 0; bar != null && i < 20; i++, bar = walker.GetNextSibling(bar))
        {
            if (bar.Current.ControlType != ControlType.ScrollBar || bar.Current.Orientation != OrientationType.Vertical ||
                bar.Current.IsOffscreen)
                continue;
            var area = bar.Current.BoundingRectangle;
            if (area.IsEmpty)
                continue;
            var strip = PixelRect.Intersect(bounds, PixelBounds(area));
            if (strip.Height < bounds.Height * 0.6 || strip.Width < 1 || strip.Width > bounds.Width / 4)
                continue;

            // Only trim a separate scrollbar where the accessibility provider also exposes
            // an adjacent full-height content child. An overlay bar can cover document pixels.
            var child = walker.GetFirstChild(viewport);
            for (int j = 0; child != null && j < 20; j++, child = walker.GetNextSibling(child))
            {
                if (child.Current.ControlType == ControlType.ScrollBar || child.Current.IsOffscreen)
                    continue;
                var childBounds = child.Current.BoundingRectangle;
                if (childBounds.IsEmpty)
                    continue;
                var content = PixelRect.Intersect(bounds, PixelBounds(childBounds));
                if (content.Width < bounds.Width * 0.6 || content.Height < bounds.Height * 0.6)
                    continue;
                if (strip.Right >= bounds.Right - 3 && content.Right <= strip.Left)
                    return PixelRect.FromLTRB(bounds.Left, bounds.Top, strip.Left, bounds.Bottom);
                if (strip.Left <= bounds.Left + 3 && content.Left >= strip.Right)
                    return PixelRect.FromLTRB(strip.Right, bounds.Top, bounds.Right, bounds.Bottom);
            }
        }
        return bounds;
    }

    private static PixelRect PixelBounds(Rect bounds) => PixelRect.FromLTRB(
        (int)Math.Ceiling(bounds.Left), (int)Math.Ceiling(bounds.Top),
        (int)Math.Floor(bounds.Right), (int)Math.Floor(bounds.Bottom));

    private void SelectViewport()
    {
        if (finished || processing || resolving || stitcher == null || stitcher.AddedRows > 0)
            return;
        PauseAutomatic(null);
        timer.Stop();
        Status("请在原选区内框选会滚动的部分，按回车确认。");
        var dialog = new ScrollViewportPicker(ToBitmap(stitcher.FirstFrame), selection, settings.SelectionBorder) { Owner = this };
        if (dialog.ShowDialog() == true && dialog.Selection is PixelRect part)
        {
            part.Offset(selection.X, selection.Y);
            target = null;
            ConfigureViewport(part);
        }
        else if (viewport != null)
            timer.Start();
        else
            Close();
    }

    private void ConfigureViewport(PixelRect region)
    {
        var part = region;
        part.Offset(-selection.X, -selection.Y);
        stitcher!.SetViewport(part);
        viewport = region;
        Status("向下滚动，结束时点击「完成」。");
        LayoutPreview();
        timer.Start();
        if (startAutomatically)
        {
            startAutomatically = false;
            ToggleAutomatic();
        }
    }

    private void ToggleAutomatic()
    {
        if (auto)
        {
            PauseAutomatic("自动滚动已暂停，仍可手动滚动。");
            return;
        }
        if (viewport == null)
        {
            startAutomatically = true;
            Status("先在正文上滚动一次，或手动指定滚动区域。");
            timer.Start();
            return;
        }
        auto = true;
        stationaryFrames = 0;
        pendingAutomaticFrame = false;
        nextAutoScroll = DateTimeOffset.UtcNow.AddMilliseconds(220);
        autoScroll.Content = "暂停滚动";
        Status("正在自动向下滚动…");
        timer.Start();
    }

    private async Task<bool> ScrollOnce()
    {
        if (viewport is not { } region)
            return false;

        int motion = step.SelectedIndex;
        double desired = motion switch
        {
            1 => settings.LongShotStepPixels * 0.5,
            2 => settings.LongShotStepPixels * 1.5,
            _ => settings.LongShotStepPixels
        };
        double overlap = double.IsFinite(settings.LongShotOverlap) ? Math.Clamp(settings.LongShotOverlap, 0.35, 0.9) : 0.4;
        double scrollPixels = Math.Clamp(desired, 1, Math.Max(1, Math.Floor(region.Height * (1 - overlap))));
        var point = target?.Point ?? new WinPoint(region.Left + region.Width / 2, region.Top + region.Height / 2);
        if (target != null)
        {
            try
            {
                return await Task.Run(() => MoveScrollPattern(point, scrollPixels / region.Height)).WaitAsync(TimeSpan.FromSeconds(1.4));
            }
            catch (TimeoutException)
            {
                return false;
            }
        }
        var position = new Native.Point { X = (int)point.X, Y = (int)point.Y };
        if (OverPanel(position))
            return false;
        var handle = Native.WindowFromPoint(position);
        if (handle == IntPtr.Zero)
            return false;
        // Wheel distances are application-specific; use fractional detents for short viewports.
        int wheelDelta = Math.Clamp((int)Math.Round(scrollPixels), 30, 240);
        int mouseData = -wheelDelta << 16;
        int location = (position.X & 0xffff) | (position.Y << 16);
        return Native.PostMessage(handle, 0x020A, new IntPtr(mouseData), new IntPtr(location));
    }

    private static bool MoveScrollPattern(WinPoint point, double fraction)
    {
        try
        {
            var walker = TreeWalker.RawViewWalker;
            var current = AutomationElement.FromPoint(point);
            for (int i = 0; current != null && i < 24; i++, current = walker.GetParent(current))
            {
                if (!current.TryGetCurrentPattern(ScrollPattern.Pattern, out var pattern) ||
                    pattern is not ScrollPattern scroll || !scroll.Current.VerticallyScrollable)
                    continue;

                var info = scroll.Current;
                if (info.VerticalScrollPercent >= 99.9)
                    return false;
                double viewportPercent = info.VerticalViewSize;
                if (viewportPercent <= 0 || viewportPercent >= 100)
                {
                    scroll.Scroll(ScrollAmount.NoAmount, ScrollAmount.SmallIncrement);
                    return true;
                }
                double percentage = 100 * viewportPercent * fraction / (100 - viewportPercent);
                scroll.SetScrollPercent(ScrollPattern.NoScroll, Math.Min(100, info.VerticalScrollPercent + percentage));
                return true;
            }
        }
        catch (Exception e) when (e is ElementNotAvailableException or COMException or InvalidOperationException)
        {
        }
        return false;
    }

    private void PauseAutomatic(string? message)
    {
        auto = false;
        pendingAutomaticFrame = false;
        stationaryFrames = 0;
        autoScroll.Content = "自动滚动";
        if (message != null)
            Status(message);
    }

    private void Complete()
    {
        if (stitcher == null || finished || finalizing)
            return;
        finalizing = true;
        timer.Stop();
        PauseAutomatic("正在生成长图…");
        complete.IsEnabled = false;
        if (!processing)
            FinishImage();
    }

    private void FinishImage()
    {
        if (stitcher == null || finished)
            return;
        try
        {
            var output = ToBitmap(stitcher.Render());
            Close();
            finish(output);
        }
        catch (Exception error)
        {
            if (!finished)
            {
                finalizing = false;
                complete.IsEnabled = true;
                Status($"无法生成长图：{error.Message}", warning: true);
                timer.Start();
            }
        }
    }

    private ScrollFrame ReadFrame()
    {
        // A GDI capture can show a black area under an excluded overlapping window.
        bool hide = Native.IsWindowVisible(hwnd) && Native.GetWindowRect(hwnd, out var live) &&
                    live.Rectangle.IntersectsWith(selection);
        if (hide)
        {
            Native.ShowWindow(hwnd, 0);
            Desktop.Flush();
        }
        try
        {
            var bitmap = capture(selection);
            if (bitmap.Format != PixelFormats.Bgra32)
                bitmap = new FormatConvertedBitmap(bitmap, PixelFormats.Bgra32, null, 0);
            if ((long)bitmap.PixelWidth * bitmap.PixelHeight > 64_000_000)
                throw new InvalidOperationException("选区超过 6400 万像素。");

            var frame = new ScrollFrame(bitmap.PixelWidth, bitmap.PixelHeight,
                new byte[checked(bitmap.PixelWidth * bitmap.PixelHeight * 4)]);
            bitmap.CopyPixels(frame.Pixels, frame.Stride, 0);
            return frame;
        }
        finally
        {
            if (hide)
                Native.ShowWindow(hwnd, 4);
        }
    }

    private static BitmapSource ToBitmap(ScrollFrame frame)
    {
        var bitmap = BitmapSource.Create(frame.Width, frame.Height, 96, 96, PixelFormats.Bgra32,
            null, frame.Pixels, frame.Stride);
        bitmap.Freeze();
        return bitmap;
    }

    private void LayoutPreview()
    {
        if (image.Source is not BitmapSource value || stitcher == null) return;
        image.Width = Math.Max(1, scroll.ViewportWidth - 1);
        image.Height = image.Width * value.PixelHeight / value.PixelWidth;
        imageLayer.Width = image.Width;
        imageLayer.Height = image.Height;
        if (viewport is not { } view) return;

        double scale = image.Width / stitcher.Width;
        liveViewport.Width = view.Width * scale;
        liveViewport.Height = view.Height * scale;
        liveViewport.Margin = new Thickness((view.X - selection.X) * scale,
            (view.Y - selection.Y + stitcher.AddedRows) * scale, 0, 0);
        liveViewport.HorizontalAlignment = HorizontalAlignment.Left;
        liveViewport.VerticalAlignment = VerticalAlignment.Top;
        liveViewport.Visibility = Visibility.Visible;
    }

    private void UpdatePreview(BitmapSource bitmap, int width, int height)
    {
        bool atBottom = scroll.ScrollableHeight - scroll.VerticalOffset < 3;
        image.Source = bitmap;
        dimensions.Text = $"{width:N0} × {height:N0} 像素";
        LayoutPreview();
        if (atBottom && stitcher?.AddedRows > 0)
            Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(scroll.ScrollToBottom));
    }

    private void Status(string message, bool warning = false)
    {
        status.Text = message;
        status.Foreground = warning
            ? SnapTheme.Brush(SnapTheme.IsDark ? 0xffc975u : 0x89550c)
            : SnapPalette.For(SnapTheme.IsDark).Muted;
    }

    private void PlaceWindow()
    {
        if (!Native.GetWindowRect(hwnd, out var frame))
            return;
        int width = frame.Rectangle.Width;
        int height = frame.Rectangle.Height;
        PixelRect best = default;
        long minOverlap = long.MaxValue;
        var monitors = System.Windows.Forms.Screen.AllScreens.OrderByDescending(screen => Overlap(screen.Bounds, selection));
        foreach (var monitor in monitors)
        {
            var work = monitor.WorkingArea;
            int left = work.Left + 12, top = work.Top + 12;
            int right = Math.Max(left, work.Right - width - 12);
            int bottom = Math.Max(top, work.Bottom - height - 12);
            foreach (int x in new[] { right, left })
                foreach (int y in new[] { bottom, top })
                {
                    var candidate = new PixelRect(x, y, width, height);
                    long area = Overlap(candidate, selection);
                    if (area < minOverlap)
                    {
                        minOverlap = area;
                        best = candidate;
                    }
                }
        }
        if (minOverlap != long.MaxValue)
            Desktop.Place(this, best, keepSize: true);
    }

    private static long Overlap(PixelRect first, PixelRect second)
    {
        var overlap = PixelRect.Intersect(first, second);
        return (long)overlap.Width * overlap.Height;
    }

    private bool OverPanel(Native.Point point) => Native.GetWindowRect(hwnd, out var bounds) &&
        bounds.Rectangle.Contains(point.X, point.Y);

    private bool OverPanel(WinPoint point) => OverPanel(new Native.Point { X = (int)point.X, Y = (int)point.Y });

    private static WinButton Button(string label, Action action)
    {
        var button = new WinButton { Content = label, Margin = new Thickness(4), Padding = new Thickness(7, 3, 7, 3) };
        button.Click += (_, _) => action();
        return button;
    }

    public static FrameworkElement SettingsContent(Settings settings)
    {
        var panel = new StackPanel();
        var rows = SettingsLayout.Group(panel, "自动滚动");
        SettingsLayout.Toggle(rows, "识别滚动区域后自动滚动", settings.LongShotAutoScroll, value =>
        {
            settings.LongShotAutoScroll = value;
            settings.Save();
        });
        SettingsLayout.Slider(rows, "滚动步长", 1, 10_000, settings.LongShotStepPixels, 1, v => settings.LongShotStepPixels = (int)v, settings.Save, " px");
        SettingsLayout.Slider(rows, "滚动间隔", 300, 5000, settings.LongShotIntervalMilliseconds, 50, v => settings.LongShotIntervalMilliseconds = (int)v, settings.Save, " ms");
        SettingsLayout.Slider(rows, "保留重叠", 35, 90, Math.Round(100 * settings.LongShotOverlap), 1, v => settings.LongShotOverlap = v / 100d, settings.Save, "%");
        return panel;
    }

    private sealed record ScrollTarget(PixelRect Bounds, WinPoint Point);

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct Point { public int X; public int Y; }

        [StructLayout(LayoutKind.Sequential)]
        internal struct Rect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
            public readonly PixelRect Rectangle => PixelRect.FromLTRB(Left, Top, Right, Bottom);
        }

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr window, out Rect bounds);
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out Point point);
        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")]
        public static extern IntPtr WindowFromPoint(Point point);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    }
}

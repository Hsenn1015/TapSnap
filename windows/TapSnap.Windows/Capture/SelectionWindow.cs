using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using DrawingRect = System.Drawing.Rectangle;
using DrawingPoint = System.Drawing.Point;

namespace TapSnap.Windows;

internal sealed record Selection(BitmapSource Image, DrawingRect ScreenRegion, CaptureAction Action)
{
    public DateTime CapturedAt { get; init; } = DateTime.Now;
    public AnnotationTool? InitialTool { get; init; }
    public bool RequiresPrivacy { get; init; }
}

internal sealed class SelectionWindow : Window
{
    private readonly BitmapSource screenshot;
    private readonly DrawingRect monitor;
    private readonly CaptureAction action;
    private readonly bool windowsOnly;
    private readonly Settings settings;
    private readonly CaptureSession session;
    private readonly Canvas canvas = new() { Background = Brushes.Transparent };
    private readonly Path shade = new() { Fill = SnapTheme.Brush(0, 89), IsHitTestVisible = false };
    private readonly SelectionBorder border;
    private readonly TextBlock dimensions = new() { Foreground = Brushes.White, FontSize = 11 };
    private readonly TextBlock hex = new() { Foreground = Brushes.White, FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Border tag;
    private readonly Border toolbar;
    private readonly Panel buttons;
    private readonly SnapPalette palette;
    private readonly bool copyOnConfirm;
    private (int Slots, bool SingleScreen)? dockLayout;
    private bool ShowsEditorDock => action is CaptureAction.Edit or CaptureAction.Privacy;
    private readonly Border lens;
    private readonly Image zoomed = new() { Width = 100, Height = 100, Stretch = Stretch.Fill };
    private readonly byte[] pixel = new byte[4];
    private DrawingPoint? start;
    private DrawingRect? region;
    private DrawingRect? original;
    private IntPtr selectedWindow;
    private int handle = -1;
    private bool locked;
    private bool showsToolbar = true;
    private bool CanSpan => !windowsOnly && action is not (CaptureAction.LongShot or CaptureAction.Record);
    private bool closed;
    private int snapGeneration;

    private SelectionWindow(DrawingRect monitor, BitmapSource screenshot, CaptureAction action, bool windowsOnly,
        Settings settings, CaptureSession session, bool preset)
    {
        this.monitor = monitor;
        this.screenshot = screenshot;
        this.action = action;
        this.windowsOnly = windowsOnly;
        this.settings = settings;
        this.session = session;
        copyOnConfirm = action == CaptureAction.Edit && !preset;
        palette = SnapPalette.For(settings.DarkTheme);
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Cursor = Cursors.Cross;
        Background = Brushes.Black;
        Content = canvas;
        Focusable = true;
        WindowStartupLocation = WindowStartupLocation.Manual;

        var image = new Image { Source = screenshot, Stretch = Stretch.Fill, IsHitTestVisible = false };
        canvas.Children.Add(image);
        canvas.Children.Add(shade);
        border = new SelectionBorder(settings.SelectionBorder);
        canvas.Children.Add(border);

        tag = Badge(dimensions);
        tag.IsHitTestVisible = false;
        canvas.Children.Add(tag);
        buttons = ShowsEditorDock ? new StackPanel { Orientation = Orientation.Horizontal } : new WrapPanel();
        toolbar = Badge(buttons);
        toolbar.CornerRadius = new CornerRadius(9);
        if (ShowsEditorDock)
        {
            toolbar.Height = 44;
            toolbar.Padding = new Thickness(6, 0, 6, 0);
            toolbar.Background = palette.EditorChrome;
            toolbar.BorderBrush = palette.Border;
            toolbar.BorderThickness = new Thickness(1);
            AutomationProperties.SetName(toolbar, "标注工具栏");
        }
        else
        {
            buttons.Children.Add(Choice("取消 ⎋", "取消框选 Esc", null));
            buttons.Children.Add(Choice(action switch
            {
                CaptureAction.Record => "开始录屏", CaptureAction.LongShot => "开始长截图",
                CaptureAction.Pin => "贴图 ↵", _ => "确认 ↵"
            }, "确认当前选区 ↵", action, primary: true));
            toolbar.Padding = new Thickness(6, 4, 6, 4);
            toolbar.Background = SnapTheme.Brush(0, 204);
        }
        toolbar.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 14, ShadowDepth = 2, Direction = 270, Opacity = .27 };
        toolbar.Cursor = Cursors.Arrow;
        toolbar.MouseLeftButtonDown += (_, e) => e.Handled = true;
        canvas.Children.Add(toolbar);

        var zoomGrid = new Grid();
        zoomGrid.Children.Add(zoomed);
        var crosshair = SelectionBorder.BrushFor(0xff453a, .85);
        zoomGrid.Children.Add(new Border { Width = 1, Background = crosshair, HorizontalAlignment = HorizontalAlignment.Center });
        zoomGrid.Children.Add(new Border { Height = 1, Background = crosshair, VerticalAlignment = VerticalAlignment.Center });
        var samples = new StackPanel();
        samples.Children.Add(new Border { Child = zoomGrid, BorderThickness = new Thickness(1), BorderBrush = Brushes.White });
        samples.Children.Add(hex);
        lens = Badge(samples);
        lens.IsHitTestVisible = false;
        RenderOptions.SetBitmapScalingMode(zoomed, BitmapScalingMode.NearestNeighbor);
        canvas.Children.Add(lens);

        SourceInitialized += (_, _) =>
        {
            Desktop.Place(this, monitor);
            var handle = new WindowInteropHelper(this).Handle;
            HwndSource.FromHwnd(handle)?.AddHook(ActivateOnClick);
        };
        Loaded += (_, _) => { Desktop.Place(this, monitor); Update(); };
        SizeChanged += (_, _) =>
        {
            image.Width = border.Width = ActualWidth;
            image.Height = border.Height = ActualHeight;
            Update();
        };
        Closed += (_, _) => { closed = true; session.End(); };
        canvas.MouseLeftButtonDown += Begin;
        canvas.MouseMove += Move;
        canvas.MouseLeftButtonUp += End;
        canvas.LostMouseCapture += (_, _) =>
        {
            if (!start.HasValue) return;
            start = null;
            region = original;
            original = null;
            locked = region.HasValue;
            PublishSelection();
        };
        canvas.MouseLeave += (_, _) => { lens.Visibility = Visibility.Collapsed; };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { e.Handled = true; session.End(); return; }
            if (start.HasValue || session.Finishing) return;
            var operation = ShowsEditorDock ? OperationShortcut.Match(Shortcuts.FromEvent(e), settings.OperationHotkeys) : null;
            if (locked && region.HasValue && operation?.Tool is { } tool)
            {
                e.Handled = true;
                if (!e.IsRepeat) _ = Finish(CaptureAction.Edit, tool);
                return;
            }
            CaptureAction? output = operation?.Output;
            if (output is null && e.Key != Key.Enter) return;
            e.Handled = true;
            if (region.HasValue && (output is null || !e.IsRepeat)) _ = Finish(output ?? action);
            else if (region is null && output is null) session.End();
        };
    }

    private static IntPtr ActivateOnClick(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != 0x0021) return IntPtr.Zero; // WM_MOUSEACTIVATE
        handled = true;
        return new IntPtr(1); // MA_ACTIVATE also delivers the initiating mouse press.
    }

    private sealed class CaptureSession
    {
        public readonly DispatcherFrame Frame = new();
        public readonly List<SelectionWindow> Windows = [];
        public DrawingRect Bounds;
        public readonly DateTime CapturedAt = DateTime.Now;
        public Selection? Result;
        public bool Finishing;
        public bool Ended;

        public void End()
        {
            Ended = true;
            Frame.Continue = false;
        }

        public void ClearOthers(SelectionWindow owner)
        {
            foreach (var window in Windows)
            {
                if (window == owner) continue;
                window.region = null;
                window.locked = false;
                window.snapGeneration++;
                window.Update();
            }
        }
    }

    public static Selection? Select(CaptureAction action, Settings settings, bool windowsOnly = false, bool preset = false)
    {
        var session = new CaptureSession();
        var screens = Desktop.Monitors();
        if (screens.Count == 0) return null;
        session.Bounds = screens.Select(screen => screen.Bounds).Aggregate(DrawingRect.Union);
        var images = Desktop.CaptureDesktop(screens.Select(screen => screen.Bounds).ToArray(), settings.HideDesktopIcons);
        try
        {
            for (int i = 0; i < screens.Count; i++)
                session.Windows.Add(new SelectionWindow(screens[i].Bounds, images[i], action, windowsOnly, settings, session, preset));
            if (session.Windows.Count == 0) return null;
            foreach (var window in session.Windows) window.Show();
            var active = session.Windows.FirstOrDefault(w => w.monitor.Contains(Desktop.Cursor)) ?? session.Windows[0];
            active.Activate();
            Keyboard.Focus(active);
            Dispatcher.PushFrame(session.Frame);
            return session.Result;
        }
        finally
        {
            foreach (var window in session.Windows)
                if (!window.closed) window.Close();
        }
    }

    private void Begin(object sender, MouseButtonEventArgs args)
    {
        if (session.Finishing) return;
        Activate();
        Keyboard.Focus(this);
        session.ClearOthers(this);
        showsToolbar = true;
        snapGeneration++;
        var pointer = Desktop.Cursor;
        if (args.ClickCount == 2 && locked && region?.Contains(pointer) == true)
        {
            _ = Finish(action);
            args.Handled = true;
            return;
        }
        if (windowsOnly)
        {
            SnapWindow(pointer);
            locked = region.HasValue;
            Update();
            args.Handled = true;
            return;
        }

        start = pointer;
        handle = locked ? HandleAt(pointer) : -1;
        original = region is { } r && locked && (handle >= 0 || Outline(r).Contains(Local(pointer))) ? r : null;
        if (!original.HasValue)
        {
            region = null;
            selectedWindow = IntPtr.Zero;
        }
        locked = false;
        if (!canvas.CaptureMouse())
        {
            start = null;
            locked = region.HasValue;
        }
        Update();
        args.Handled = true;
    }

    private void Move(object sender, MouseEventArgs args)
    {
        if (session.Finishing) return;
        var pointer = Desktop.Cursor;
        if (start is { } origin)
        {
            UpdateDrag(origin, pointer);
            PublishSelection();
        }
        else if (windowsOnly && !locked)
        {
            SnapWindow(pointer);
            Update();
        }

        canvas.Cursor = (start is null && locked && !windowsOnly ? HandleAt(pointer) : -1) switch
            {
                0 or 4 => Cursors.SizeNWSE,
                2 or 6 => Cursors.SizeNESW,
                1 or 5 => Cursors.SizeNS,
                3 or 7 => Cursors.SizeWE,
                _ => Cursors.Cross
        };
        if (settings.ShowMagnifier && !locked && !windowsOnly && monitor.Contains(pointer))
            ShowMagnifier(pointer);
    }

    private async void End(object sender, MouseButtonEventArgs args)
    {
        if (start is not { } anchor) return;
        var pointer = Desktop.Cursor;
        UpdateDrag(anchor, pointer);
        start = null;
        canvas.ReleaseMouseCapture();
        bool creating = !original.HasValue;
        original = null;
        args.Handled = true;
        int generation = ++snapGeneration;
        double scale = Desktop.ScaleForMonitor(monitor);
        if (creating && Math.Abs(pointer.X - anchor.X) < 4 * scale && Math.Abs(pointer.Y - anchor.Y) < 4 * scale)
        {
            SnapWindow(pointer);
            locked = region.HasValue;
            Update();
            var target = selectedWindow;
            if (target != IntPtr.Zero && region is { } windowBounds)
            {
                var search = Task.Run(() => ElementAt(target, pointer, windowBounds));
                var done = await Task.WhenAny(search, Task.Delay(300));
                if (done == search && !closed && !session.Ended && generation == snapGeneration && await search is { } element)
                {
                    region = element;
                    locked = true;
                    Update();
                }
            }
        }
        else
        {
            locked = region.HasValue;
            PublishSelection();
        }
    }

    private void PublishSelection()
    {
        if (!CanSpan) { Update(); return; }
        var owner = session.Windows.FirstOrDefault(w => w.monitor.Contains(Desktop.Cursor)) ?? this;
        foreach (var window in session.Windows)
        {
            if (window != this)
            {
                window.region = region is { } rect && window.monitor.IntersectsWith(rect) ? rect : null;
                window.locked = locked && window.region.HasValue;
            }
            window.showsToolbar = window == owner;
            window.Update();
        }
    }

    private void UpdateDrag(DrawingPoint origin, DrawingPoint pointer)
    {
        var bounds = CanSpan ? session.Bounds : monitor;
        if (original is { } initial)
        {
            int dx = pointer.X - origin.X, dy = pointer.Y - origin.Y;
            region = handle >= 0 ? SelectionGeometry.Resize(initial, bounds, handle, dx, dy)
                : SelectionGeometry.Move(initial, bounds, dx, dy);
            return;
        }
        region = SelectionGeometry.Create(origin, pointer, bounds);
    }

    private static DrawingRect? ElementAt(IntPtr window, DrawingPoint point, DrawingRect bounds)
    {
        try
        {
            // FromPoint would return our overlay. Walk the visible descendants of the underlying window instead.
            var walker = TreeWalker.ControlViewWalker;
            var current = AutomationElement.FromHandle(window);
            DrawingRect? best = null;
            long bestArea = (long)bounds.Width * bounds.Height;
            var watch = System.Diagnostics.Stopwatch.StartNew();
            for (int depth = 0; depth < 12 && current is not null && watch.ElapsedMilliseconds < 225; depth++)
            {
                AutomationElement? childAtPoint = null;
                int visited = 0;
                for (var child = walker.GetFirstChild(current); child != null; child = walker.GetNextSibling(child))
                {
                    if (++visited > 140 || watch.ElapsedMilliseconds >= 225) break;
                    var information = child.Current;
                    var box = information.BoundingRectangle;
                    if (information.IsOffscreen || box.IsEmpty || !box.Contains(point.X, point.Y)) continue;
                    var clipped = DrawingRect.Intersect(bounds, DrawingRect.FromLTRB((int)Math.Floor(box.Left),
                        (int)Math.Floor(box.Top), (int)Math.Ceiling(box.Right), (int)Math.Ceiling(box.Bottom)));
                    long area = (long)clipped.Width * clipped.Height;
                    if (clipped.Width <= 4 || clipped.Height <= 4 || area > bestArea) continue;
                    childAtPoint = child;
                    best = clipped;
                    bestArea = area;
                }
                current = childAtPoint;
            }
            return best;
        }
        catch (Exception error) when (error is COMException or InvalidOperationException or ArgumentException or ElementNotAvailableException)
        {
            return null;
        }
    }

    private int HandleAt(DrawingPoint pointer)
    {
        if (region is not { } r) return -1;
        var rim = Outline(r);
        if (rim.IsEmpty) return -1;
        var handles = SelectionBorder.Handles(rim);
        var point = Local(pointer);
        for (int i = 0; i < handles.Length; i++)
            if (Math.Abs(handles[i].X - point.X) <= 7 && Math.Abs(handles[i].Y - point.Y) <= 7) return i;
        return -1;
    }

    private void SnapWindow(DrawingPoint pointer)
    {
        var window = Desktop.WindowUnder(pointer, new WindowInteropHelper(this).Handle);
        region = window is { } match ? DrawingRect.Intersect(monitor, match.Bounds) : null;
        selectedWindow = window?.Handle ?? IntPtr.Zero;
        if (region is not { Width: > 1, Height: > 1 }) region = null;
    }

    private void ShowMagnifier(DrawingPoint pointer)
    {
        int px = pointer.X - monitor.X, py = pointer.Y - monitor.Y;
        const int side = 21;
        int x = Math.Clamp(px - side / 2, 0, Math.Max(0, screenshot.PixelWidth - side));
        int y = Math.Clamp(py - side / 2, 0, Math.Max(0, screenshot.PixelHeight - side));
        zoomed.Source = new CroppedBitmap(screenshot, new Int32Rect(x, y, Math.Min(side, screenshot.PixelWidth), Math.Min(side, screenshot.PixelHeight)));
        screenshot.CopyPixels(new Int32Rect(px, py, 1, 1), pixel, 4, 0);
        hex.Text = $"#{pixel[2]:X2}{pixel[1]:X2}{pixel[0]:X2}";
        var local = Local(pointer);
        Canvas.SetLeft(lens, ClampPosition(local.X + 24 + 104 <= ActualWidth - 8 ? local.X + 24 : local.X - 128, ActualWidth, 104));
        Canvas.SetTop(lens, ClampPosition(local.Y + 24 + 120 <= ActualHeight - 8 ? local.Y + 24 : local.Y - 144, ActualHeight, 120));
        lens.Visibility = Visibility.Visible;
    }

    private void Update()
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        var full = new Rect(0, 0, ActualWidth, ActualHeight);
        tag.Visibility = toolbar.Visibility = Visibility.Collapsed;
        if (locked || windowsOnly) lens.Visibility = Visibility.Collapsed;
        if (region is not { } r)
        {
            shade.Data = new RectangleGeometry(full);
            border.Update(Rect.Empty, false);
            return;
        }

        var rect = new Rect(Local(new DrawingPoint(r.Left, r.Top)), Local(new DrawingPoint(r.Right, r.Bottom)));
        var rim = Outline(r);
        shade.Data = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(full), new RectangleGeometry(rect));
        border.Update(rim, locked && !windowsOnly);
        dimensions.Text = $"{r.Width:N0} × {r.Height:N0}";
        if (rim.IsEmpty) rim = rect;
        if (settings.ShowSelectionSize && showsToolbar)
        {
            tag.Visibility = Visibility.Visible;
            tag.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(tag, ClampPosition(rim.Left, ActualWidth, tag.DesiredSize.Width));
            Canvas.SetTop(tag, ClampPosition(rim.Top - 24, ActualHeight, tag.DesiredSize.Height));
        }
        if (!locked || !showsToolbar) return;
        rim.Intersect(full);
        if (rim.IsEmpty) return;
        Rect available = full;
        if (ShowsEditorDock)
        {
            var work = System.Windows.Forms.Screen.FromRectangle(monitor).WorkingArea;
            available = new Rect(Local(work.Location), Local(new DrawingPoint(work.Right, work.Bottom)));
            double limit = Math.Min(available.Width - 16, Math.Max(rim.Width, 44 * 9));
            UpdateDock(SelectionToolbarModel.Slots(limit), monitor.Contains(r));
        }
        else buttons.MaxWidth = Math.Max(1, ActualWidth - 28);
        toolbar.Visibility = Visibility.Visible;
        toolbar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double height = toolbar.DesiredSize.Height;
        double top = rim.Bottom + 10;
        if (top + height > available.Bottom - 8)
        {
            double above = rim.Top - height - (settings.ShowSelectionSize ? 28 : 10);
            top = !ShowsEditorDock && above >= available.Top + 8 ? above : rim.Bottom - height - 10;
        }
        Canvas.SetLeft(toolbar, available.Left + ClampPosition(rim.Left + (rim.Width - toolbar.DesiredSize.Width) / 2 - available.Left,
            available.Width, toolbar.DesiredSize.Width));
        Canvas.SetTop(toolbar, available.Top + ClampPosition(top - available.Top, available.Height, height));
    }

    private void UpdateDock(int slots, bool singleScreen)
    {
        if (dockLayout == (slots, singleScreen)) return;
        dockLayout = (slots, singleScreen);
        buttons.Children.Clear();
        var layout = SelectionToolbarModel.Layout(slots, singleScreen, copyOnConfirm, settings.SelectionToolbarActions);
        Button Add(string title, string symbol, Action run, string? shortcut = null)
        {
            var button = ToolbarGlyph.CreateButton(title, symbol, palette, shortcut);
            button.Click += (_, _) => run();
            buttons.Children.Add(button);
            return button;
        }
        void Choose(ToolbarItem item) => _ = Finish(item.Action, item.Tool);
        string? Shortcut(ToolbarItem item)
        {
            var operation = item.Tool is { } tool ? OperationShortcut.ForTool(tool) : OperationShortcut.ForOutput(item.Action);
            return operation?.Binding(settings.OperationHotkeys) is { } key ? Shortcuts.Display(key) : null;
        }
        foreach (var item in layout.Tools) Add(item.Title, item.Symbol, () => Choose(item), Shortcut(item));
        if (layout.Tools.Length > 0) buttons.Children.Add(ToolbarGlyph.Divider(palette));
        foreach (var item in layout.Outputs) Add(item.Title, item.Symbol, () => Choose(item), Shortcut(item));
        var more = ToolbarGlyph.CreateButton("更多工具与操作", "⌄", palette);
        more.Click += (_, _) =>
        {
            var menu = new ContextMenu { PlacementTarget = more, Placement = PlacementMode.Top,
                Background = palette.Panel, Foreground = palette.Foreground, BorderBrush = palette.Border };
            foreach (var item in layout.More)
            {
                var entry = new MenuItem { Header = item.Title, Icon = ToolbarGlyph.Make(item.Symbol),
                    InputGestureText = Shortcut(item) ?? "" };
                entry.Click += (_, _) => Choose(item);
                menu.Items.Add(entry);
            }
            menu.IsOpen = true;
        };
        buttons.Children.Add(more);
        buttons.Children.Add(ToolbarGlyph.Divider(palette));
        Add("取消框选 Esc", "×", session.End);
        var title = copyOnConfirm ? Shortcuts.WithHint(RecognitionService.ShouldScanAutomatically ? "检查后复制" : "复制",
            OperationShortcut.Copy.Binding(settings.OperationHotkeys) is { } copyKey ? Shortcuts.Display(copyKey) : null) : "编辑 ↵";
        var confirm = Add(title, "✓", () => _ = Finish(copyOnConfirm ? CaptureAction.Copy : action));
        confirm.Background = palette.Primary;
        confirm.Foreground = palette.PrimaryForeground;
    }

    private async Task Finish(CaptureAction act, AnnotationTool? initialTool = null)
    {
        if (session.Finishing || session.Ended || region is not { Width: > 0, Height: > 0 } rect) return;
        session.Finishing = true;
        buttons.IsEnabled = false;
        border.Opacity = .65;
        if (act != CaptureAction.Copy && SystemParameters.ClientAreaAnimation) await Task.Delay(65);
        if (session.Ended) return;

        try
        {
            BitmapSource image;
            if (windowsOnly && selectedWindow != IntPtr.Zero)
            {
                foreach (var window in session.Windows) window.Hide();
                Desktop.Flush();
                var native = await GraphicsCapture.WindowAsync(selectedWindow);
                if (session.Ended) return;
                image = native is not null && native.PixelWidth == rect.Width && native.PixelHeight == rect.Height
                    ? native : Desktop.CaptureWindow(selectedWindow, rect);
            }
            else if (monitor.Contains(rect))
            {
                var area = SelectionGeometry.OffsetToImage(rect, monitor);
                var crop = new CroppedBitmap(screenshot, new Int32Rect(area.X, area.Y, area.Width, area.Height));
                crop.Freeze();
                image = crop;
            }
            else
            {
                var visual = new DrawingVisual();
                using (var drawing = visual.RenderOpen())
                    foreach (var window in session.Windows.Where(w => w.monitor.IntersectsWith(rect)))
                        drawing.DrawImage(window.screenshot, new Rect(window.monitor.X - rect.X, window.monitor.Y - rect.Y,
                            window.monitor.Width, window.monitor.Height));
                var combined = new RenderTargetBitmap(rect.Width, rect.Height, 96, 96, PixelFormats.Pbgra32);
                combined.Render(visual);
                combined.Freeze();
                image = combined;
            }
            session.Result = new Selection(image, rect, act) { CapturedAt = session.CapturedAt,
                InitialTool = initialTool, RequiresPrivacy = action == CaptureAction.Privacy || initialTool == AnnotationTool.Privacy };
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "截图失败", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        session.End();
    }

    private Point Local(DrawingPoint p) => new((p.X - monitor.X) * ActualWidth / monitor.Width,
        (p.Y - monitor.Y) * ActualHeight / monitor.Height);

    private Rect Outline(DrawingRect r)
    {
        var rect = new Rect(Local(new DrawingPoint(r.Left, r.Top)), Local(new DrawingPoint(r.Right, r.Bottom)));
        if (monitor.Contains(r)) return SelectionBorder.Outline(rect, new Rect(0, 0, ActualWidth, ActualHeight));
        rect.Inflate(8, 8);
        return rect;
    }

    private static double ClampPosition(double value, double extent, double size) =>
        Math.Clamp(value, 8, Math.Max(8, extent - size - 8));

    private Button Choice(string title, string help, CaptureAction? act, bool primary = false)
    {
        var scale = new ScaleTransform(1, 1);
        var button = new Button
        {
            Content = title, Width = 64, Height = 32, Margin = new Thickness(2, 0, 2, 0),
            Foreground = Brushes.White, FontSize = 12, FontWeight = primary ? FontWeights.SemiBold : FontWeights.Normal,
            ToolTip = help, Cursor = Cursors.Hand, Focusable = false, Tag = act,
            Background = primary ? SelectionBorder.BrushFor(0x007aff) : Brushes.Transparent,
            RenderTransform = scale, RenderTransformOrigin = new Point(.5, .5)
        };
        var surface = new FrameworkElementFactory(typeof(Border)) { Name = "Surface" };
        surface.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        surface.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(BackgroundProperty));
        var label = new FrameworkElementFactory(typeof(ContentPresenter));
        label.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        label.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        surface.AppendChild(label);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = surface };
        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(Border.BackgroundProperty,
            SelectionBorder.BrushFor(primary ? 0x278fffu : 0xffffffu, primary ? 1 : .14), "Surface"));
        template.Triggers.Add(hover);
        var pressed = new Trigger { Property = System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty, Value = true };
        pressed.Setters.Add(new Setter(Border.BackgroundProperty,
            SnapTheme.Brush(primary ? 0x005fc8u : 0xffffffu, primary ? (byte)255 : (byte)66), "Surface"));
        template.Triggers.Add(pressed);
        button.Template = template;
        ToolTipService.SetInitialShowDelay(button, 320);
        void Animate(double value, double milliseconds)
        {
            if (!SystemParameters.ClientAreaAnimation) return;
            var time = TimeSpan.FromMilliseconds(milliseconds);
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(value, time));
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(value, time));
        }
        button.PreviewMouseLeftButtonDown += (_, _) => Animate(.94, 70);
        button.PreviewMouseLeftButtonUp += (_, _) => Animate(1, 130);
        button.LostMouseCapture += (_, _) => Animate(1, 130);
        button.Click += async (_, _) =>
        {
            if (act is not { } selected) { session.End(); return; }
            button.Content = "处理中…";
            await Finish(selected);
        };
        return button;
    }

    private static Border Badge(UIElement content) => new()
    {
        Background = SnapTheme.Brush(0, 153), Padding = new Thickness(4, 2, 4, 2),
        CornerRadius = new CornerRadius(4), Child = content, Visibility = Visibility.Collapsed
    };
}

internal sealed class RelayCommand(Action run) : ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => run();
}

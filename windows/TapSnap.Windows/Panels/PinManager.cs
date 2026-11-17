using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using DrawingRect = System.Drawing.Rectangle;

namespace TapSnap.Windows;

internal sealed record PinInfo(Guid Id, string Group, int X, int Y, double Width, double Height, double Opacity,
    bool Topmost, bool ClickThrough, long ContentBytes = 0, int QuarterTurns = 0, bool FlipHorizontal = false,
    bool FlipVertical = false);

internal sealed record PinPreferences(bool DoubleClickToClose = false, bool Shadow = true, bool Snap = true,
    bool HideInFullscreen = false, bool DefaultTopmost = true, double DefaultOpacity = 1);

internal sealed class PinManager
{
    private const long MaximumContentBytes = 512L * 1024 * 1024;
    private readonly string folder = Path.Combine(Settings.DirectoryPath, "Pins");
    private readonly List<PinInfo> closed = [];
    private readonly List<PinWindow> open = [];
    private readonly HashSet<string> groups = ["默认"];
    private readonly HashSet<string> hiddenGroups = [];
    private readonly DispatcherTimer fullscreenMonitor = new() { Interval = TimeSpan.FromMilliseconds(750) };
    private PinPreferences preferences = new();
    private Window? groupWindow;
    private bool allHidden;
    private bool otherAppFullscreen;
    private bool quitting;

    public PinManager()
    {
        fullscreenMonitor.Tick += (_, _) =>
        {
            bool fullscreen = IsOtherForegroundFullscreen();
            if (fullscreen == otherAppFullscreen) return;
            otherAppFullscreen = fullscreen;
            RefreshVisibility();
        };
        try
        {
            var file = Path.Combine(folder, "index.json");
            if (!File.Exists(file)) return;
            var store = JsonSerializer.Deserialize<PinStore>(File.ReadAllText(file));
            if (store == null) return;
            preferences = store.Preferences ?? new PinPreferences();
            allHidden = store.AllHidden;
            foreach (string group in store.Groups) groups.Add(group);
            if (store.HiddenGroups is { } hidden) hiddenGroups.UnionWith(hidden);
            foreach (var pin in store.Closed.Take(20))
                if (TryRead(pin, out var saved, out _)) closed.Add(saved);
            long closedBytes = closed.Sum(item => item.ContentBytes);
            while (closedBytes > MaximumContentBytes) closedBytes -= RemoveOldestClosed();
            foreach (var pin in store.Open.Take(40))
                if (TryRead(pin, out var saved, out var image))
                {
                    MakeRoom(saved.ContentBytes);
                    Show(saved, image);
                }
            StartFullscreenMonitor();
            RefreshVisibility();
            Save();
        }
        catch (IOException) { }
        catch (JsonException) { }
    }

    public void Add(BitmapSource image)
    {
        var bytes = ContentBytes(image);
        Directory.CreateDirectory(folder);
        var cursor = Desktop.Cursor;
        double fit = Math.Min(1, Math.Min(680d / image.PixelWidth, 540d / image.PixelHeight));
        var item = new PinInfo(Guid.NewGuid(), "默认", cursor.X, cursor.Y, Math.Max(32, image.PixelWidth * fit),
            Math.Max(32, image.PixelHeight * fit), preferences.DefaultOpacity, preferences.DefaultTopmost, false, bytes);
        if (bytes <= MaximumContentBytes) Images.Save(image, PathFor(item.Id));
        MakeRoom(bytes);
        Show(item, image);
        Save();
    }

    public void Toggle()
    {
        allHidden = !allHidden;
        RefreshVisibility();
        Save();
    }

    public bool Restore()
    {
        if (closed.Count == 0 || open.Count >= 40) return false;
        PinInfo info;
        BitmapSource image;
        while (!TryRead(closed[0], out info, out image))
        {
            closed.RemoveAt(0);
            if (closed.Count != 0) continue;
            Save();
            return false;
        }
        closed.RemoveAt(0);
        MakeRoom(info.ContentBytes);
        Show(info with { ClickThrough = false }, image);
        allHidden = false;
        hiddenGroups.Remove(info.Group);
        RefreshVisibility();
        Save();
        return true;
    }

    public void Groups()
    {
        if (groupWindow is { } existing) { existing.Activate(); return; }
        var window = new Window { Title = "贴图分组", Width = 485, Height = 465, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        SnapTheme.StyleWindow(window);
        groupWindow = window;
        window.Closed += (_, _) => groupWindow = null;
        var body = new DockPanel { Margin = new Thickness(12) };
        var groupActions = new WrapPanel { Margin = new Thickness(0, 0, 0, 6) };
        DockPanel.SetDock(groupActions, Dock.Top);
        body.Children.Add(groupActions);
        var name = new TextBox { Width = 135, Margin = new Thickness(2), VerticalContentAlignment = VerticalAlignment.Center };
        groupActions.Children.Add(name);
        groupActions.Children.Add(RecordingWindow.Button("贴图设置…", () => ShowOptions(window)));
        var rows = new StackPanel();
        void Refresh()
        {
            rows.Children.Clear();
            foreach (string group in groups.OrderBy(g => g))
            {
                var heading = new WrapPanel();
                var pins = open.Where(p => p.Info.Group == group).ToList();
                heading.Children.Add(new TextBlock { Text = $"{group}  ({pins.Count})", FontWeight = FontWeights.SemiBold, Margin = new Thickness(5) });
                heading.Children.Add(RecordingWindow.Button(hiddenGroups.Contains(group) ? "显示" : "隐藏", () =>
                {
                    if (!hiddenGroups.Remove(group)) hiddenGroups.Add(group);
                    RefreshVisibility();
                    Save();
                    Refresh();
                }));
                if (group != "默认")
                {
                    heading.Children.Add(RecordingWindow.Button("重命名", () =>
                    {
                        var newName = name.Text.Trim();
                        if (newName.Length == 0 || !groups.Add(newName)) return;
                        groups.Remove(group);
                        if (hiddenGroups.Remove(group)) hiddenGroups.Add(newName);
                        foreach (var pin in pins) pin.Info = pin.Info with { Group = newName };
                        RewriteClosedGroup(group, newName);
                        Save();
                        Refresh();
                    }));
                    heading.Children.Add(RecordingWindow.Button("删除", () =>
                    {
                        groups.Remove(group);
                        hiddenGroups.Remove(group);
                        foreach (var pin in pins) pin.Info = pin.Info with { Group = "默认" };
                        RewriteClosedGroup(group, "默认");
                        RefreshVisibility();
                        Save();
                        Refresh();
                    }));
                }
                rows.Children.Add(heading);
                foreach (var pin in pins)
                {
                    var row = new WrapPanel { Margin = new Thickness(15, 0, 0, 4) };
                    row.Children.Add(new Image { Source = pin.Image, Width = 64, Height = 43 });
                    row.Children.Add(RecordingWindow.Button("显示", () => Reveal(pin)));
                    row.Children.Add(RecordingWindow.Button("恢复鼠标交互", () => { pin.SetClickThrough(false); Reveal(pin); }));
                    var move = new ComboBox { ItemsSource = groups.ToArray(), SelectedItem = group, MinWidth = 100, Margin = new Thickness(4) };
                    move.SelectionChanged += (_, _) =>
                    {
                        if (move.SelectedItem is not string dest || dest == pin.Info.Group) return;
                        pin.Info = pin.Info with { Group = dest };
                        RefreshVisibility();
                        Save();
                        Refresh();
                    };
                    row.Children.Add(move);
                    row.Children.Add(RecordingWindow.Button("关闭", () => { pin.Close(); Refresh(); }));
                    rows.Children.Add(row);
                }
            }
        }
        groupActions.Children.Add(RecordingWindow.Button("新建分组", () =>
        {
            if (name.Text.Trim() is { Length: > 0 } text && groups.Add(text)) { Save(); Refresh(); }
        }));
        groupActions.Children.Add(RecordingWindow.Button("清空已关闭", () =>
        {
            if (closed.Count == 0 || MessageBox.Show(window, "清空后将无法恢复这些贴图。", "清空已关闭的贴图",
                    MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
            while (closed.Count > 0) RemoveOldestClosed();
            Save();
        }));
        body.Children.Add(new ScrollViewer { Content = rows });
        window.Content = body;
        Refresh();
        window.Show();
    }

    private void Show(PinInfo info, BitmapSource image)
    {
        var pin = new PinWindow(info, image, preferences);
        open.Add(pin);
        pin.Changed += Save;
        pin.Closed += (_, _) =>
        {
            bool wasManaged = open.Remove(pin);
            if (quitting) return;
            if (!wasManaged) return;
            if (pin.Info.ContentBytes <= MaximumContentBytes)
                closed.Insert(0, pin.Info);
            while (closed.Count > 20) RemoveOldestClosed();
            Save();
        };
        if (ShouldShow(pin)) pin.Show();
    }

    public void Shutdown()
    {
        Save();
        quitting = true;
        fullscreenMonitor.Stop();
    }

    private string PathFor(Guid id) => Path.Combine(folder, id + ".png");

    private static long ContentBytes(BitmapSource image) =>
        (long)image.PixelWidth * image.PixelHeight * Math.Max(4, (image.Format.BitsPerPixel + 7) / 8);

    private bool TryRead(PinInfo info, out PinInfo saved, out BitmapSource image)
    {
        saved = info;
        image = null!;
        if (info.ContentBytes > MaximumContentBytes || !File.Exists(PathFor(info.Id))) return false;
        try
        {
            image = Images.Read(PathFor(info.Id));
            saved = info with { ContentBytes = ContentBytes(image), Group = groups.Contains(info.Group) ? info.Group : "默认" };
            return saved.ContentBytes <= MaximumContentBytes;
        }
        catch (Exception error) when (error is IOException or FileFormatException or NotSupportedException)
        {
            return false;
        }
    }

    private void MakeRoom(long newBytes)
    {
        long total = newBytes + open.Sum(pin => pin.Info.ContentBytes) + closed.Sum(pin => pin.ContentBytes);
        while (closed.Count > 0 && total > MaximumContentBytes)
            total -= RemoveOldestClosed();
        while (open.Count > 0 && (open.Count >= 40 || total > MaximumContentBytes))
        {
            var oldest = open[0];
            total -= oldest.Info.ContentBytes;
            // Evicted windows no longer have a manifest entry or a restorable file.
            open.RemoveAt(0);
            oldest.Close();
            File.Delete(PathFor(oldest.Info.Id));
        }
    }

    private long RemoveOldestClosed()
    {
        var oldest = closed[^1];
        closed.RemoveAt(closed.Count - 1);
        File.Delete(PathFor(oldest.Id));
        return oldest.ContentBytes;
    }

    private void RewriteClosedGroup(string group, string replacement)
    {
        for (int i = 0; i < closed.Count; i++)
            if (closed[i].Group == group)
                closed[i] = closed[i] with { Group = replacement };
    }

    private bool ShouldShow(PinWindow pin) => !allHidden && !hiddenGroups.Contains(pin.Info.Group) &&
                                               !(preferences.HideInFullscreen && otherAppFullscreen);

    private void RefreshVisibility()
    {
        foreach (var pin in open)
        {
            bool visible = ShouldShow(pin);
            if (visible && !pin.IsVisible) pin.Show();
            else if (!visible && pin.IsVisible) pin.Hide();
        }
    }

    private void Reveal(PinWindow pin)
    {
        allHidden = false;
        hiddenGroups.Remove(pin.Info.Group);
        RefreshVisibility();
        if (pin.IsVisible) pin.Activate();
        Save();
    }

    private void ShowOptions(Window owner)
    {
        var panel = PreferencesContent();
        panel.Margin = new Thickness(14);
        var window = new Window
        {
            Owner = owner, Title = "贴图设置", Content = panel, Width = 335, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false
        };
        SnapTheme.StyleWindow(window);
        panel.Children.Add(RecordingWindow.Button("完成", window.Close));
        window.Closed += (_, _) => Save();
        window.ShowDialog();
    }

    public StackPanel PreferencesContent()
    {
        var panel = new StackPanel();
        var rows = SettingsLayout.Group(panel, "行为");
        Option("双击关闭贴图", preferences.DoubleClickToClose, value => preferences with { DoubleClickToClose = value });
        Option("显示阴影", preferences.Shadow, value => preferences with { Shadow = value });
        Option("拖动时吸附到屏幕边缘", preferences.Snap, value => preferences with { Snap = value });
        Option("其他应用全屏时隐藏", preferences.HideInFullscreen, value => preferences with { HideInFullscreen = value });
        Option("默认置顶", preferences.DefaultTopmost, value => preferences with { DefaultTopmost = value });
        SettingsLayout.Slider(SettingsLayout.Group(panel, "外观"), "默认不透明度", 15, 100,
            preferences.DefaultOpacity * 100, 1,
            v => SetPreferences(preferences with { DefaultOpacity = v / 100d }, save: false), Save, "%");
        return panel;

        void Option(string title, bool value, Func<bool, PinPreferences> apply) =>
            SettingsLayout.Toggle(rows, title, value, v => SetPreferences(apply(v)));
    }

    private void SetPreferences(PinPreferences updated, bool save = true)
    {
        var previous = preferences;
        preferences = updated;
        foreach (var pin in open)
            pin.UpdatePreferences(previous, updated);
        StartFullscreenMonitor();
        RefreshVisibility();
        if (save) Save();
    }

    private void StartFullscreenMonitor()
    {
        if (preferences.HideInFullscreen)
        {
            otherAppFullscreen = IsOtherForegroundFullscreen();
            fullscreenMonitor.Start();
        }
        else
        {
            fullscreenMonitor.Stop();
            otherAppFullscreen = false;
        }
    }

    private static bool IsOtherForegroundFullscreen()
    {
        IntPtr window = GetForegroundWindow();
        if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out uint process) == 0 || process == Environment.ProcessId)
            return false;
        if (DwmGetWindowAttribute(window, 9, out var rect, Marshal.SizeOf<ForegroundRect>()) != 0)
            return false;
        if (rect.Right - rect.Left < 1 || rect.Bottom - rect.Top < 1) return false;
        var foreground = DrawingRect.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
        var screen = System.Windows.Forms.Screen.FromRectangle(foreground);
        var bounds = screen.Bounds;
        if (Math.Abs(bounds.Left - foreground.Left) > 2 || Math.Abs(bounds.Top - foreground.Top) > 2 ||
            Math.Abs(bounds.Right - foreground.Right) > 2 || Math.Abs(bounds.Bottom - foreground.Bottom) > 2)
            return false;
        // A normal maximized overlapped window can cover the work area when the taskbar auto-hides.
        return (GetWindowLongW(window, -16) & 0x00C00000) == 0 || screen.WorkingArea != bounds;
    }

    private void Save()
    {
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, "index.json");
        var snapshot = new PinStore(open.Select(p => p.Info).Where(p => p.ContentBytes <= MaximumContentBytes).ToArray(),
            closed.ToArray(), groups.ToArray(), hiddenGroups.ToArray(), allHidden, preferences);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(snapshot));
        File.Move(path + ".tmp", path, true);
    }

    private sealed record PinStore(PinInfo[] Open, PinInfo[] Closed, string[] Groups,
        string[]? HiddenGroups = null, bool AllHidden = false, PinPreferences? Preferences = null);

    [StructLayout(LayoutKind.Sequential)] private struct ForegroundRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out ForegroundRect rect, int size);
    [DllImport("user32.dll")] private static extern int GetWindowLongW(IntPtr window, int index);
}

internal sealed class PinWindow : Window
{
    public PinInfo Info { get; set; }
    public BitmapSource Image { get; private set; }
    public event Action? Changed;
    private readonly BitmapSource original;
    private readonly Border imageFrame;
    private readonly Image imageView;
    private PinPreferences preferences;

    public PinWindow(PinInfo info, BitmapSource image, PinPreferences preferences)
    {
        Info = info;
        this.preferences = preferences;
        original = Image = image;
        Title = "TapSnap 贴图";
        Width = info.Width;
        Height = info.Height;
        MinWidth = MinHeight = 32;
        ShowInTaskbar = false;
        ShowActivated = false;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        Topmost = info.Topmost;
        Opacity = info.Opacity;
        imageView = new Image { Source = image, Stretch = Stretch.Uniform };
        RenderOptions.SetBitmapScalingMode(imageView, BitmapScalingMode.HighQuality);
        imageFrame = new Border { Child = imageView };
        Content = imageFrame;
        UpdateShadow();
        ApplyImageTransform();
        SourceInitialized += (_, _) =>
        {
            var bounds = new DrawingRect(info.X, info.Y, 1, 1);
            if (!Desktop.Monitors().Any(d => d.Bounds.Contains(bounds.Location))) bounds.Location = Desktop.Cursor;
            Desktop.Place(this, bounds, keepSize: true);
            Desktop.Exclude(this);
            if (Info.ClickThrough) ApplyClickThrough(true);
        };
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2 && this.preferences.DoubleClickToClose) { Close(); return; }
            DragMove();
            var hwnd = new WindowInteropHelper(this).Handle;
            if (GetWindowRect(hwnd, out var frame))
            {
                var monitor = Desktop.CursorMonitor;
                int x = frame.Left, y = frame.Top;
                if (this.preferences.Snap)
                {
                    if (Math.Abs(x - monitor.Left) < 16) x = monitor.Left;
                    if (Math.Abs(y - monitor.Top) < 16) y = monitor.Top;
                    if (Math.Abs(frame.Right - monitor.Right) < 16) x = monitor.Right - (frame.Right - frame.Left);
                    if (Math.Abs(frame.Bottom - monitor.Bottom) < 16) y = monitor.Bottom - (frame.Bottom - frame.Top);
                    Desktop.Place(this, new DrawingRect(x, y, 1, 1), keepSize: true);
                }
                Info = Info with { X = x, Y = y };
                Changed?.Invoke();
            }
        };
        MouseWheel += (_, e) =>
        {
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
            {
                Opacity = Math.Clamp(Opacity + (e.Delta > 0 ? 0.08 : -0.08), 0.15, 1);
                Info = Info with { Opacity = Opacity };
            }
            else
            {
                double scale = Math.Clamp((e.Delta > 0 ? 1.12 : 1 / 1.12),
                    Math.Min(1, Math.Max(32 / Width, 32 / Height)),
                    Math.Max(1, Math.Min(2800 / Width, 1800 / Height)));
                Width *= scale;
                Height *= scale;
                Info = Info with { Width = Width, Height = Height };
            }
            Changed?.Invoke();
        };
        ContextMenu = new ContextMenu();
        Add("复制", () => Images.Copy(Image));
        Add("保存", () => Images.SaveWithDialog(Image));
        Add("向右旋转", () => Rotate(1));
        Add("向左旋转", () => Rotate(-1));
        Add("水平翻转", () => Flip(horizontal: true));
        Add("垂直翻转", () => Flip(horizontal: false));
        Add("置顶 / 取消置顶", () => { Topmost = !Topmost; Info = Info with { Topmost = Topmost }; Changed?.Invoke(); });
        Add("鼠标穿透", () => SetClickThrough(true));
        Add("关闭", Close);
    }

    public void SetClickThrough(bool value)
    {
        ApplyClickThrough(value);
        Info = Info with { ClickThrough = value };
        Changed?.Invoke();
    }

    private void ApplyClickThrough(bool value)
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        int style = GetWindowLongW(hwnd, -20);
        // WS_EX_TRANSPARENT forwards mouse input to underlying windows for layered windows.
        SetWindowLongW(hwnd, -20, value ? style | 0x20 : style & ~0x20);
    }

    public void UpdatePreferences(PinPreferences previous, PinPreferences updated)
    {
        preferences = updated;
        if (previous.Shadow != updated.Shadow) UpdateShadow();
        if (previous.DefaultTopmost != updated.DefaultTopmost)
        {
            Topmost = updated.DefaultTopmost;
            Info = Info with { Topmost = Topmost };
        }
        if (previous.DefaultOpacity != updated.DefaultOpacity)
        {
            Opacity = updated.DefaultOpacity;
            Info = Info with { Opacity = Opacity };
        }
    }

    private void UpdateShadow()
    {
        imageFrame.Margin = preferences.Shadow ? new Thickness(10) : new Thickness(0);
        imageFrame.Effect = preferences.Shadow ? new DropShadowEffect
        {
            BlurRadius = 16, ShadowDepth = 3, Direction = 270, Opacity = 0.32
        } : null;
    }

    private void Rotate(int direction)
    {
        Info = Info with { QuarterTurns = (Info.QuarterTurns + direction + 4) % 4,
            Width = Height, Height = Width, FlipHorizontal = Info.FlipVertical, FlipVertical = Info.FlipHorizontal };
        (Width, Height) = (Info.Width, Info.Height);
        ApplyImageTransform();
        Changed?.Invoke();
    }

    private void Flip(bool horizontal)
    {
        Info = horizontal ? Info with { FlipHorizontal = !Info.FlipHorizontal }
            : Info with { FlipVertical = !Info.FlipVertical };
        ApplyImageTransform();
        Changed?.Invoke();
    }

    private void ApplyImageTransform()
    {
        if (Info.QuarterTurns == 0 && !Info.FlipHorizontal && !Info.FlipVertical)
            Image = original;
        else
        {
            Transform transform = new RotateTransform(90 * Info.QuarterTurns);
            var transformed = new TransformedBitmap(original, transform);
            if (Info.FlipHorizontal || Info.FlipVertical)
                transformed = new TransformedBitmap(transformed,
                    new ScaleTransform(Info.FlipHorizontal ? -1 : 1, Info.FlipVertical ? -1 : 1));
            transformed.Freeze();
            Image = transformed;
        }
        imageView.Source = Image;
    }

    private void Add(string label, Action action)
    {
        var item = new MenuItem { Header = label };
        item.Click += (_, _) => action();
        ContextMenu.Items.Add(item);
    }

    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] private static extern int GetWindowLongW(IntPtr window, int index);
    [DllImport("user32.dll")] private static extern int SetWindowLongW(IntPtr window, int index, int value);
}

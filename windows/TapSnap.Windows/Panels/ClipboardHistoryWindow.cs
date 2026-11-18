using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Automation;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TapSnap.Windows;

internal sealed record ClipboardEntry(Guid Id, string? Text, string? ImagePath, DateTime Date);

internal sealed class ClipboardHistory : IDisposable
{
    private readonly HwndSource source = new(new HwndSourceParameters("TapSnapClipboard") { ParentWindow = new IntPtr(-3) });
    private readonly string folder = Path.Combine(Settings.DirectoryPath, "Clipboard");
    private List<ClipboardEntry> entries;
    private uint lastSequence;

    public ClipboardHistory()
    {
        entries = Load();
        source.AddHook(Receive);
        AddClipboardFormatListener(source.Handle);
        lastSequence = GetClipboardSequenceNumber();
    }

    public event Action? Changed;
    public IReadOnlyList<ClipboardEntry> Entries => entries;

    public void Activate(ClipboardEntry entry)
    {
        if (entry.ImagePath is { } image) Images.Copy(Images.Read(Path.Combine(folder, image)));
        else if (entry.Text is { } text) Clipboard.SetText(text);
        lastSequence = GetClipboardSequenceNumber();
    }

    public BitmapSource Image(ClipboardEntry entry) => Images.Read(Path.Combine(folder, entry.ImagePath!));

    public void Clear()
    {
        foreach (var entry in entries) DeleteImage(entry);
        entries.Clear();
        Persist();
        Changed?.Invoke();
    }

    private List<ClipboardEntry> Load()
    {
        try
        {
            var list = JsonSerializer.Deserialize<List<ClipboardEntry>>(File.ReadAllText(Path.Combine(folder, "index.json"))) ?? [];
            return list.Where(e => e.ImagePath is null || e.ImagePath == Path.GetFileName(e.ImagePath) &&
                File.Exists(Path.Combine(folder, e.ImagePath))).Take(50).ToList();
        }
        catch (IOException) { return []; }
        catch (JsonException) { return []; }
    }

    private void Persist()
    {
        Directory.CreateDirectory(folder);
        string index = Path.Combine(folder, "index.json");
        File.WriteAllText(index + ".tmp", JsonSerializer.Serialize(entries));
        File.Move(index + ".tmp", index, true);
    }

    private IntPtr Receive(IntPtr hwnd, int message, IntPtr w, IntPtr l, ref bool handled)
    {
        if (message == 0x031D) _ = source.Dispatcher.BeginInvoke(ReadClipboard);
        return IntPtr.Zero;
    }

    private void ReadClipboard()
    {
        uint sequence = GetClipboardSequenceNumber();
        if (lastSequence == sequence) return;
        try
        {
            var id = Guid.NewGuid();
            ClipboardEntry? entry = null;
            if (Images.ClipboardImage() is { } image && (long)image.PixelWidth * image.PixelHeight <= 32_000_000)
            {
                Directory.CreateDirectory(folder);
                string name = id + ".png";
                Images.Save(image, Path.Combine(folder, name));
                entry = new ClipboardEntry(id, null, name, DateTime.Now);
            }
            else if (Clipboard.ContainsText() && Clipboard.GetText() is { Length: > 0 and <= 524288 } text &&
                     entries.FirstOrDefault()?.Text != text)
                entry = new ClipboardEntry(id, text, null, DateTime.Now);
            lastSequence = sequence;
            if (entry == null) return;
            entries.Insert(0, entry);
            long bytes = 0;
            for (int index = 0; index < entries.Count;)
            {
                var row = entries[index];
                if (row.ImagePath is { } name) bytes += new FileInfo(Path.Combine(folder, name)).Length;
                else bytes += (row.Text?.Length ?? 0) * 2;
                if (index < 50 && bytes <= 128 * 1024 * 1024) { index++; continue; }
                DeleteImage(row);
                entries.RemoveAt(index);
            }
            Persist();
            Changed?.Invoke();
        }
        catch (ExternalException) { }
        catch (IOException) { }
    }

    private void DeleteImage(ClipboardEntry entry)
    {
        if (entry.ImagePath is { } name) File.Delete(Path.Combine(folder, name));
    }

    public void Dispose()
    {
        RemoveClipboardFormatListener(source.Handle);
        source.Dispose();
    }

    [DllImport("user32.dll")] private static extern bool AddClipboardFormatListener(IntPtr window);
    [DllImport("user32.dll")] private static extern bool RemoveClipboardFormatListener(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
}

internal sealed class ClipboardHistoryWindow : Window
{
    private readonly ClipboardHistory history;
    private readonly SnapPalette palette;
    private readonly StackPanel rows = new();
    private readonly TextBlock count = new() { FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button clear;
    private readonly Action<BitmapSource> editImage;
    private string filter = "全部";

    public ClipboardHistoryWindow(ClipboardHistory history, Action<BitmapSource> editImage, bool dark = false)
    {
        this.history = history;
        this.editImage = editImage;
        palette = SnapPalette.For(dark);
        Foreground = palette.Foreground;
        Title = "剪贴板历史";
        Width = 368;
        Height = 468;
        WindowStyle = WindowStyle.None;
        ShowInTaskbar = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        var layout = new DockPanel();
        Content = new Border
        {
            CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(1),
            BorderBrush = palette.Border, Background = palette.Hover, Child = layout
        };

        var header = new DockPanel { Height = 53, LastChildFill = true, Background = palette.Panel,
            Margin = new Thickness(1, 1, 1, 0) };
        var close = HeaderButton("×", "关闭", Close);
        clear = HeaderButton("delete", "清空本地剪贴板历史", history.Clear);
        foreach (var button in new[] { close, clear })
        {
            DockPanel.SetDock(button, Dock.Right);
            header.Children.Add(button);
        }
        var grip = new Border
        {
            Background = Brushes.Transparent, Cursor = Cursors.SizeAll,
            ToolTip = "拖动标题栏移动窗口", Padding = new Thickness(11, 0, 4, 0)
        };
        var title = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(GlyphTile("clipboard", new SolidColorBrush(dark ? Color.FromRgb(170, 184, 255) : Color.FromRgb(76, 88, 184))));
        title.Children.Add(new TextBlock { Text = "剪贴板历史", FontSize = 14, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(9, 0, 8, 0) });
        count.Foreground = palette.Muted;
        title.Children.Add(new Border { Background = palette.Hover, CornerRadius = new CornerRadius(9),
            Padding = new Thickness(6, 2, 6, 2), Child = count, VerticalAlignment = VerticalAlignment.Center });
        grip.Child = title;
        grip.MouseLeftButtonDown += (_,_) => DragMove();
        header.Children.Add(grip);
        DockPanel.SetDock(header, Dock.Top);
        layout.Children.Add(header);
        var segments = new UniformGrid { Rows = 1 };
        var filters = new Border { Child = segments, CornerRadius = new CornerRadius(7), Background = palette.Input,
            Padding = new Thickness(2), Margin = new Thickness(9, 7, 9, 4) };
        AutomationProperties.SetName(filters, "剪贴板分类");
        foreach (string kind in new[] { "全部", "图片", "文字" })
        {
            var segment = new RadioButton { Content = kind, IsChecked = kind == filter };
            segment.SetResourceReference(StyleProperty, "SnapSegment");
            segment.Checked += (_, _) => { filter = kind; Refresh(); };
            segments.Children.Add(segment);
        }
        DockPanel.SetDock(filters, Dock.Top);
        layout.Children.Add(filters);

        var footer = new DockPanel { Height = 34, Margin = new Thickness(13, 0, 13, 0) };
        var capacity = new TextBlock { Text = "最多 50 条", FontSize = 11,
            Foreground = palette.Muted, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(capacity, Dock.Right);
        footer.Children.Add(capacity);
        var lockIcon = IconCarrier("lock", palette.Muted, 11);
        lockIcon.Margin = new Thickness(0, 0, 5, 0);
        DockPanel.SetDock(lockIcon, Dock.Left);
        footer.Children.Add(lockIcon);
        footer.Children.Add(new TextBlock { Text = "仅保存在本机", FontSize = 11,
            Foreground = palette.Muted, VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(footer, Dock.Bottom);
        layout.Children.Add(footer);
        layout.Children.Add(new Border
        {
            Background = palette.Panel, BorderBrush = palette.Border, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10), Margin = new Thickness(8, 3, 8, 0),
            Child = new ScrollViewer { Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }
        });
        PreviewKeyDown += (_, args) => { if (args.Key == Key.Escape) Close(); };
        Closed += (_, _) => history.Changed -= Refresh;
        history.Changed += Refresh;
        WindowStartupLocation = WindowStartupLocation.Manual;
        SourceInitialized += (_, _) =>
        {
            var cursor = Desktop.Cursor;
            var monitor = Desktop.CursorMonitor;
            var area = System.Windows.Forms.Screen.FromPoint(cursor).WorkingArea;
            double scale = Desktop.ScaleForMonitor(monitor);
            int inset = (int)Math.Round(8 * scale);
            int width = Math.Clamp((int)Math.Round(Width * scale), 1, Math.Max(1, area.Width - inset * 2));
            int height = Math.Clamp((int)Math.Round(Height * scale), 1, Math.Max(1, area.Height - inset * 2));
            int x = Math.Clamp(cursor.X - width / 2, area.Left + inset, Math.Max(area.Left + inset, area.Right - width - inset));
            int y = Math.Clamp(cursor.Y + (int)Math.Round(12 * scale), area.Top + inset,
                Math.Max(area.Top + inset, area.Bottom - height - inset));
            Desktop.Place(this, new System.Drawing.Rectangle(x, y, width, height));
            Desktop.Exclude(this);
        };
        Refresh();
    }

    private Button HeaderButton(string glyph, string label, Action invoke)
    {
        var button = new Button { Width = 27, Height = 27, Margin = new Thickness(0, 0, 7, 0),
            VerticalAlignment = VerticalAlignment.Center, Foreground = palette.Muted, Cursor = Cursors.Hand,
            Background = palette.Panel, BorderBrush = palette.Border, Content = ToolbarGlyph.Make(glyph, 13), ToolTip = label,
            Template = RoundedButton(horizontal: HorizontalAlignment.Center, radius: 7) };
        AutomationProperties.SetName(button, label);
        button.Click += (_, _) => invoke();
        return button;
    }

    private Brush HoverColor => palette.Hover;

    private ControlTemplate RoundedButton(HorizontalAlignment horizontal, int radius)
    {
        var shell = new FrameworkElementFactory(typeof(Border)) { Name = "Shell" };
        shell.SetValue(Border.CornerRadiusProperty, new CornerRadius(radius));
        shell.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        shell.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Control.BorderBrushProperty));
        shell.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Control.BorderThicknessProperty));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(HorizontalAlignmentProperty, horizontal);
        content.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        shell.AppendChild(content);
        var template = new ControlTemplate(typeof(Button)) { VisualTree = shell };
        var hovered = new Trigger { Property = IsMouseOverProperty, Value = true };
        hovered.Setters.Add(new Setter(Border.BackgroundProperty, HoverColor, "Shell"));
        template.Triggers.Add(hovered);
        var pressed = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
        pressed.Setters.Add(new Setter(OpacityProperty, 0.76, "Shell"));
        template.Triggers.Add(pressed);
        var disabled = new Trigger { Property = IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(OpacityProperty, 0.35, "Shell"));
        template.Triggers.Add(disabled);
        return template;
    }

    private static ContentControl IconCarrier(string name, Brush tint, double size) => new()
    {
        Foreground = tint, Content = ToolbarGlyph.Make(name, size), Focusable = false,
        VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
        IsHitTestVisible = false
    };

    private static Border GlyphTile(string name, Brush tint)
    {
        Brush fill = tint.Clone();
        fill.Opacity = 0.12;
        return new Border { Width = 29, Height = 29, CornerRadius = new CornerRadius(8), Background = fill,
            Child = IconCarrier(name, tint, 13), VerticalAlignment = VerticalAlignment.Top };
    }

    private void Refresh()
    {
        var visible = history.Entries.Where(e => filter switch
            { "图片" => e.ImagePath != null, "文字" => e.ImagePath == null, _ => true }).ToList();
        count.Text = visible.Count.ToString();
        AutomationProperties.SetName(count, $"{count.Text} 条记录");
        clear.IsEnabled = history.Entries.Count > 0;
        rows.Children.Clear();
        if (visible.Count == 0)
        {
            var empty = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(10, 120, 10, 0) };
            empty.Children.Add(GlyphTile("clipboard", palette.Muted));
            empty.Children[^1].SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
            empty.Children.Add(new TextBlock { Text = filter == "全部" ? "还没有记录" : $"还没有{filter}记录", FontSize = 13, FontWeight = FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 9, 0, 0) });
            empty.Children.Add(new TextBlock { Text = "复制的文字和图片会出现在这里", Foreground = palette.Muted,
                HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 5, 0, 0) });
            rows.Children.Add(empty);
        }
        foreach (var entry in visible)
        {
            var row = new DockPanel { Margin = new Thickness(7), MinHeight = 29, LastChildFill = true };
            var stamp = new TextBlock { Text = entry.Date.ToString("HH:mm:ss"), FontSize = 10, Foreground = palette.Muted,
                Margin = new Thickness(9, 3, 0, 0), FontFamily = new FontFamily("Consolas") };
            DockPanel.SetDock(stamp, Dock.Right);
            row.Children.Add(stamp);
            var icon = GlyphTile(entry.ImagePath is null ? "text" : "image", palette.Muted);
            icon.Margin = new Thickness(0, 0, 9, 0);
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            if (entry.ImagePath != null)
            {
                try { row.Children.Add(new Image { Source = history.Image(entry), MaxWidth = 200, MaxHeight = 72,
                    HorizontalAlignment = HorizontalAlignment.Left }); }
                catch (IOException) { continue; }
            }
            else row.Children.Add(new TextBlock
            {
                Text = entry.Text, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = palette.Foreground, MaxHeight = 34, VerticalAlignment = VerticalAlignment.Center
            });
            var button = new Button
            {
                Content = row, HorizontalContentAlignment = HorizontalAlignment.Stretch, Cursor = Cursors.Hand,
                Margin = new Thickness(6, 3, 6, 0), BorderThickness = new Thickness(0), Background = Brushes.Transparent,
                Template = RoundedButton(horizontal: HorizontalAlignment.Stretch, radius: 8)
            };
            AutomationProperties.SetHelpText(button, "复制这条记录");
            button.Click += (_, _) => { history.Activate(entry); Close(); };
            var actions = new DockPanel();
            if (entry.ImagePath != null)
            {
                var edit = new Button { Content = "编辑", VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(2, 0, 6, 0), ToolTip = "编辑这张图片" };
                edit.Click += (_, _) =>
                {
                    try { var image = history.Image(entry); Close(); editImage(image); }
                    catch (Exception error) { MessageBox.Show(error.Message, "无法打开图片"); }
                };
                DockPanel.SetDock(edit, Dock.Right);
                actions.Children.Add(edit);
            }
            actions.Children.Add(button);
            rows.Children.Add(actions);
        }
    }
}

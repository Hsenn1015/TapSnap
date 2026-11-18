using System;
using System.Collections.Specialized;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace TapSnap.Windows;

internal sealed partial class RecordingPreview : IDisposable
{
    private readonly RecordingFrames frames;
    private readonly TimeSpan duration;
    private readonly int videoRate;
    private readonly string? audio;
    private readonly CancellationTokenSource lifetime = new();
    private Window? window;
    private Task<string>? preparation;
    private Task? exporting;

    public RecordingPreview(RecordingFrames frames, TimeSpan duration, int videoRate, string? audio)
    {
        this.frames = frames;
        this.duration = duration;
        this.videoRate = videoRate;
        this.audio = audio;
    }

    public void Show()
    {
        if (lifetime.IsCancellationRequested) return;
        if (window != null) { window.Activate(); return; }
        double full = duration.TotalSeconds, from = 0, to = full;
        double minimum = Math.Min(full, 1d / 60);
        bool opened = false, playing = false, updating = false, closed = false, seeking = false;
        CancellationTokenSource? export = null;

        var panel = new Window
        {
            Title = "录屏预览", Width = 720, Height = 630, WindowStartupLocation = WindowStartupLocation.CenterScreen,
            MinWidth = 520, MinHeight = 440, Topmost = true
        };
        SnapTheme.StyleWindow(panel);
        var palette = SnapPalette.For(SnapTheme.IsDark);
        var foreground = palette.Foreground;
        var muted = palette.Muted;
        window = panel;
        panel.SourceInitialized += (_, _) => Desktop.Exclude(panel);
        var content = new DockPanel();
        var controls = new StackPanel { Margin = new Thickness(16, 10, 16, 12) };
        DockPanel.SetDock(controls, Dock.Bottom);
        content.Children.Add(controls);
        var video = new DockPanel { Background = Brushes.Black };
        content.Children.Add(video);
        panel.Content = content;

        var media = new MediaElement
        {
            LoadedBehavior = MediaState.Manual, UnloadedBehavior = MediaState.Close,
            Volume = 0.75, Stretch = Stretch.Uniform, ScrubbingEnabled = true
        };
        var scene = new Grid();
        var poster = new Image { Stretch = Stretch.Uniform };
        using (var handle = frames.Open()) poster.Source = frames.Read(handle, 0);
        media.Visibility = Visibility.Hidden;
        var transport = new DockPanel { Margin = new Thickness(9, 4, 9, 5), Background = Brushes.Black };
        DockPanel.SetDock(transport, Dock.Bottom);
        video.Children.Add(transport);
        video.Children.Add(scene);
        scene.Children.Add(poster);
        scene.Children.Add(media);

        var time = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
        var play = new Button { Content = "▶", Margin = new Thickness(3), Padding = new Thickness(9, 4, 9, 4) };
        play.Click += (_, _) => SetPlaying(!playing);
        play.IsEnabled = false;
        play.ToolTip = "播放／暂停";
        var volume = new Slider { Width = 64, Minimum = 0, Maximum = 1, Value = media.Volume, Margin = new Thickness(8, 2, 0, 2) };
        volume.ValueChanged += (_, _) => media.Volume = volume.Value;
        AutomationProperties.SetName(volume, "音量");
        var position = new Slider { Minimum = 0, Maximum = full, IsMoveToPointEnabled = true, IsEnabled = false };
        AutomationProperties.SetName(position, "播放进度");
        transport.Children.Add(play);
        DockPanel.SetDock(volume, Dock.Right);
        transport.Children.Add(volume);
        transport.Children.Add(position);

        void SetPlaying(bool value)
        {
            if (!opened) return;
            playing = value;
            play.Content = playing ? "Ⅱ" : "▶";
            if (playing)
            {
                if (media.Position.TotalSeconds < from || media.Position.TotalSeconds >= to)
                    media.Position = TimeSpan.FromSeconds(from);
                media.Play();
                time.Start();
            }
            else { time.Stop(); media.Pause(); }
        }

        void UpdatePosition()
        {
            if (seeking) return;
            if (media.Position.TotalSeconds >= to) media.Position = TimeSpan.FromSeconds(from);
            updating = true;
            position.Value = media.Position.TotalSeconds;
            updating = false;
        }

        time.Tick += (_, _) => UpdatePosition();
        position.ValueChanged += (_, _) =>
        {
            if (!opened || updating) return;
            media.Position = TimeSpan.FromSeconds(position.Value);
        };
        position.PreviewMouseLeftButtonDown += (_, _) => seeking = true;
        position.PreviewMouseLeftButtonUp += (_, _) => seeking = false;
        position.LostMouseCapture += (_, _) => seeking = false;

        (Slider Slider, TextBox Field) TrimRow(string title, double initial)
        {
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            var label = new TextBlock { Width = 42, Text = title, VerticalAlignment = VerticalAlignment.Center, Foreground = foreground };
            var unit = new TextBlock { Text = "秒", Margin = new Thickness(7, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center, Foreground = foreground };
            var field = new TextBox
            {
                Width = 78, TextAlignment = TextAlignment.Right, Padding = new Thickness(3, 1, 5, 1),
                FontFamily = new FontFamily("Consolas"), Text = TimeText(initial)
            };
            var slider = new Slider
            {
                Minimum = 0, Maximum = full, Value = initial, IsMoveToPointEnabled = true,
                VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0)
            };
            AutomationProperties.SetName(field, title + "秒数");
            AutomationProperties.SetName(slider, "裁剪" + title + "时间");
            DockPanel.SetDock(unit, Dock.Right);
            DockPanel.SetDock(field, Dock.Right);
            row.Children.Add(label);
            row.Children.Add(unit);
            row.Children.Add(field);
            row.Children.Add(slider);
            controls.Children.Add(row);
            return (slider, field);
        }

        var (startSlider, startField) = TrimRow("开始", 0);
        var (endSlider, endField) = TrimRow("结束", full);
        var options = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 4) };
        options.Children.Add(new TextBlock { Text = "GIF", VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 5, 0), Foreground = foreground });
        var rates = new ComboBox { Width = 82, Margin = new Thickness(3), SelectedValuePath = "Tag" };
        foreach (int value in new[] { 10, 15, 24, 30 }) rates.Items.Add(new ComboBoxItem { Content = $"{value} FPS", Tag = value });
        rates.SelectedValue = 15;
        var sizes = new ComboBox { Width = 145, Margin = new Thickness(3), SelectedValuePath = "Tag" };
        foreach (int value in new[] { 640, 960, 1280, 1920, 0 })
            sizes.Items.Add(new ComboBoxItem { Content = value == 0 ? "原始尺寸" : $"最长边 {value} 像素", Tag = value });
        sizes.SelectedValue = 1280;
        AutomationProperties.SetName(rates, "GIF 帧率");
        AutomationProperties.SetName(sizes, "GIF 尺寸上限");
        options.Children.Add(rates);
        options.Children.Add(sizes);
        var reset = new Button { Content = "恢复全段", Margin = new Thickness(3), Padding = new Thickness(9, 4, 9, 4) };
        options.Children.Add(reset);
        controls.Children.Add(options);

        var statusRow = new DockPanel { LastChildFill = true, Margin = new Thickness(3, 3, 3, 1) };
        var status = new TextBlock { Text = "正在读取视频…", VerticalAlignment = VerticalAlignment.Center, Foreground = muted };
        var cancel = RecordingWindow.Button("取消导出", () => export?.Cancel());
        cancel.Visibility = Visibility.Collapsed;
        DockPanel.SetDock(cancel, Dock.Right);
        statusRow.Children.Add(cancel);
        statusRow.Children.Add(status);
        controls.Children.Add(statusRow);
        var progress = new ProgressBar { Height = 4, IsIndeterminate = true, Margin = new Thickness(3, 4, 3, 8) };
        controls.Children.Add(progress);

        string RangeText() => $"已选择 {to - from:F2} 秒，视频与 GIF 均导出此范围，GIF 无声";

        void ApplyRange(double start, double end, bool seek)
        {
            from = start;
            to = end;
            updating = true;
            startSlider.Value = from;
            endSlider.Value = to;
            startField.Text = TimeText(from);
            endField.Text = TimeText(to);
            position.Maximum = to;
            position.Minimum = from;
            if (seek && opened) { media.Position = TimeSpan.FromSeconds(from); position.Value = from; }
            updating = false;
            if (export == null) status.Text = RangeText();
        }

        reset.Click += (_, _) => ApplyRange(0, full, true);
        startSlider.ValueChanged += (_, _) => { if (!updating) ApplyRange(Math.Clamp(startSlider.Value, 0, Math.Max(0, to - minimum)), to, true); };
        endSlider.ValueChanged += (_, _) => { if (!updating) ApplyRange(from, Math.Clamp(endSlider.Value, Math.Min(full, from + minimum), full), true); };

        void Commit(TextBox field, bool changeStart)
        {
            bool parsed = double.TryParse(field.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double value) ||
                double.TryParse(field.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out value);
            if (!parsed || !double.IsFinite(value))
            {
                field.Text = TimeText(changeStart ? from : to);
                return;
            }
            if (changeStart) ApplyRange(Math.Clamp(value, 0, Math.Max(0, to - minimum)), to, true);
            else ApplyRange(from, Math.Clamp(value, Math.Min(full, from + minimum), full), true);
        }

        startField.LostKeyboardFocus += (_, _) => { if (startField.Text != TimeText(from)) Commit(startField, true); };
        endField.LostKeyboardFocus += (_, _) => { if (endField.Text != TimeText(to)) Commit(endField, false); };
        startField.PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(startField, true); e.Handled = true; } };
        endField.PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(endField, false); e.Handled = true; } };

        var footer = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1 };
        var close = RecordingWindow.Button("关闭", panel.Close);
        var saveVideo = new Button { Content = "保存视频…", Margin = new Thickness(3) };
        var copyVideo = new Button { Content = "复制视频", ToolTip = "将当前片段作为 MP4 文件复制（Ctrl+C）", Margin = new Thickness(3) };
        copyVideo.SetResourceReference(FrameworkElement.StyleProperty, "SnapPrimary");
        var saveGif = new Button { Content = "保存 GIF…", Margin = new Thickness(3) };
        var copyGif = new Button { Content = "复制 GIF", Margin = new Thickness(3) };
        saveVideo.Click += (_, _) => StartExport(".mp4", false);
        copyVideo.Click += (_, _) => StartExport(".mp4", true);
        saveGif.Click += (_, _) => StartExport(".gif", false);
        copyGif.Click += (_, _) => StartExport(".gif", true);
        foreach (var button in new[] { close, saveVideo, saveGif, copyGif, copyVideo }) footer.Children.Add(button);
        controls.Children.Add(footer);

        void SetExporting(bool busy)
        {
            foreach (var control in new Control[] { startSlider, endSlider, startField, endField, rates, sizes, reset, saveVideo, saveGif, copyGif, copyVideo })
                control.IsEnabled = !busy;
            progress.Visibility = busy ? Visibility.Visible : Visibility.Hidden;
            cancel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        }

        void StartExport(string format, bool copy)
        {
            if (export != null || closed) return;
            exporting = RunExportAsync();
            async Task RunExportAsync()
            {
                try { await ExportAsync(format, copy); }
                catch (Exception error) { if (!closed) status.Text = $"导出失败：{error.Message}"; }
            }
        }

        async Task ExportAsync(string format, bool copy)
        {
            string path;
            if (copy)
            {
                string cache = Path.Combine(Settings.DirectoryPath, "RecordingClipboard");
                Directory.CreateDirectory(cache);
                path = Path.Combine(cache, $"TapSnap-{DateTime.Now:yyyy-MM-dd-HHmmss}-{Guid.NewGuid():N}{format}");
            }
            else
            {
                var dialog = new SaveFileDialog
                {
                    Filter = $"{format[1..].ToUpperInvariant()}|*{format}",
                    FileName = $"TapSnap-{DateTime.Now:yyyy-MM-dd-HHmmss}{format}"
                };
                if (dialog.ShowDialog(panel) != true) return;
                path = dialog.FileName;
            }
            using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            export = cancellation;
            double start = from, end = to;
            int rate = (int)rates.SelectedValue, limit = (int)sizes.SelectedValue;
            SetExporting(true);
            status.Text = "正在导出…";
            bool placedOnClipboard = false;
            try
            {
                if (format == ".gif") await Task.Run(() => SaveGif(path, start, end, rate, limit, cancellation.Token), cancellation.Token);
                else if (start == 0 && end == full)
                {
                    string original = await PrepareAsync().WaitAsync(cancellation.Token);
                    await Task.Run(() => CopyVideo(original, path, cancellation.Token), cancellation.Token);
                }
                else await Task.Run(() => SaveMp4(path, start, end, cancellation.Token), cancellation.Token);
                if (copy && !closed)
                {
                    var files = new StringCollection { path };
                    var data = new DataObject();
                    if (format == ".gif") data.SetData("GIF", new MemoryStream(await File.ReadAllBytesAsync(path, cancellation.Token)), false);
                    cancellation.Token.ThrowIfCancellationRequested();
                    data.SetFileDropList(files);
                    Clipboard.SetDataObject(data, true);
                    placedOnClipboard = true;
                }
                status.Text = !copy ? "已保存" : format == ".gif" ? "已复制 GIF" : "已复制视频";
            }
            catch (OperationCanceledException) { if (!closed) status.Text = "已取消导出"; }
            catch (Exception error) { if (!closed) status.Text = $"导出失败：{error.Message}"; }
            finally
            {
                export = null;
                if (!closed) SetExporting(false);
                if (copy && !placedOnClipboard) File.Delete(path);
            }
        }

        media.MediaOpened += (_, _) =>
        {
            if (closed) return;
            opened = true;
            play.IsEnabled = position.IsEnabled = true;
            media.Visibility = Visibility.Visible;
            poster.Visibility = Visibility.Collapsed;
            media.Position = TimeSpan.FromSeconds(from);
            if (export == null) { progress.Visibility = Visibility.Hidden; status.Text = RangeText(); }
            SetPlaying(true);
        };
        media.MediaEnded += (_, _) =>
        {
            if (!opened || !playing) return;
            media.Position = TimeSpan.FromSeconds(from);
            media.Play();
        };
        media.MediaFailed += (_, failure) =>
        {
            opened = false;
            time.Stop();
            play.IsEnabled = position.IsEnabled = false;
            media.Visibility = Visibility.Hidden;
            poster.Visibility = Visibility.Visible;
            if (export == null) { progress.Visibility = Visibility.Hidden; status.Text = $"无法播放视频：{failure.ErrorException.Message}"; }
        };
        panel.Loaded += async (_, _) =>
        {
            try
            {
                var path = await PrepareAsync();
                if (!closed)
                {
                    media.Source = new Uri(path, UriKind.Absolute);
                    // Opening the media resource is lazy in manual mode.
                    media.Play();
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                if (!closed && export == null) { progress.Visibility = Visibility.Hidden; status.Text = $"无法读取视频：{error.Message}"; }
            }
        };
        panel.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { panel.Close(); e.Handled = true; }
            if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control && Keyboard.FocusedElement is not TextBox)
            { if (!e.IsRepeat) StartExport(".mp4", true); e.Handled = true; }
            if (e.Key == Key.Space && Keyboard.FocusedElement is not TextBox and not ComboBox)
            { SetPlaying(!playing); e.Handled = true; }
        };
        panel.Closed += (_, _) =>
        {
            closed = true;
            time.Stop();
            media.Close();
            export?.Cancel();
            if (window == panel) window = null;
        };
        panel.Show();
    }

    private static string TimeText(double value) => value.ToString("F2", CultureInfo.CurrentCulture);

    private Task<string> PrepareAsync() => preparation ??= Task.Run(async () =>
    {
        string path = Path.Combine(frames.Folder, "preview.mp4");
        await SaveMp4(path, 0, duration.TotalSeconds, lifetime.Token);
        return path;
    }, lifetime.Token);

    private static void CopyVideo(string source, string target, CancellationToken cancellation)
    {
        string temporary = target + ".tapsnap-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var input = File.OpenRead(source))
            using (var output = File.Create(temporary))
            {
                var buffer = new byte[128 * 1024];
                for (int read; (read = input.Read(buffer)) != 0;)
                {
                    cancellation.ThrowIfCancellationRequested();
                    output.Write(buffer, 0, read);
                }
            }
            cancellation.ThrowIfCancellationRequested();
            File.Move(temporary, target, true);
        }
        finally { File.Delete(temporary); }
    }

    public void Dispose()
    {
        if (lifetime.IsCancellationRequested) return;
        lifetime.Cancel();
        window?.Close();
        _ = CleanAsync();
    }

    private async Task CleanAsync()
    {
        try { if (preparation != null) await preparation; }
        catch (Exception) { }
        try { if (exporting != null) await exporting; }
        catch (Exception) { }
        frames.Clean();
        lifetime.Dispose();
    }
}

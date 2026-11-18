using System;
using System.Collections.Specialized;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
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
    private Task<BitmapSource[]>? thumbnails;
    private RecordingMark[] marks = [];
    private double trimStart, trimEnd;

    public RecordingPreview(RecordingFrames frames, TimeSpan duration, int videoRate, string? audio)
    {
        this.frames = frames;
        this.duration = duration;
        this.videoRate = videoRate;
        this.audio = audio;
        trimEnd = duration.TotalSeconds;
    }

    public void Show()
    {
        if (lifetime.IsCancellationRequested) return;
        if (window != null) { window.Activate(); return; }
        double full = duration.TotalSeconds, from = trimStart, to = trimEnd, head = from;
        double minimum = Math.Min(full, 1d / videoRate);
        bool opened = false, playing = false, autoplay = true, closed = false;
        CancellationTokenSource? export = null;

        var panel = new Window
        {
            Title = "录屏预览", Width = 800, Height = 650, WindowStartupLocation = WindowStartupLocation.CenterScreen,
            MinWidth = 550, MinHeight = 530, Topmost = true
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
        BitmapSource reference;
        using (var handle = frames.Open()) reference = frames.Read(handle, 0);
        poster.Source = reference;
        var ink = new RecordingMarkupEditor(reference, marks, full, videoRate, palette);
        var timeline = new RecordingTimeline(full, videoRate, palette);
        int posterIndex = 0;
        media.Visibility = Visibility.Hidden;
        var transport = new DockPanel { Background = palette.EditorChrome };
        DockPanel.SetDock(transport, Dock.Bottom);
        video.Children.Add(transport);
        video.Children.Add(scene);
        scene.Children.Add(poster);
        scene.Children.Add(media);
        scene.Children.Add(ink);

        var time = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(20) };
        var play = ToolbarGlyph.CreateButton("播放／暂停", "play", palette);
        play.IsEnabled = false;
        var volume = new Slider { Width = 64, Minimum = 0, Maximum = 1, Value = media.Volume, Margin = new Thickness(8, 2, 0, 2) };
        volume.ValueChanged += (_, _) => media.Volume = volume.Value;
        AutomationProperties.SetName(volume, "音量");
        var previousFrame = ToolbarGlyph.CreateButton("上一帧", "previous-frame", palette);
        var nextFrame = ToolbarGlyph.CreateButton("下一帧", "next-frame", palette);
        var clock = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Foreground = foreground,
            Margin = new Thickness(8, 0, 0, 0), FontFamily = new FontFamily("Consolas") };
        AutomationProperties.SetName(clock, "当前播放时间");
        play.Click += (_, _) => SetPlaying(!playing);
        previousFrame.Click += (_, _) => Step(-1);
        nextFrame.Click += (_, _) => Step(1);
        DockPanel.SetDock(volume, Dock.Right);
        transport.Children.Add(volume);
        transport.Children.Add(play);
        transport.Children.Add(previousFrame);
        transport.Children.Add(nextFrame);
        transport.Children.Add(clock);
        controls.Children.Add(ink.Controls);
        var timelineScroll = new ScrollViewer { Content = timeline, MaxHeight = 114,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        controls.Children.Add(timelineScroll);

        void SetHead(double value, bool showStill)
        {
            head = Math.Clamp(value, from, to);
            double visible = head >= to ? Math.Max(from, (Math.Ceiling(to * videoRate - 1e-7) - 1) / videoRate) : head;
            ink.SetTime(visible, to);
            timeline.Playhead(head);
            clock.Text = $"{head:0.000} / {full:0.000} s";
            if (!showStill) return;
            int index = frames.IndexAt(Math.Floor(visible * videoRate + 1e-7) / videoRate);
            if (index != posterIndex)
            {
                using var handle = frames.Open();
                poster.Source = frames.ReadFrame(handle, index, Math.Max(960, (int)Math.Ceiling(scene.ActualWidth *
                    VisualTreeHelper.GetDpi(scene).DpiScaleX)));
                posterIndex = index;
            }
            media.Visibility = Visibility.Hidden;
            poster.Visibility = Visibility.Visible;
        }
        void SetPlaying(bool value)
        {
            autoplay = value;
            if (!opened) return;
            if (value == playing) return;
            playing = value;
            play.Content = ToolbarGlyph.Make(value ? "pause" : "play");
            if (value)
            {
                if (head >= to) SetHead(from, false);
                media.Position = TimeSpan.FromSeconds(head);
                media.Visibility = Visibility.Visible;
                poster.Visibility = Visibility.Collapsed;
                media.Play();
                time.Start();
            }
            else
            {
                time.Stop();
                media.Pause();
                SetHead(media.Position.TotalSeconds, true);
            }
        }
        void Seek(double seconds)
        {
            SetPlaying(false);
            SetHead(seconds, true);
            if (opened) media.Position = TimeSpan.FromSeconds(head);
        }
        void Step(int direction)
        {
            double current = playing ? media.Position.TotalSeconds : head;
            double last = Math.Max(from, (Math.Ceiling(to * videoRate - 1e-7) - 1) / videoRate);
            int index = (int)Math.Floor(Math.Min(current, last) * videoRate + 1e-7);
            Seek(Math.Clamp((index + direction) / (double)videoRate, from, last));
        }
        time.Tick += (_, _) =>
        {
            if (!playing) return;
            if (media.Position.TotalSeconds >= to) media.Position = TimeSpan.FromSeconds(from);
            SetHead(media.Position.TotalSeconds, false);
        };
        ink.Pause += () => SetPlaying(false);
        ink.Seek += Seek;
        timeline.Marks(marks, ink.Selection);
        timeline.SelectMark += i => ink.SelectMark(i, true);
        timeline.MarkRange += ink.ChangeRange;
        timeline.Seek += Seek;
        timeline.Range(from, to);
        SetHead(from, true);

        var rangeRow = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 3, 0, 3) };
        controls.Children.Add(rangeRow);
        TextBox TimeField(string label, double initial)
        {
            rangeRow.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(5, 0, 3, 0) });
            var field = new TextBox { Width = 70, Text = TimeText(initial), FontFamily = new FontFamily("Consolas"),
                TextAlignment = TextAlignment.Right, VerticalContentAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(field, label + "秒数");
            rangeRow.Children.Add(field);
            return field;
        }
        var startField = TimeField("开始", from);
        var endField = TimeField("结束", to);
        var status = new TextBlock { Text = "正在读取视频…", VerticalAlignment = VerticalAlignment.Center, Foreground = muted };
        var reset = RecordingWindow.Button("恢复全段", () => ApplyRange(0, full, 0));
        rangeRow.Children.Add(reset);
        controls.Children.Add(ink.Inspector);
        int gifRate = 15, gifLimit = 1280;

        var statusRow = new DockPanel { LastChildFill = true, Margin = new Thickness(3, 3, 3, 1) };
        var cancel = RecordingWindow.Button("取消导出", () => export?.Cancel());
        cancel.Visibility = Visibility.Collapsed;
        DockPanel.SetDock(cancel, Dock.Right);
        statusRow.Children.Add(cancel);
        statusRow.Children.Add(status);
        controls.Children.Add(statusRow);
        var progress = new ProgressBar { Height = 4, IsIndeterminate = true, Margin = new Thickness(3, 4, 3, 8) };
        controls.Children.Add(progress);

        string RangeText() => $"已选择 {to - from:F2} 秒，视频与 GIF 均导出此范围，GIF 无声";
        ink.Changed += () =>
        {
            if (marks != ink.Items && export == null) status.Text = RangeText();
            marks = ink.Items;
            timeline.Marks(marks, ink.Selection);
        };

        void ApplyRange(double start, double end, double seek)
        {
            trimStart = from = start;
            trimEnd = to = end;
            startField.Text = TimeText(from);
            endField.Text = TimeText(to);
            timeline.Range(from, to);
            Seek(seek);
            if (export == null) status.Text = RangeText();
        }

        void Adjust(bool start, double value)
        {
            if (start) { double n = Math.Clamp(value, 0, Math.Max(0, to - minimum)); ApplyRange(n, to, n); }
            else { double n = Math.Clamp(value, Math.Min(full, from + minimum), full); ApplyRange(from, n, n); }
        }
        timeline.Trim += Adjust;

        void Commit(TextBox field, bool changeStart)
        {
            bool parsed = double.TryParse(field.Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double value) ||
                double.TryParse(field.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out value);
            if (!parsed || !double.IsFinite(value))
            {
                field.Text = TimeText(changeStart ? from : to);
                return;
            }
            Adjust(changeStart, value);
        }

        startField.LostKeyboardFocus += (_, _) => { if (startField.Text != TimeText(from)) Commit(startField, true); };
        endField.LostKeyboardFocus += (_, _) => { if (endField.Text != TimeText(to)) Commit(endField, false); };
        startField.PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(startField, true); e.Handled = true; } };
        endField.PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(endField, false); e.Handled = true; } };

        var footer = new DockPanel { LastChildFill = false };
        var close = RecordingWindow.Button("关闭", panel.Close);
        var saveVideo = new Button { Content = "保存视频…", Margin = new Thickness(3) };
        var copyVideo = new Button { Content = "复制视频", ToolTip = "将当前片段作为 MP4 文件复制（Ctrl+C）", Margin = new Thickness(3) };
        copyVideo.SetResourceReference(FrameworkElement.StyleProperty, "SnapPrimary");
        var copyGif = new Button { Content = "复制 GIF", Margin = new Thickness(3) };
        var gifOptions = ToolbarGlyph.CreateButton("GIF 导出选项", "⌄", palette);
        saveVideo.Click += (_, _) => StartExport(".mp4", false);
        copyVideo.Click += (_, _) => StartExport(".mp4", true);
        copyGif.Click += (_, _) => StartExport(".gif", true);
        gifOptions.Click += (_, _) =>
        {
            var menu = new ContextMenu { PlacementTarget = gifOptions };
            var save = new MenuItem { Header = "保存 GIF…" };
            save.Click += (_, _) => _ = panel.Dispatcher.BeginInvoke(() => StartExport(".gif", false), DispatcherPriority.Background);
            menu.Items.Add(save);
            void Choices(string title, int[] values, int selected, Func<int, string> label, Action<int> choose)
            {
                var group = new MenuItem { Header = title };
                foreach (int n in values)
                {
                    var item = new MenuItem { Header = label(n), IsChecked = n == selected };
                    item.Click += (_, _) => choose(n);
                    group.Items.Add(item);
                }
                menu.Items.Add(group);
            }
            Choices("帧率", new[] { 10, 15, 24, 30 }, gifRate, n => $"{n} FPS", n => gifRate = n);
            Choices("最长边", new[] { 640, 960, 1280, 1920, 0 }, gifLimit, n => n == 0 ? "原始尺寸" : $"{n} 像素", n => gifLimit = n);
            gifOptions.ContextMenu = menu;
            menu.IsOpen = true;
        };
        footer.Children.Add(close);
        foreach (var button in new[] { copyVideo, saveVideo, gifOptions, copyGif })
        { DockPanel.SetDock(button, Dock.Right); footer.Children.Add(button); }
        controls.Children.Add(footer);

        void SetExporting(bool busy)
        {
            foreach (var control in new UIElement[] { timeline, ink, ink.Controls, ink.Inspector, startField, endField, reset, saveVideo, gifOptions, copyGif, copyVideo })
                control.IsEnabled = !busy;
            progress.Visibility = busy ? Visibility.Visible : Visibility.Hidden;
            cancel.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        }

        void StartExport(string format, bool copy)
        {
            if (export != null || closed) return;
            var current = RunExportAsync();
            exporting = exporting is { IsCompleted: false } pending ? Task.WhenAll(pending, current) : current;
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
            int rate = gifRate, limit = gifLimit;
            SetExporting(true);
            status.Text = "正在导出…";
            bool placedOnClipboard = false;
            try
            {
                RecordingOverlay[] layers = [];
                if (marks.Any(m => m.Start < end && start < m.End))
                {
                    int w = frames.Width & ~1, h = frames.Height & ~1;
                    if (format == ".gif")
                    {
                        using var input = frames.Open();
                        var frame = frames.ReadFrame(input, frames.IndexAt(start), limit);
                        w = frame.PixelWidth; h = frame.PixelHeight;
                    }
                    layers = RecordingOverlay.Prepare(marks, reference, start, end, w, h, format == ".gif");
                }
                if (format == ".gif") await Task.Run(() => SaveGif(path, start, end, rate, limit, cancellation.Token, layers), cancellation.Token);
                else if (start == 0 && end == full && layers.Length == 0)
                {
                    string original = await PrepareAsync().WaitAsync(cancellation.Token);
                    await Task.Run(() => CopyVideo(original, path, cancellation.Token), cancellation.Token);
                }
                else await Task.Run(() => SaveMp4(path, start, end, cancellation.Token, layers), cancellation.Token);
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
            play.IsEnabled = true;
            media.Pause();
            media.Position = TimeSpan.FromSeconds(head);
            if (export == null) { progress.Visibility = Visibility.Hidden; status.Text = RangeText(); }
            SetPlaying(autoplay);
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
            playing = false;
            play.IsEnabled = false;
            media.Visibility = Visibility.Hidden;
            poster.Visibility = Visibility.Visible;
            if (export == null) { progress.Visibility = Visibility.Hidden; status.Text = $"无法播放视频：{failure.ErrorException.Message}"; }
        };
        panel.Loaded += async (_, _) =>
        {
            try
            {
                thumbnails ??= Task.Run(() =>
                {
                    using var input = frames.Open();
                    return Enumerable.Range(0, 8).Select(i =>
                    {
                        lifetime.Token.ThrowIfCancellationRequested();
                        return frames.ReadFrame(input, frames.IndexAt((i + .5) * full / 8), 180);
                    }).ToArray();
                }, lifetime.Token);
                var film = await thumbnails;
                if (closed) return;
                timeline.SetFilm(film);
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
            if (e.Key == Key.Escape) { if (!ink.CancelTool()) panel.Close(); e.Handled = true; return; }
            if (Keyboard.FocusedElement is TextBox or ComboBox) return;
            if (export == null && Keyboard.Modifiers == ModifierKeys.Control && e.Key is Key.Z or Key.Y)
            { ink.History(e.Key == Key.Y); e.Handled = true; return; }
            if (export == null && e.Key == Key.Delete) { ink.DeleteSelection(); e.Handled = true; return; }
            if (e.Key is Key.Left or Key.Right) { Step(e.Key == Key.Left ? -1 : 1); e.Handled = true; return; }
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

    private static string TimeText(double value) => value.ToString("0.###", CultureInfo.CurrentCulture);

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
        try { if (thumbnails != null) await thumbnails; }
        catch (Exception) { }
        try { if (preparation != null) await preparation; }
        catch (Exception) { }
        try { if (exporting != null) await exporting; }
        catch (Exception) { }
        frames.Clean();
        lifetime.Dispose();
    }
}

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ImageMagick;
using TapSnap.Windows;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Storage;

internal static partial class Program
{
    private static Button ButtonNamed(DependencyObject parent, string name) =>
        Descendants<Button>(parent).Single(b => AutomationProperties.GetName(b) == name || Equals(b.Content, name));

    private static void Snapshot(FrameworkElement panel, string path)
    {
        panel.UpdateLayout();
        var size = new Size(Math.Ceiling(panel.ActualWidth), Math.Ceiling(panel.ActualHeight));
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen()) dc.DrawRectangle(new VisualBrush(panel), null, new Rect(size));
        var image = new RenderTargetBitmap((int)size.Width, (int)size.Height, 96, 96, PixelFormats.Pbgra32);
        image.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(image));
        using var output = File.Create(path);
        encoder.Save(output);
    }

    private static async Task CheckHistoryFilters(TapSnapHost host, string output)
    {
        var history = (ClipboardHistory)typeof(TapSnapHost).GetField("history", Private)!.GetValue(host)!;
        const string example = "TapSnap 分类测试";
        Clipboard.SetText(example);
        await Until(() => history.Entries.Any(e => e.Text == example), "fixture text in history");
        Images.Copy(BitmapSource.Create(40, 20, 96, 96, PixelFormats.Bgra32, null, Enumerable.Repeat((byte)255, 3200).ToArray(), 160));
        await Until(() => history.Entries.Any(e => e.ImagePath != null), "fixture image in history");
        var shortcuts = (Dictionary<string, (string Title, Action Action)>)typeof(TapSnapHost).GetField("hotkeyActions", Private)!.GetValue(host)!;
        shortcuts["history"].Action();
        var window = Application.Current.Windows.OfType<ClipboardHistoryWindow>().Single();
        window.UpdateLayout();
        var buttons = Descendants<RadioButton>(window).ToDictionary(b => (string)b.Content);
        Require(buttons.Count == 3 && buttons["全部"].IsChecked == true, "Missing history segments.");
        foreach (string filter in new[] { "文字", "图片", "全部" })
        {
            ((ISelectionItemProvider)new RadioButtonAutomationPeer(buttons[filter]).GetPattern(PatternInterface.SelectionItem)!).Select();
            window.UpdateLayout();
            Require(Descendants<TextBlock>(window).Any(t => t.Text == example) == (filter != "图片") &&
                Descendants<Button>(window).Any(b => Equals(b.Content, "编辑")) == (filter != "文字"), "Wrong rows for " + filter);
        }
        Snapshot((FrameworkElement)window.Content, Path.Combine(output, "clipboard-filters.png"));
        window.Close();
        Console.WriteLine("PASS one-click history segments for images, text and all entries.");
    }

    private static void EditField(Window panel, string name, string text)
    {
        var field = Descendants<TextBox>(panel).Single(s => AutomationProperties.GetName(s) == name);
        field.Text = text;
        field.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(field)!, Environment.TickCount, Key.Enter)
            { RoutedEvent = Keyboard.PreviewKeyDownEvent });
    }

    private static async Task<MenuItem> GifMenu(Window panel, string title)
    {
        var button = ButtonNamed(panel, "GIF 导出选项");
        Invoke(button);
        await Until(() => button.ContextMenu?.IsOpen == true, "GIF menu");
        return button.ContextMenu!.Items.OfType<MenuItem>().Single(i => Equals(i.Header, title));
    }

    private static async Task GifOption(Window panel, string group, string label)
    {
        var parent = await GifMenu(panel, group);
        var item = parent.Items.OfType<MenuItem>().Single(c => Equals(c.Header, label));
        item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        ButtonNamed(panel, "GIF 导出选项").ContextMenu!.IsOpen = false;
    }

    private static async Task Drag(FrameworkElement view, Point from, Point to)
    {
        var p = view.PointToScreen(from);
        Require(SetCursorPos((int)Math.Round(p.X), (int)Math.Round(p.Y)), "Cannot position mouse.");
        await Task.Delay(65);
        view.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left) { RoutedEvent = UIElement.MouseLeftButtonDownEvent });
        p = view.PointToScreen(to);
        Require(SetCursorPos((int)Math.Round(p.X), (int)Math.Round(p.Y)), "Cannot move mouse.");
        await Task.Delay(65);
        view.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = Mouse.MouseMoveEvent });
        view.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left) { RoutedEvent = UIElement.MouseLeftButtonUpEvent });
    }

    private static async Task CheckTimedAnnotation(Window panel, string folder)
    {
        await GifOption(panel, "帧率", "10 FPS");
        var ink = Descendants<RecordingMarkupEditor>(panel).Single();
        var timeline = Descendants<RecordingTimeline>(panel).Single();
        panel.Activate();
        Invoke(ButtonNamed(panel, "打码"));
        await Task.Delay(100);
        await Drag(ink, new Point(ink.ActualWidth * .39, ink.ActualHeight * .39), new Point(ink.ActualWidth * .61, ink.ActualHeight * .61));
        Require(ink.Items is [{ Start: 0, End: 5 }], "Mask should cover the whole recording by default.");
        var seek = new Point(9 + (timeline.ActualWidth - 18) * 1.5 / 5, 19);
        await Drag(timeline, seek, seek);
        var clock = Descendants<TextBlock>(panel).Single(t => AutomationProperties.GetName(t) == "当前播放时间");
        Invoke(ButtonNamed(panel, "上一帧"));
        await Until(() => clock.Text.StartsWith("1.400"), "previous frame");
        Invoke(ButtonNamed(panel, "下一帧"));
        await Until(() => clock.Text.StartsWith("1.467"), "next frame");
        Invoke(ButtonNamed(panel, "下一帧"));
        await Until(() => clock.Text.StartsWith("1.533"), "source frame at 23/15");
        Invoke(ButtonNamed(panel, "仅此帧"));
        await Until(() => ink.Items[0].Start > 1.53 && ink.Items[0].End <= 1.600001, "one-frame interval");
        Invoke(ButtonNamed(panel, "撤销"));
        await Until(() => ink.Items[0].End == 5, "undo range");
        Invoke(ButtonNamed(panel, "重做"));
        await Until(() => ink.Items[0].End < 2, "redo range");
        Snapshot((FrameworkElement)panel.Content, Path.Combine(folder, "recording-timeline.png"));

        async Task<string> Copy(string title, string extension)
        {
            string? old = Clipboard.GetFileDropList().Cast<string>().FirstOrDefault();
            Invoke(ButtonNamed(panel, title));
            await Until(() =>
            {
                var problem = Descendants<TextBlock>(panel).FirstOrDefault(t => t.Text.StartsWith("导出失败"));
                Require(problem == null, problem?.Text ?? "");
                return Clipboard.GetFileDropList().Cast<string>().Any(p => p != old && p.EndsWith(extension));
            }, title, 90);
            return Clipboard.GetFileDropList()[0]!;
        }
        var gifPath = await Copy("复制 GIF", ".gif");
        using (var gif = new MagickImageCollection(gifPath))
        {
            Require(gif.Sum(f => (int)f.AnimationDelay) == 200, "Inserting mask boundaries extended the GIF.");
            gif.Coalesce();
            int position = 0, covered = 0;
            foreach (var image in gif)
            {
                int next = position + (int)image.AnimationDelay;
                bool masked = position < 60 && next > 53;
                using var pixels = image.GetPixels();
                var color = pixels.GetPixel((int)image.Width / 2, (int)image.Height / 2).ToColor()!;
                Require((Math.Max(color.R, Math.Max(color.G, color.B)) < 10) == masked, $"Wrong GIF center pixel at {position} cs.");
                if (masked) covered += next - position;
                position = next;
            }
            Require(covered == 7, "A source frame between 10 FPS samples was lost.");
        }
        string savedGif = Path.Combine(folder, "annotated.gif");
        var saveGif = await GifMenu(panel, "保存 GIF…");
        await SaveThroughDialog(panel, savedGif, () =>
            ((IInvokeProvider)new MenuItemAutomationPeer(saveGif).GetPattern(PatternInterface.Invoke)!).Invoke());
        Require(File.ReadAllBytes(savedGif).SequenceEqual(File.ReadAllBytes(gifPath)), "Saved and copied annotation GIFs differ.");
        var mp4 = await Copy("复制视频", ".mp4");
        await CheckMoviePixels(mp4, 1);
        string savedVideo = Path.Combine(folder, "annotated.mp4");
        await SaveThroughDialog(panel, savedVideo, () => Invoke(ButtonNamed(panel, "保存视频…")));
        await CheckMoviePixels(savedVideo, 1);
        Invoke(ButtonNamed(panel, "恢复全段"));
        await Until(() => Descendants<TextBox>(panel).Any(b => AutomationProperties.GetName(b) == "结束秒数" && b.Text == "5"), "reset full range");
        await CheckMoviePixels(await Copy("复制视频", ".mp4"), 0);
        Console.WriteLine("PASS source frame 23/15 appears only at 53–60 cs of the trimmed GIF, and in trimmed and full MP4. Native save dialogs and clipboard exports agree.");
    }

    private static async Task CheckMoviePixels(string path, int trimStart)
    {
        var movie = new MediaComposition();
        movie.Clips.Add(await MediaClip.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(path)));
        foreach (var (sourceTime, black) in new[] { (1.44, false), (1.54, true), (1.68, false) })
        {
            using var stream = await movie.GetThumbnailAsync(TimeSpan.FromSeconds(sourceTime - trimStart), 320, 180, VideoFramePrecision.NearestFrame);
            var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
            var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, new BitmapTransform(),
                ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
            var pixels = data.DetachPixelData();
            int at = (90 * 320 + 160) * 4;
            Require((Math.Max(pixels[at], Math.Max(pixels[at + 1], pixels[at + 2])) < 20) == black,
                $"MP4 center pixel wrong at source time {sourceTime} ({pixels[at]}, {pixels[at + 1]}, {pixels[at + 2]}).");
        }
    }

    private static async Task CheckStaticFrameEdits(string folder)
    {
        // Only one captured JPEG backs every sample. A one-frame mask at 60 FPS
        // must appear between the 10 FPS ticks and clear again on that same JPEG.
        var frames = new RecordingFrames(64, 48);
        var image = BitmapSource.Create(64, 48, 96, 96, PixelFormats.Bgra32, null, Enumerable.Repeat((byte)255, 64 * 48 * 4).ToArray(), 64 * 4);
        frames.Add(TimeSpan.Zero, image);
        frames.Stop();
        await frames.Completion;
        using var preview = new RecordingPreview(frames, TimeSpan.FromSeconds(.3), 60, null);
        RecordingMark[] marks = [
            new(new(AnnotationTool.Privacy, new[] { new Point(20, 12), new Point(40, 32) }, new() { Color = Colors.Black }), 2d / 60, 3d / 60),
            new(new(AnnotationTool.Arrow, new[] { new Point(4, 18), new Point(46, 18) }, new() { Color = Colors.Red, LineWidth = 4 }), .1, .2),
            new(new(AnnotationTool.Text, new[] { new Point(1, 1), new Point(60, 44) }, new() { Color = Colors.Black, FontSize = 28 }, "A"), .2, .3)
        ];
        var layers = RecordingOverlay.Prepare(marks, image, 0, .3, 64, 48, true);
        string path = Path.Combine(folder, "single-frame-60fps.gif");
        typeof(RecordingPreview).GetMethod("SaveGif", Private)!.Invoke(preview, [path, 0d, .3, 10, 64, CancellationToken.None, layers]);
        using var gif = new MagickImageCollection(path);
        gif.Coalesce();
        int tick = 0;
        foreach (var frame in gif)
        {
            using var pixels = frame.GetPixels();
            var center = pixels.GetPixel(28, 23).ToColor()!;
            Require((center.R < 10) == (tick == 3) || tick == 20, "Lost mask boundary on an unchanged source frame.");
            if (tick == 3) Require(frame.AnimationDelay == 2, "One 60 FPS frame should occupy two centiseconds here.");
            if (tick == 10)
            {
                var arrow = pixels.GetPixel(15, 18).ToColor()!;
                Require(arrow.R > 240 && arrow.G < 20, "Vector arrow did not reach the rendered frame.");
            }
            if (tick == 20)
                Require(frame.ToByteArray(MagickFormat.Rgb).Count(b => b < 80) > 40, "Text did not reach the rendered frame.");
            tick += (int)frame.AnimationDelay;
        }
        Require(gif.Count == 5 && tick == 30, "Wrong number or duration of timed edits on a held frame.");
        Console.WriteLine("PASS held source frame, 60 FPS mask at 3–5 cs, arrow, text and exact 30 cs duration at 10 FPS output.");
    }

    private delegate bool EnumWindow(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumThreadWindows(uint thread, EnumWindow callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern IntPtr GetLastActivePopup(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int length);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder name, int length);

    private static async Task SaveThroughDialog(Window window, string path, Action start)
    {
        // Drive the standard Windows file picker on a worker while WPF runs its modal loop.
        var owner = new WindowInteropHelper(window).Handle;
        var thread = GetWindowThreadProcessId(owner, out _);
        var picker = Task.Run(() =>
        {
            var timer = Stopwatch.StartNew();
            IntPtr handle = IntPtr.Zero;
            while (handle == IntPtr.Zero)
            {
                var names = new List<string>();
                bool Inspect(IntPtr hwnd, IntPtr unused)
                {
                    if (!IsWindowVisible(hwnd)) return true;
                    var type = new StringBuilder(140);
                    var title = new StringBuilder(140);
                    GetClassName(hwnd, type, type.Capacity);
                    GetWindowText(hwnd, title, title.Capacity);
                    names.Add(type + "=" + title);
                    if (type.ToString() != "#32770") return true;
                    handle = hwnd;
                    return false;
                }
                Inspect(GetLastActivePopup(owner), IntPtr.Zero);
                if (handle == IntPtr.Zero) EnumThreadWindows(thread, Inspect, IntPtr.Zero);
                Require(timer.Elapsed.TotalSeconds < 20, "Save dialog missing. Open windows: " + string.Join(", ", names));
                if (handle == IntPtr.Zero) Thread.Sleep(70);
            }
            var dialog = AutomationElement.FromHandle(handle);
            try
            {
                var condition = new AndCondition(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
                    new PropertyCondition(AutomationElement.AutomationIdProperty, "1001"));
                AutomationElement? edit;
                while ((edit = dialog.FindFirst(TreeScope.Descendants, condition)) == null)
                {
                    Require(timer.Elapsed.TotalSeconds < 25, "Save dialog did not show its filename control.");
                    Thread.Sleep(70);
                }
                ((ValuePattern)edit.GetCurrentPattern(ValuePattern.Pattern)).SetValue(path);
                var save = dialog.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, "1"));
                ((InvokePattern)save.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
            }
            catch
            {
                if (dialog.TryGetCurrentPattern(WindowPattern.Pattern, out var windowPattern)) ((WindowPattern)windowPattern).Close();
                throw;
            }
        });
        _ = window.Dispatcher.InvokeAsync(start);
        await picker;
        await Until(() => File.Exists(path) && new FileInfo(path).Length > 0, "save " + Path.GetFileName(path), 90);
    }
}

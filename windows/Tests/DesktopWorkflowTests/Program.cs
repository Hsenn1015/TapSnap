using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ImageMagick;
using TapSnap.Windows;

internal static partial class Program
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 3) throw new ArgumentException("Expected v0.2.3 TapSnap.dll, fixture artwork and output folder.");
        args[2] = Path.GetFullPath(args[2]);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += async (_, _) =>
        {
            try
            {
                Directory.CreateDirectory(args[2]);
                // Initialize the production WPF resources before loading the old
                // encoder, whose assembly has the same name and pack URI.
                using var host = new TapSnapHost(app);
                var legacy = new AssemblyLoadContext("v0.2.3").LoadFromAssemblyPath(Path.GetFullPath(args[0]));
                var before = Export(legacy, args[1], Path.Combine(args[2], "v0.2.3.gif"));
                var after = Export(typeof(RecordingPreview).Assembly, args[1], Path.Combine(args[2], "current.gif"));
                var json = JsonSerializer.Serialize(new { before.Report, Current = after.Report }, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(Path.Combine(args[2], "gif-comparison.json"), json);
                Console.WriteLine(json);
                Require(after.Report.Bytes < before.Report.Bytes * .60, "Expected at least 40% savings on this desktop recording.");
                Require(after.Report.MeanRgbError <= before.Report.MeanRgbError + 2, "GIF color error regressed.");
                using var preview = (RecordingPreview)after.Preview;
                await CheckStaticFrameEdits(args[2]);
                await CheckEditorZoom();
                await CheckSelection(host, args[2]);
                await CheckHistoryFilters(host, args[2]);
                await CheckClipboard(preview, Path.Combine(args[2], "current.gif"));
                Console.WriteLine("PASS selection dock, one-click editor handoff and recording clipboard.");
                app.Shutdown(0);
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                app.Shutdown(1);
            }
        };
        return app.Run();
    }

    private sealed record Measurement(long Bytes, long EncodingMs, int Width, int Height, int Frames, int Centiseconds, double MeanRgbError);

    // Run each version's own JPEG spool, sampler and GIF writer. Only the timed
    // SaveGif call is measured. Waiting for the spool keeps all 75 input samples.
    private static (object Preview, Measurement Report) Export(Assembly assembly, string artwork, string target)
    {
        var type = assembly.GetType("TapSnap.Windows.RecordingFrames", true)!;
        var frames = Activator.CreateInstance(type, GifFixture.Width, GifFixture.Height)!;
        var add = type.GetMethod("Add")!;
        var count = type.GetProperty("Count")!;
        int i = 0;
        foreach (var pixels in GifFixture.Frames(artwork))
        {
            var shot = BitmapSource.Create(GifFixture.Width, GifFixture.Height, 96, 96, PixelFormats.Bgra32, null, pixels, GifFixture.Width * 4);
            shot.Freeze();
            add.Invoke(frames, [TimeSpan.FromTicks(TimeSpan.TicksPerSecond * i / GifFixture.Fps), shot]);
            i++;
            Require(SpinWait.SpinUntil(() => (int)count.GetValue(frames)! == i, 10000), "Recording spool dropped a fixture frame.");
        }
        type.GetMethod("Stop")!.Invoke(frames, null);
        ((Task)type.GetProperty("Completion")!.GetValue(frames)!).GetAwaiter().GetResult();
        var previewType = assembly.GetType("TapSnap.Windows.RecordingPreview", true)!;
        var preview = Activator.CreateInstance(previewType, frames, TimeSpan.FromSeconds(5), GifFixture.Fps, null)!;
        var write = previewType.GetMethod("SaveGif", Private)!;
        var timer = Stopwatch.StartNew();
        object[] arguments = [target, 0d, 5d, GifFixture.Fps, 1280, CancellationToken.None];
        write.Invoke(preview, assembly == typeof(RecordingPreview).Assembly ? [.. arguments, Array.Empty<RecordingOverlay>()] : arguments);
        timer.Stop();
        if (assembly != typeof(RecordingPreview).Assembly) type.GetMethod("Clean")!.Invoke(frames, null);
        using var gif = new MagickImageCollection(target);
        Require(gif[0].AnimationIterations == 0, "GIF must loop.");
        int duration = gif.Sum(f => (int)f.AnimationDelay);
        Require(duration == 500, "GIF did not preserve the 5-second duration.");
        gif.Coalesce();
        Require(gif[0].Width == GifFixture.Width && gif[0].Height == GifFixture.Height, "Output resolution changed.");
        int current = 0, until = (int)gif[0].AnimationDelay;
        long error = 0, samples = 0;
        i = 0;
        foreach (var frame in GifFixture.Frames(artwork))
        {
            double center = (i++ + .5) * 100 / GifFixture.Fps;
            while (center >= until && current + 1 < gif.Count) until += (int)gif[++current].AnimationDelay;
            if (i % 7 != 1 && i != GifFixture.Count) continue;
            var decoded = gif[current].ToByteArray(MagickFormat.Bgra);
            for (int j = 0; j < frame.Length; j += 4)
                for (int c = 0; c < 3; c++) error += Math.Abs(frame[j + c] - decoded[j + c]);
            samples += frame.Length / 4 * 3;
        }
        var report = new Measurement(new FileInfo(target).Length, timer.ElapsedMilliseconds, GifFixture.Width, GifFixture.Height,
            gif.Count, duration, Math.Round((double)error / samples, 3));
        return (preview, report);
    }

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    private static async Task CheckEditorZoom()
    {
        const int width = 600, height = 400;
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, new byte[width * height * 4], width * 4);
        var editor = new EditorWindow(bitmap, _ => { }, _ => { }, _ => { }, () => { }, () => { }, _ => { })
            { Width = 520, Height = 410 };
        editor.ApplyOperationHotkeys(new Dictionary<string, Hotkey>(OperationShortcut.Defaults)
        {
            [OperationShortcut.FitImage.Id] = new(0, (uint)KeyInterop.VirtualKeyFromKey(Key.F6))
        });
        editor.Show();
        try
        {
            editor.UpdateLayout();
            var viewport = Descendants<ScrollViewer>(editor).Single();
            var canvas = Descendants<AnnotationSurface>(viewport).Single();
            var controls = Descendants<Button>(editor).Where(button => AutomationProperties.GetName(button) is "适合窗口" or "放大画布")
                .ToDictionary(AutomationProperties.GetName);
            double fitScale = canvas.Scale;
            Require(viewport.ScrollableWidth == 0 && viewport.ScrollableHeight == 0, "Fit should show the whole image.");
            var center = new Point(viewport.ViewportWidth / 2, viewport.ViewportHeight / 2);
            Point original = canvas.ToImage(viewport.TranslatePoint(center, canvas));

            Invoke(controls["放大画布"]);
            await Until(() => canvas.Scale > fitScale && viewport.HorizontalOffset > 0 && viewport.VerticalOffset > 0,
                "zoom in around the viewport center");
            Point anchored = canvas.ToImage(viewport.TranslatePoint(center, canvas));
            Require((anchored - original).Length * canvas.Scale < 2, "Zoom moved the image point under the anchor.");
            viewport.ScrollToRightEnd();
            viewport.ScrollToBottom();
            await Until(() => Math.Abs(viewport.HorizontalOffset - viewport.ScrollableWidth) < 1 &&
                Math.Abs(viewport.VerticalOffset - viewport.ScrollableHeight) < 1, "bottom-right of enlarged image");

            var crop = new Rect(23, 31, 103, 79);
            editor.RestoreDraft(new EditorWindow.Draft(bitmap, DateTime.Now, [], crop));
            BitmapSource full = canvas.Render(crop: false), cropped = canvas.Render(crop: true);
            Require(full.PixelWidth == width && full.PixelHeight == height && cropped.PixelWidth == crop.Width &&
                cropped.PixelHeight == crop.Height, "Zoom changed the export or crop dimensions.");

            Require(controls["适合窗口"].ToolTip is ToolTip { Content: "适合窗口 F6" }, "Fit hint did not update to the recorded key.");
            Press(editor, Key.F6);
            await Until(() => Math.Abs(canvas.Scale - fitScale) < .001 && viewport.ScrollableWidth == 0 &&
                viewport.ScrollableHeight == 0, "restore fit and remove both scroll ranges");
            Console.WriteLine("PASS image zoom anchor, viewport edges, original crop pixels and reset to fit.");
        }
        finally { editor.Close(); }
    }

    private static async Task CheckSelection(TapSnapHost host, string output)
    {
        var shortcuts = (Dictionary<string, (string Title, Action Action)>)typeof(TapSnapHost).GetField("hotkeyActions", Private)!.GetValue(host)!;
        async Task<(SelectionWindow Overlay, Task Opening)> DrawSelection()
        {
            var opening = Application.Current.Dispatcher.InvokeAsync(shortcuts["capture"].Action);
            await Until(() => Application.Current.Windows.OfType<SelectionWindow>().Any(w => w.IsVisible), "selection window");
            var overlay = Application.Current.Windows.OfType<SelectionWindow>().First(w => w.IsVisible);
            var screen = Desktop.Monitors().First().Bounds;
            var canvas = (Canvas)overlay.Content;
            Require(SetCursorPos(screen.Left + 60, screen.Top + 80), "Cannot set cursor on the capture desktop.");
            canvas.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left)
                { RoutedEvent = UIElement.MouseLeftButtonDownEvent });
            Require(SetCursorPos(screen.Left + screen.Width * 2 / 3, screen.Top + screen.Height / 2), "Cannot move cursor.");
            canvas.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount) { RoutedEvent = Mouse.MouseMoveEvent });
            canvas.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left)
                { RoutedEvent = UIElement.MouseLeftButtonUpEvent });
            overlay.UpdateLayout();
            return (overlay, opening.Task);
        }

        var (overlay, opening) = await DrawSelection();
        var canvas = (Canvas)overlay.Content;
        var dock = Descendants<Border>(canvas).Single(b => AutomationProperties.GetName(b) == "标注工具栏");
        Require(dock.IsVisible && dock.ActualWidth > 0 && dock.ActualHeight == 44, "Dock missing on first drag release.");
        var buttons = Descendants<Button>(dock).ToDictionary(AutomationProperties.GetName);
        foreach (var name in new[] { "箭头", "编辑 ↵", "长截图", "录屏", "更多工具与操作", "复制 Ctrl+C" })
            Require(buttons.ContainsKey(name), "Missing first-stage button " + name);
        Require(buttons["箭头"].ToolTip is ToolTip { Content: "箭头 A" }, "Arrow button does not show its key.");
        var size = new Size(Math.Ceiling(dock.ActualWidth), Math.Ceiling(dock.ActualHeight));
        var visual = new DrawingVisual();
        using (var graphics = visual.RenderOpen()) graphics.DrawRectangle(new VisualBrush(dock), null, new Rect(size));
        var bitmap = new RenderTargetBitmap((int)size.Width, (int)size.Height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(bitmap));
        using (var file = File.Create(Path.Combine(output, "selection-toolbar.png"))) png.Save(file);
        Invoke(buttons["箭头"]);
        await Until(() => Application.Current.Windows.OfType<EditorWindow>().Any(w => w.IsVisible), "editor after selecting arrow");
        await opening;
        var editor = Application.Current.Windows.OfType<EditorWindow>().Single(w => w.IsVisible);
        Require(Equals(typeof(EditorWindow).GetField("tool", Private)!.GetValue(editor), AnnotationTool.Arrow),
            "Editor did not start with arrow selected.");
        editor.Close();
        Console.WriteLine("PASS native screenshot action, drag, first-stage toolbar PNG, editor with arrow selected.");

        var (shortcutOverlay, shortcutOpening) = await DrawSelection();
        Press(shortcutOverlay, Key.W);
        await Until(() => Application.Current.Windows.OfType<EditorWindow>().Any(w => w.IsVisible), "editor after watermark shortcut");
        await shortcutOpening;
        var shortcutEditor = Application.Current.Windows.OfType<EditorWindow>().Single(w => w.IsVisible);
        var selectedTool = typeof(EditorWindow).GetField("tool", Private)!;
        Require(Equals(selectedTool.GetValue(shortcutEditor), AnnotationTool.Watermark), "W did not select the overflow tool.");
        Press(shortcutEditor, Key.B);
        Require(Equals(selectedTool.GetValue(shortcutEditor), AnnotationTool.Pen), "B did not switch to the brush in the editor.");
        shortcutEditor.Close();
        Console.WriteLine("PASS stage-one watermark shortcut and in-editor brush shortcut.");
    }

    private static async Task CheckClipboard(RecordingPreview preview, string saved)
    {
        Clipboard.Clear();
        preview.Show();
        var panel = Application.Current.Windows.Cast<Window>().Single(w => w.Title == "录屏预览");
        panel.UpdateLayout();
        var copy = Descendants<Button>(panel).Single(b => Equals(b.Content, "复制 GIF"));
        Invoke(copy);
        await Until(() => Clipboard.ContainsData("GIF") && Clipboard.ContainsFileDropList(), "GIF clipboard formats", 90);
        var file = Clipboard.GetFileDropList().Cast<string>().Single();
        using var data = (Stream)Clipboard.GetData("GIF")!;
        using var memory = new MemoryStream();
        data.CopyTo(memory);
        var bytes = File.ReadAllBytes(file);
        Require(bytes.SequenceEqual(memory.ToArray()) && bytes.SequenceEqual(File.ReadAllBytes(saved)),
            "Clipboard bytes, its file and the regular GIF export differ.");
        Console.WriteLine($"PASS Windows clipboard GIF bytes and file match saved export ({bytes.Length} bytes).");

        // Exercise the same trim controls and downscaling as the preview UI.
        EditField(panel, "开始秒数", "1");
        EditField(panel, "结束秒数", "3");
        await GifOption(panel, "最长边", "640 像素");
        Invoke(copy);
        await Until(() => Clipboard.GetFileDropList().Cast<string>().Any(p => p != file && p.EndsWith(".gif")),
            "cropped and resized GIF", 90);
        using (var trimmed = new MagickImageCollection(Clipboard.GetFileDropList()[0]!))
            Require(trimmed[0].Width == 640 && trimmed[0].Height == 360 && trimmed.Sum(f => (int)f.AnimationDelay) == 200,
                "Preview range or GIF downscaling was lost.");
        Console.WriteLine("PASS selected GIF range 1–3 s, 640 × 360, exactly two seconds.");

        var videoButton = Descendants<Button>(panel).Single(b => Equals(b.Content, "复制视频"));
        Invoke(videoButton);
        await Until(() =>
        {
            var status = Descendants<TextBlock>(panel).FirstOrDefault(t => t.Text.StartsWith("导出失败"));
            Require(status == null, status?.Text ?? "");
            return Clipboard.GetFileDropList().Cast<string>().Any(p => p.EndsWith(".mp4"));
        }, "trimmed MP4 clipboard file", 90);
        var video = await Windows.Storage.StorageFile.GetFileFromPathAsync(Clipboard.GetFileDropList()[0]!);
        var info = await video.Properties.GetVideoPropertiesAsync();
        Require(Math.Abs(info.Duration.TotalSeconds - 2) < .1 && !Clipboard.ContainsData("GIF"),
            "MP4 clipboard file did not preserve the selected range.");
        Console.WriteLine($"PASS copied MP4 duration {info.Duration.TotalSeconds:F2} s.");
        await CheckTimedAnnotation(panel, Path.GetDirectoryName(saved)!);
        panel.Close();
    }

    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T match) yield return match;
            foreach (var nested in Descendants<T>(child)) yield return nested;
        }
    }

    private static void Invoke(Button button) =>
        ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)!).Invoke();

    private static void Press(Window window, Key key)
    {
        var source = PresentationSource.FromVisual(window) ?? throw new InvalidOperationException("Window not ready for key input.");
        var args = new KeyEventArgs(Keyboard.PrimaryDevice, source, Environment.TickCount, key)
            { RoutedEvent = Keyboard.PreviewKeyDownEvent };
        window.RaiseEvent(args);
        Require(args.Handled, $"The toolbar did not handle {key}.");
    }

    private static async Task Until(Func<bool> predicate, string description, int seconds = 15)
    {
        var timer = Stopwatch.StartNew();
        while (!predicate())
        {
            Require(timer.Elapsed.TotalSeconds < seconds, "Timed out waiting for " + description);
            await Task.Delay(50);
        }
    }

    private static void Require(bool passed, string detail)
    {
        if (!passed) throw new InvalidOperationException(detail);
    }
}

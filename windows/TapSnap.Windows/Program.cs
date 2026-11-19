using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Media;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using DrawingRect = System.Drawing.Rectangle;
using Forms = System.Windows.Forms;

namespace TapSnap.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var single = new Mutex(true, @"Local\TapSnap.Windows", out bool owns);
        if (!owns) return;
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        using var host = new TapSnapHost(app);
        app.SessionEnding += (_, _) => host.PrepareToExit();
        app.Run();
    }
}

internal sealed class TapSnapHost : IDisposable
{
    private readonly Application app;
    private readonly Settings settings = Settings.Load();
    private readonly Shortcuts shortcuts = new();
    private readonly ClipboardHistory history = new();
    private readonly PinManager pins = new();
    private readonly StatusToast toast = new();
    private readonly Forms.NotifyIcon tray;
    private readonly Dictionary<string, (string Title, Action Action)> hotkeyActions;
    private readonly Dictionary<string, Forms.ToolStripMenuItem> hotkeyMenu = new();
    private readonly HashSet<string> conflicts = new();
    private readonly HashSet<string> priorityHotkeys = new();
    private DrawingRect? lastSelection;
    private Window? settingsWindow;
    private Window? desktopBar;
    private Window? toolBall;
    private Window? clipboardWindow;
    private LongShotWindow? longShot;
    private RecordingWindow? recording;
    private RecordingPreview? recent;
    private EditorWindow.Draft? recentScreenshot;
    private EditorWindow? recentEditor;
    private long captureSequence;
    private bool selecting;
    private bool exiting;

    public TapSnapHost(Application application)
    {
        app = application;
        SnapTheme.Initialize(app, settings.DarkTheme);
        hotkeyActions = new()
        {
            ["capture"] = ("截图", () => Select(CaptureAction.Edit)),
            ["capturePin"] = ("截图并贴图", () => Select(CaptureAction.Pin)),
            ["clipboardPin"] = ("贴图（剪贴板）", PinClipboard),
            ["longShot"] = ("滚动长截图", () => Select(CaptureAction.LongShot)),
            ["record"] = ("屏幕录制", ToggleRecording),
            ["ocr"] = ("文字识别", () => Select(CaptureAction.Text)),
            ["history"] = ("剪贴板历史", ToggleHistory),
            ["ocrFull"] = ("全屏文字识别", () => RecognitionService.OpenResult(Desktop.Capture(Desktop.CursorMonitor), RecognitionMode.Text)),
            ["toolBall"] = ("显示／隐藏悬浮球", () => ToggleDesktop(true))
        };
        var menu = new Forms.ContextMenuStrip { ShowImageMargin = false };
        SnapTrayMenu.Style(menu);
        void Add(string title, Action action, string? key = null)
        {
            var row = menu.Items.Add(title, null, (_, _) => Invoke(action));
            row.Padding = new Forms.Padding(6, 2, 6, 2);
            if (key != null) hotkeyMenu[key] = (Forms.ToolStripMenuItem)row;
        }
        void Shortcut(string key)
        {
            var item = hotkeyActions[key];
            Add(item.Title, item.Action, key);
        }
        void Separator() => menu.Items.Add(new Forms.ToolStripSeparator());
        Shortcut("capture");
        Add("隐私截图", () => Select(CaptureAction.Privacy));
        Shortcut("capturePin");
        Add("窗口截图", () => Select(CaptureAction.Edit, windowOnly: true));
        Add("全屏截图", () => Capture(Desktop.CursorMonitor));
        Add("截图预设…", ShowPresets);
        Add("延时截图（3 秒）", DelayCapture);
        Add("编辑最近截图", EditRecentScreenshot);
        Add("编辑剪贴板图片", () =>
        {
            if (Images.ClipboardImage() is { } image) EditImage(image);
            else if (Clipboard.GetFileDropList() is { Count: > 0 } paths && File.Exists(paths[0])) EditImage(Images.Read(paths[0]!));
            else Info("剪贴板中没有图片。");
        });
        Add("打开图片…", () => { if (Images.OpenImage() is { } image) EditImage(image); });
        Shortcut("clipboardPin");
        Separator();
        Shortcut("longShot");
        Shortcut("record");
        Add("最近录制／复制 GIF…", () => { if (recent == null) Info("当前还没有录制。"); else recent.Show(); });
        Shortcut("ocr");
        Shortcut("ocrFull");
        Add("二维码 / 条形码", () => Select(CaptureAction.Barcode));
        Add("截图翻译", () => Select(CaptureAction.Translation));
        Add("公式识别", () => Select(CaptureAction.Formula));
        Add("表格识别", () => Select(CaptureAction.Table));
        Separator();
        Add("隐藏／显示所有贴图", pins.Toggle);
        Add("恢复上次关闭的贴图", () => { if (!pins.Restore()) Info("没有可恢复的贴图。"); });
        Add("贴图分组", pins.Groups);
        Shortcut("history");
        Separator();
        Add("设置…", ShowSettings);
        Add("桌面工具栏", () => ToggleDesktop(false));
        Shortcut("toolBall");
        Add("使用指南", ShowGuide);
        Add("权限检查", CheckCapture);
        Add("关于 TapSnap", () => Info("TapSnap · Windows"));
        Add("退出", () => { PrepareToExit(); app.Shutdown(); });

        using var iconStream = Application.GetResourceStream(new Uri("pack://application:,,,/TapSnap.ico"))?.Stream;
        tray = new Forms.NotifyIcon
        {
            Text = "TapSnap", Icon = iconStream == null ? System.Drawing.SystemIcons.Application : new System.Drawing.Icon(iconStream),
            ContextMenuStrip = menu, Visible = true
        };
        tray.DoubleClick += (_, _) => Invoke(hotkeyActions["capture"].Action);
        BindHotkeys();
        if (settings.ShowDesktopToolbar) ShowDesktop(false);
        if (settings.ShowToolBall) ShowDesktop(true);
    }

    private void BindHotkeys()
    {
        conflicts.Clear();
        priorityHotkeys.Clear();
        for (int slot = 1; slot <= hotkeyActions.Count; slot++) shortcuts.Unbind(slot);
        int id = 0;
        foreach (var (key, definition) in hotkeyActions)
        {
            int slot = ++id;
            var menu = hotkeyMenu[key];
            if (!settings.Hotkeys.TryGetValue(key, out var combination))
            {
                menu.Text = definition.Title;
                menu.ShortcutKeyDisplayString = "";
                continue;
            }
            if (!shortcuts.Bind(slot, combination, () => Invoke(definition.Action), settings.PreferPriorityHotkeys, out bool priority))
                conflicts.Add(key);
            if (priority) priorityHotkeys.Add(key);
            menu.Text = definition.Title + (conflicts.Contains(key) ? "（快捷键冲突）" : priority ? "（优先响应）" : "");
            menu.ShortcutKeyDisplayString = Shortcuts.Display(combination);
        }
    }

    private void Invoke(Action action)
    {
        try { action(); }
        catch (Exception error) { Info(error.Message, error: true); }
    }

    private async void DelayCapture()
    {
        await Task.Delay(TimeSpan.FromSeconds(3));
        Invoke(() => Select(CaptureAction.Edit));
    }

    private void Select(CaptureAction action, bool windowOnly = false, Action<Selection>? accept = null)
    {
        if (selecting) return;
        selecting = true;
        Selection? selection;
        try
        {
            Desktop.Flush();
            toast.Dismiss();
            selection = SelectionWindow.Select(action, settings, windowOnly, preset: accept != null);
        }
        finally { selecting = false; }
        if (selection == null) return;
        lastSelection = selection.ScreenRegion;
        if (accept != null) accept(selection);
        else Complete(selection);
    }

    private void Capture(DrawingRect region, CapturePreset? preset = null)
    {
        toast.Dismiss();
        Complete(new Selection(Desktop.CaptureDesktop(region, settings.HideDesktopIcons), region, CaptureAction.Edit), preset);
    }

    private void CopyImage(BitmapSource image)
    {
        Images.Copy(image);
        toast.Show("已复制");
    }

    private void Complete(Selection shot, CapturePreset? preset = null)
    {
        bool autoPrivacy = shot.RequiresPrivacy || RecognitionService.ShouldScanAutomatically;
        if (shot.Action is not (CaptureAction.LongShot or CaptureAction.Record))
        {
            ++captureSequence;
            recentEditor = null;
            recentScreenshot = autoPrivacy || shot.Action == CaptureAction.Privacy ? null :
                new EditorWindow.Draft(shot.Image, shot.CapturedAt, [], null);
        }
        if (settings.ShutterSound && shot.Action is not (CaptureAction.LongShot or CaptureAction.Record))
            SystemSounds.Asterisk.Play();
        void Recognize(RecognitionMode mode)
        {
            if (autoPrivacy) OpenEditor(shot.Image, shot.ScreenRegion, true,
                output => RecognitionService.OpenResult(output, mode), completionTitle: shot.Action switch
                {
                    CaptureAction.Text => "文字识别", CaptureAction.Barcode => "二维码／条码", CaptureAction.Table => "表格识别",
                    CaptureAction.Translation => "翻译", CaptureAction.Formula => "公式识别", _ => "完成"
                }, captureID: captureSequence, capturedAt: shot.CapturedAt);
            else RecognitionService.OpenResult(shot.Image, mode);
        }
        switch (shot.Action)
        {
            case CaptureAction.Edit:
            case CaptureAction.Privacy:
                OpenEditor(shot.Image, shot.ScreenRegion, shot.Action == CaptureAction.Privacy || autoPrivacy, preset: preset,
                    captureID: captureSequence, capturedAt: shot.CapturedAt, initialTool: shot.InitialTool);
                break;
            case CaptureAction.Copy:
                if (autoPrivacy) OpenEditor(shot.Image, shot.ScreenRegion, true, CopyImage, completionTitle: "复制",
                    captureID: captureSequence, capturedAt: shot.CapturedAt);
                else CopyImage(shot.Image);
                break;
            case CaptureAction.Pin:
                if (autoPrivacy) OpenEditor(shot.Image, shot.ScreenRegion, true, pins.Add, completionTitle: "贴图",
                    captureID: captureSequence, capturedAt: shot.CapturedAt);
                else pins.Add(shot.Image);
                break;
            case CaptureAction.Save:
                if (autoPrivacy || !Images.SaveWithDialog(shot.Image, settings.OutputFolder, preset?.SaveFormat ?? settings.SaveFormat))
                    OpenEditor(shot.Image, shot.ScreenRegion, autoPrivacy, preset: preset,
                        completionTitle: autoPrivacy ? "保存…" : null, captureID: captureSequence, capturedAt: shot.CapturedAt,
                        saveOnConfirm: autoPrivacy);
                break;
            case CaptureAction.Print:
                if (autoPrivacy) OpenEditor(shot.Image, shot.ScreenRegion, true, i => EditorWindow.PrintImage(i, "TapSnap"),
                    completionTitle: "打印", captureID: captureSequence, capturedAt: shot.CapturedAt);
                else EditorWindow.PrintImage(shot.Image, "TapSnap");
                break;
            case CaptureAction.LongShot: StartLongShot(shot.ScreenRegion, shot.RequiresPrivacy); break;
            case CaptureAction.Record: StartRecording(shot.ScreenRegion); break;
            case CaptureAction.Text: Recognize(RecognitionMode.Text); break;
            case CaptureAction.Barcode: Recognize(RecognitionMode.Barcode); break;
            case CaptureAction.Table: Recognize(RecognitionMode.Table); break;
            case CaptureAction.Translation: Recognize(RecognitionMode.Translation); break;
            case CaptureAction.Formula: Recognize(RecognitionMode.Formula); break;
        }
    }

    private void EditImage(BitmapSource image) => OpenEditor(image, null, RecognitionService.ShouldScanAutomatically);

    private void EditRecentScreenshot()
    {
        if (recentScreenshot == null) { Info("还没有可编辑的最近截图。"); return; }
        if (recentEditor is { IsVisible: true }) { recentEditor.Activate(); return; }
        OpenEditor(recentScreenshot.Image, null, RecognitionService.ShouldScanAutomatically, captureID: ++captureSequence,
            capturedAt: recentScreenshot.CapturedAt, restoring: recentScreenshot);
    }

    private void OpenEditor(BitmapSource image, DrawingRect? region, bool scan, Action<BitmapSource>? reviewedOutput = null,
        CapturePreset? preset = null, string? completionTitle = null, bool longImage = false, long? captureID = null,
        DateTime? capturedAt = null, EditorWindow.Draft? restoring = null, bool saveOnConfirm = false, AnnotationTool? initialTool = null)
    {
        EditorWindow editor = null!;
        void Transfer(Action<DrawingRect> run, CaptureAction fallback)
        {
            if (region is { } r)
            {
                var crop = editor.PixelCrop;
                var selected = new DrawingRect(r.X + crop.X, r.Y + crop.Y, crop.Width, crop.Height);
                editor.Close();
                _ = app.Dispatcher.BeginInvoke(() =>
                {
                    Desktop.Flush();
                    if (Desktop.Monitors().Any(m => m.Bounds.Contains(selected))) Invoke(() => run(selected));
                    else Select(fallback);
                }, DispatcherPriority.Background);
            }
            else { editor.Close(); Select(fallback); }
        }
        editor = new EditorWindow(image, i => Invoke(() => CopyImage(i)),
            i => Invoke(() => { if (Images.SaveWithDialog(i, settings.OutputFolder, preset?.SaveFormat ?? settings.SaveFormat)) toast.Show("已保存"); }),
            i => Invoke(() => pins.Add(i)), () => Transfer(r => StartLongShot(r, scan || editor.LocalScanCompleted), CaptureAction.LongShot),
            () => Transfer(StartRecording, CaptureAction.Record), i => Scan(editor, i), settings.DarkTheme,
            settings.DefaultLineWidth, settings.DefaultFontSize, settings.DefaultMosaicBlockSize, settings.AutoMosaicFaces);
        editor.ApplyOperationHotkeys(settings.OperationHotkeys);
        editor.CapturedAt = capturedAt ?? DateTime.Now;
        if (restoring != null) editor.RestoreDraft(restoring);
        if (captureID.HasValue)
        {
            bool protectedDraft = scan;
            recentEditor = editor;
            editor.ProtectOriginal += () =>
            {
                protectedDraft = true;
                if (captureID == captureSequence) { recentScreenshot = null; recentEditor = null; }
            };
            editor.ReviewedOutput += output =>
            {
                if (captureID == captureSequence && protectedDraft)
                    recentScreenshot = new EditorWindow.Draft(output, editor.CapturedAt, [], null);
            };
            editor.Closing += (_, _) =>
            {
                if (captureID == captureSequence && !protectedDraft) recentScreenshot = editor.SaveDraft();
                if (recentEditor == editor) recentEditor = null;
            };
        }
        editor.SetCompletionAction(output =>
        {
            try
            {
                if (saveOnConfirm) return Images.SaveWithDialog(output, settings.OutputFolder, preset?.SaveFormat ?? settings.SaveFormat);
                if (reviewedOutput is not null) reviewedOutput(output);
                else if (settings.CopyAfterConfirm) Images.Copy(output);
                if (reviewedOutput is null && (preset?.AutoSave ?? settings.SaveAfterConfirm))
                {
                    Directory.CreateDirectory(settings.OutputFolder);
                    var format = preset?.SaveFormat ?? settings.SaveFormat;
                    Images.Save(output, Path.Combine(settings.OutputFolder, $"TapSnap-{DateTime.Now:yyyy-MM-dd-HHmmss-fff}.{format}"));
                    toast.Show(settings.CopyAfterConfirm ? "已复制并保存" : "已保存");
                }
                else if (reviewedOutput is null && settings.CopyAfterConfirm) toast.Show("已复制");
                return true;
            }
            catch (Exception error) { Info(error.Message, error: true); return false; }
        }, completionTitle);
        if (region is { } source) editor.AnchorToCapture(source, scan);
        editor.RegisterOutput("导出…", i => ImageOutputWindow.Export(editor, i, settings.OutputFolder, preset?.SaveFormat ?? settings.SaveFormat));
        editor.RegisterOutput("追加一张图片…", i =>
        {
            if (Images.OpenImage() is { } second && ImageOutputWindow.Combine(editor, i, second) is { } combined)
                OpenEditor(combined, null, scan || editor.LocalScanCompleted || RecognitionService.ShouldScanAutomatically);
        });
        foreach (var (title, kind) in new[]
        {
            ("文字识别", RecognitionMode.Text), ("二维码／条码", RecognitionMode.Barcode),
            ("表格识别", RecognitionMode.Table), ("截图翻译", RecognitionMode.Translation), ("公式识别", RecognitionMode.Formula)
        })
            editor.RegisterOutput(title, i => RecognitionService.OpenResult(i, kind));
        editor.RegisterPrivacyActions(RecognitionService.OpenSettings, (i, crop) => ScanAi(editor, i, crop, false),
            (i, crop) => ScanAi(editor, i, crop, true));
        editor.RegisterMosaicDetection(RecognitionService.DetectMosaicAsync);
        editor.RegisterPrivacyControls(() => StopPrivacyScan(editor), () => RecognitionService.IsAiConfigured);
        editor.ConfigurePrivacyAppearance(settings.PrivacyMaskStyle, settings.PrivacyMaskPatternSize, settings.PrivacyMaskRgb,
            (style, size, rgb) =>
            {
                settings.PrivacyMaskStyle = style;
                settings.PrivacyMaskPatternSize = size;
                settings.PrivacyMaskRgb = rgb;
                settings.Save();
            });
        editor.Closed += (_, _) => StopPrivacyScan(editor);
        if (longImage) editor.UseLongShotLayout();
        editor.Show();
        if (initialTool is { } tool) editor.PickTool(tool);
        if (scan) Scan(editor, image);
    }

    private readonly Dictionary<EditorWindow, CancellationTokenSource> privacyScans = new();

    private void StopPrivacyScan(EditorWindow editor)
    {
        if (privacyScans.TryGetValue(editor, out var pending)) pending.Cancel();
    }

    private void Scan(EditorWindow editor, BitmapSource image)
    {
        if (privacyScans.ContainsKey(editor)) return;
        editor.BeginPrivacyReview();
        RunPrivacyScan(editor, "隐私扫描失败", async (update, token) =>
        {
            update.Report("正在扫描图片…");
            var matches = await RecognitionService.ScanPrivacyAsync(image, token);
            ApplyPrivacyMatches(editor, matches, 0, 0);
            if (!token.IsCancellationRequested) editor.LocalScanCompleted = true;
        });
    }

    private void ScanAi(EditorWindow editor, BitmapSource image, Int32Rect crop, bool visual)
    {
        if (privacyScans.ContainsKey(editor)) return;
        editor.BeginPrivacyReview(startsLocalScan: false);
        RunPrivacyScan(editor, "AI 补查失败", (update, token) =>
            RecognitionService.ScanPrivacyWithAiAsync(image, visual, editor,
                matches => ApplyPrivacyMatches(editor, matches, crop.X, crop.Y), update, token));
    }

    private async void RunPrivacyScan(EditorWindow editor, string title, Func<IProgress<string>, CancellationToken, Task> run)
    {
        if (privacyScans.ContainsKey(editor)) return;
        using var source = new CancellationTokenSource();
        privacyScans.Add(editor, source);
        editor.SetPrivacyScanning(true);
        var progress = new Progress<string>(message =>
        {
            if (!source.IsCancellationRequested && editor.IsLoaded && privacyScans.GetValueOrDefault(editor) == source)
                editor.SetPrivacyScanning(true, message);
        });
        try { await run(progress, source.Token); }
        catch (OperationCanceledException) when (source.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (editor.IsLoaded && !source.IsCancellationRequested)
                MessageBox.Show(editor, error.Message, title, MessageBoxButton.OK, MessageBoxImage.Information);
        }
        finally
        {
            privacyScans.Remove(editor);
            if (editor.IsLoaded) editor.SetPrivacyScanning(false);
        }
    }

    private static void ApplyPrivacyMatches(EditorWindow editor, IReadOnlyList<PrivacyCandidate> matches, int x, int y)
    {
        void Apply()
        {
            if (!editor.IsLoaded) return;
            Rect Translate(Rect rect) => new(rect.X + x, rect.Y + y, rect.Width, rect.Height);
            editor.AddPrivacyMasks(matches.Where(m => m.ApplyAutomatically).Select(m => Translate(m.Bounds)));
            editor.AddPrivacyCandidates(matches.Where(m => !m.ApplyAutomatically).Select(m => (m.Label, Translate(m.Bounds))));
        }

        if (editor.Dispatcher.CheckAccess()) Apply();
        else editor.Dispatcher.Invoke(Apply);
    }

    private void StartLongShot(DrawingRect region, bool forcePrivacy = false)
    {
        if (longShot != null) { longShot.Activate(); return; }
        Desktop.Flush();
        var panel = new LongShotWindow(region, Desktop.Capture, image => OpenEditor(image, null,
            forcePrivacy || RecognitionService.ShouldScanAutomatically, longImage: true), settings);
        longShot = panel;
        panel.Closed += (_, _) => longShot = null;
        panel.Show();
    }

    private void ToggleRecording()
    {
        if (recording != null) recording.Finish();
        else Select(CaptureAction.Record);
    }

    private void StartRecording(DrawingRect region)
    {
        if (recording != null) { recording.Activate(); return; }
        var panel = new RecordingWindow(region, settings, preview =>
        {
            recent?.Dispose();
            recent = preview;
            preview.Show();
        });
        recording = panel;
        panel.Closed += (_, _) => recording = null;
        panel.Show();
    }

    private void PinClipboard()
    {
        var image = Clipboard.GetImage();
        if (image == null) Info("剪贴板中没有图片。");
        else pins.Add(image);
    }

    private void ToggleHistory()
    {
        if (clipboardWindow != null) { clipboardWindow.Close(); return; }
        clipboardWindow = new ClipboardHistoryWindow(history, EditImage, settings.DarkTheme);
        clipboardWindow.Closed += (_, _) => clipboardWindow = null;
        clipboardWindow.Show();
    }

    private void ShowPresets()
    {
        var manager = new Window
        {
            Title = "截图预设", Width = 660, Height = 430, MinWidth = 600, MinHeight = 400,
            WindowStartupLocation = WindowStartupLocation.CenterScreen
        };
        SnapTheme.StyleWindow(manager);
        var layout = new DockPanel { Margin = new Thickness(14) };
        var left = new DockPanel { Width = 190, Margin = new Thickness(0, 0, 16, 0) };
        DockPanel.SetDock(left, Dock.Left);
        layout.Children.Add(left);
        var entries = new ListBox();
        var listActions = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(listActions, Dock.Bottom);
        left.Children.Add(listActions);
        left.Children.Add(entries);
        var fields = new StackPanel();
        layout.Children.Add(fields);
        var name = new TextBox { Margin = new Thickness(0, 0, 0, 8) };
        const string autoLocate = "按区域自动定位";
        var monitors = Desktop.Monitors();
        var screenPicker = new ComboBox { ItemsSource = new[] { autoLocate }.Concat(monitors.Select(m => m.Name)) };
        var formats = new ComboBox { ItemsSource = new[] { "全局格式" }.Concat(Settings.SaveFormats), SelectedIndex = 0 };
        var save = new ComboBox { ItemsSource = new[] { "全局保存设置", "自动保存", "不自动保存" }, SelectedIndex = 0 };
        var fixedRegion = new CheckBox { Content = "使用固定区域", Margin = new Thickness(0, 8, 0, 5) };
        var position = new StackPanel();
        var coordinates = new[] { new TextBox(), new TextBox(), new TextBox(), new TextBox() };
        var feedback = new TextBlock { Foreground = System.Windows.Media.Brushes.Firebrick, TextWrapping = TextWrapping.Wrap };
        int editing = -1;

        void Row(Panel panel, string label, FrameworkElement control)
        {
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            var title = new TextBlock { Text = label, Width = 106, VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(title, Dock.Left);
            row.Children.Add(title);
            row.Children.Add(control);
            panel.Children.Add(row);
        }
        Row(fields, "预设名称", name);
        Row(fields, "图片格式", formats);
        Row(fields, "自动保存", save);
        fields.Children.Add(fixedRegion);
        fields.Children.Add(position);
        Row(position, "显示器", screenPicker);
        Row(position, "X", coordinates[0]);
        Row(position, "Y", coordinates[1]);
        Row(position, "宽", coordinates[2]);
        Row(position, "高", coordinates[3]);
        void SetArea(DrawingRect area)
        {
            coordinates[0].Text = area.X.ToString();
            coordinates[1].Text = area.Y.ToString();
            coordinates[2].Text = area.Width.ToString();
            coordinates[3].Text = area.Height.ToString();
            var screen = monitors.FirstOrDefault(monitor => monitor.Bounds.Contains(area)).Name;
            screenPicker.SelectedItem = screen ?? autoLocate;
        }
        if (lastSelection is { } recentArea)
            position.Children.Add(RecordingWindow.Button("使用最近一次框选区域", () => SetArea(recentArea)));
        var help = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 8) };
        fields.Children.Add(help);
        fields.Children.Add(feedback);
        void ToggleFixed()
        {
            bool use = fixedRegion.IsChecked == true;
            position.Visibility = use ? Visibility.Visible : Visibility.Collapsed;
            help.Text = use ? "以桌面原点计算像素坐标。原点左侧或上方的扩展屏可使用负坐标。"
                : "启动后手动框选，本次截图沿用预设的输出格式和保存方式。";
        }
        fixedRegion.Checked += (_, _) => ToggleFixed();
        fixedRegion.Unchecked += (_, _) => ToggleFixed();
        void Fill(CapturePreset? preset)
        {
            name.Text = preset?.Name ?? "新预设";
            formats.SelectedItem = preset?.SaveFormat ?? "全局格式";
            save.SelectedIndex = preset?.AutoSave switch { true => 1, false => 2, _ => 0 };
            fixedRegion.IsChecked = preset?.FixedRegion == true;
            var bounds = Desktop.CursorMonitor;
            SetArea(preset?.ScreenRegion ?? new DrawingRect(bounds.X, bounds.Y, Math.Min(640, bounds.Width), Math.Min(480, bounds.Height)));
            if (preset?.MonitorName is { } monitorName && monitors.Any(screen => screen.Name == monitorName))
                screenPicker.SelectedItem = monitorName;
            feedback.Text = "";
            ToggleFixed();
        }
        void Refresh(int selection = -1)
        {
            entries.ItemsSource = settings.Presets.Select(preset =>
                $"{preset.Name}   {preset.SaveFormat?.ToUpperInvariant() ?? "全局"} · {(preset.FixedRegion ? "固定区域" : "每次框选")}").ToArray();
            entries.SelectedIndex = selection;
            editing = selection;
            Fill(selection >= 0 ? settings.Presets[selection] : null);
        }
        entries.SelectionChanged += (_, _) =>
        {
            editing = entries.SelectedIndex;
            Fill(editing >= 0 ? settings.Presets[editing] : null);
        };
        listActions.Children.Add(RecordingWindow.Button("新增", () => Refresh()));
        listActions.Children.Add(RecordingWindow.Button("删除", () =>
        {
            if (editing < 0) return;
            settings.Presets.RemoveAt(editing);
            settings.Save();
            Refresh();
        }));
        CapturePreset? Save()
        {
            var title = name.Text.Trim();
            if (title.Length == 0) { feedback.Text = "请输入预设名称。"; return null; }
            bool use = fixedRegion.IsChecked == true;
            int[] values = new int[4];
            if (use && (coordinates.Where((control, i) => !int.TryParse(control.Text, out values[i])).Any() ||
                values[2] < 2 || values[3] < 2 || (long)values[0] + values[2] > int.MaxValue || (long)values[1] + values[3] > int.MaxValue))
            {
                feedback.Text = "请填写有效坐标，宽和高至少为 2 像素。";
                return null;
            }
            var preset = new CapturePreset(title, values[0], values[1], values[2], values[3],
                formats.SelectedIndex > 0 ? formats.SelectedItem as string : null,
                save.SelectedIndex switch { 1 => true, 2 => false, _ => null }, use,
                screenPicker.SelectedIndex > 0 ? screenPicker.SelectedItem as string : null);
            int index = editing;
            if (index < 0) { index = settings.Presets.Count; settings.Presets.Add(preset); }
            else settings.Presets[index] = preset;
            settings.Save();
            Refresh(index);
            return preset;
        }
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right };
        actions.Children.Add(RecordingWindow.Button("保存预设", () => Save()));
        actions.Children.Add(RecordingWindow.Button("使用此预设截图", () =>
        {
            if (Save() is not { } preset) return;
            manager.Close();
            Desktop.Flush();
            if (preset.FixedRegion && Desktop.Monitors().Any(screen => (preset.MonitorName is null || screen.Name == preset.MonitorName)
                && screen.Bounds.Contains(preset.ScreenRegion)))
                Invoke(() => Capture(preset.ScreenRegion, preset));
            else
            {
                if (preset.FixedRegion) Info("预设区域已不在指定屏幕。请重新框选，本次仍使用预设的输出格式。");
                Invoke(() => Select(CaptureAction.Edit, accept: shot => Complete(shot, preset)));
            }
        }));
        fields.Children.Add(actions);
        manager.Content = new ScrollViewer { Content = layout, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Refresh();
        manager.Show();
    }

    private void ShowSettings()
    {
        if (settingsWindow != null) { settingsWindow.Activate(); return; }
        var window = new Window
        {
            Title = "TapSnap 设置", Width = 640, Height = 492, MinWidth = 610, MinHeight = 380,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, UseLayoutRounding = true
        };
        SnapTheme.StyleWindow(window);
        settingsWindow = window;
        window.Closed += (_, _) => settingsWindow = null;
        var layout = new DockPanel();
        var navigation = new ListBox
        {
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(8, 10, 8, 10),
            HorizontalContentAlignment = HorizontalAlignment.Stretch
        };
        var sidebar = new Border { Width = 169, Child = navigation, BorderThickness = new Thickness(0, 0, 1, 0) };
        sidebar.SetResourceReference(Border.BackgroundProperty, "Snap.Sidebar");
        sidebar.SetResourceReference(Border.BorderBrushProperty, "Snap.Border");
        DockPanel.SetDock(sidebar, Dock.Left);
        layout.Children.Add(sidebar);
        var page = new ContentControl();
        layout.Children.Add(page);
        window.Content = layout;
        var general = new StackPanel();
        var keys = new StackPanel();
        var recordOptions = new StackPanel();
        var captureOptions = new StackPanel();
        var annotation = new StackPanel();
        var privacy = new StackPanel();
        var pin = new StackPanel();
        var about = new StackPanel();
        var pages = new (string Title, string Icon, FrameworkElement Content)[]
        {
            ("通用", "settings", general), ("截图", "⌗", captureOptions), ("隐私打码", "shield", privacy),
            ("贴图", "pin", pin), ("标注", "✎", annotation), ("录屏", "●", recordOptions),
            ("长截图", "↕", LongShotWindow.SettingsContent(settings)), ("快捷键", "keyboard", keys), ("关于", "info", about)
        };
        var views = new List<ScrollViewer>();
        foreach (var (title, icon, content) in pages)
        {
            var label = new StackPanel { Orientation = Orientation.Horizontal };
            label.Children.Add(ToolbarGlyph.Make(icon, 14));
            label.Children.Add(new TextBlock { Text = title, Margin = new Thickness(9, 0, 0, 0) });
            var entry = new ListBoxItem { Content = label };
            entry.SetResourceReference(FrameworkElement.StyleProperty, "SnapNavigationItem");
            AutomationProperties.SetName(entry, title);
            navigation.Items.Add(entry);

            var view = new StackPanel { Margin = new Thickness(20) };
            view.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(0, 0, 0, 18) });
            view.Children.Add(content);
            views.Add(new ScrollViewer { Content = view, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        }
        navigation.SelectionChanged += (_, _) =>
        {
            if (navigation.SelectedIndex >= 0) page.Content = views[navigation.SelectedIndex];
        };

        void Option(Panel group, string title, bool enabled, Action<bool> change, string? subtitle = null)
        {
            SettingsLayout.Toggle(group, title, enabled, value => Invoke(() => { change(value); settings.Save(); }), subtitle);
        }

        var appearance = SettingsLayout.Group(general, "外观");
        Option(appearance, "深色界面", settings.DarkTheme, v => { settings.DarkTheme = v; SnapTheme.Apply(app, v); }, "跟随设置而非系统外观");
        Option(appearance, "显示悬浮球", settings.ShowToolBall, v => { if (v != settings.ShowToolBall) ToggleDesktop(true); }, "桌面边缘的快捷截图入口");
        Option(appearance, "显示桌面工具栏", settings.ShowDesktopToolbar, v => { if (v != settings.ShowDesktopToolbar) ToggleDesktop(false); });
        Option(SettingsLayout.Group(general, "启动"), "登录时启动", settings.StartAtLogin, v =>
        {
            using var registry = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (v) registry.SetValue("TapSnap", $"\"{Environment.ProcessPath}\"");
            else registry.DeleteValue("TapSnap", false);
            settings.StartAtLogin = v;
        });

        void AddChoice<T>(Panel group, string title, T[] choices, T current, Action<T> change, double width = 144)
        {
            var list = new ComboBox { ItemsSource = choices, SelectedItem = current, Width = width };
            AutomationProperties.SetName(list, title);
            list.SelectionChanged += (_, _) => { if (list.SelectedItem is T value) { change(value); settings.Save(); } };
            SettingsLayout.Row(group, title, list);
        }

        var selectionTools = SettingsLayout.Group(captureOptions, "框选工具栏");
        SettingsLayout.Row(selectionTools, "常用按钮",
            RecordingWindow.Button("自定义…", () => new SelectionToolbarSettingsWindow(settings) { Owner = window }.ShowDialog()),
            "选择普通截图时直接显示的按钮");

        var borders = SettingsLayout.Group(captureOptions, "选区边框");
        var preview = new SelectionBorder(settings.SelectionBorder);
        var sample = new Grid { Height = 108, IsHitTestVisible = false, ClipToBounds = true, UseLayoutRounding = true };
        sample.ColumnDefinitions.Add(new ColumnDefinition());
        sample.ColumnDefinitions.Add(new ColumnDefinition());
        sample.Children.Add(new Border { Background = SnapTheme.Brush(0xf5f7fa) });
        var darkHalf = new Border { Background = SnapTheme.Brush(0x161c25) };
        Grid.SetColumn(darkHalf, 1);
        sample.Children.Add(darkHalf);
        var tint = new System.Windows.Shapes.Path { Fill = SnapTheme.Brush(0, 64) };
        Grid.SetColumnSpan(tint, 2);
        Grid.SetColumnSpan(preview, 2);
        sample.Children.Add(tint);
        sample.Children.Add(preview);
        void PreviewBorder()
        {
            if (sample.ActualWidth < 60) return;
            var bounds = new Rect(0, 0, sample.ActualWidth, sample.ActualHeight);
            sample.Clip = new RectangleGeometry(bounds, 6, 6);
            var selection = bounds;
            selection.Inflate(-Math.Max(28, bounds.Width * 0.18), -25);
            tint.Data = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(bounds), new RectangleGeometry(selection));
            preview.Update(selection, true, settings.SelectionBorder);
        }
        sample.SizeChanged += (_, _) => PreviewBorder();
        AddChoice(borders, "边框样式", new[] { "极光", "像素阶梯", "双色套印", "布纹缝线", "冰蓝薄荷", "黑白双线", "四角取景", "琥珀虚线", "冷白追光" },
            settings.SelectionBorder, choice => { settings.SelectionBorder = choice; PreviewBorder(); });
        borders.Children.Add(new Border { Child = sample, Margin = new Thickness(13, 0, 13, 12) });
        var behavior = SettingsLayout.Group(captureOptions, "行为");
        Option(behavior, "截图时隐藏桌面图标", settings.HideDesktopIcons, v => settings.HideDesktopIcons = v);
        Option(behavior, "播放快门声", settings.ShutterSound, v => settings.ShutterSound = v);
        Option(behavior, "自动复制到剪贴板", settings.CopyAfterConfirm, v => settings.CopyAfterConfirm = v);
        Option(behavior, "自动保存到文件", settings.SaveAfterConfirm, v => settings.SaveAfterConfirm = v);
        var assist = SettingsLayout.Group(captureOptions, "选区辅助");
        Option(assist, "显示放大镜", settings.ShowMagnifier, v => settings.ShowMagnifier = v);
        Option(assist, "显示选区尺寸", settings.ShowSelectionSize, v => settings.ShowSelectionSize = v);
        var output = SettingsLayout.Group(captureOptions, "输出");
        AddChoice(output, "保存格式", Settings.SaveFormats, settings.SaveFormat, choice => settings.SaveFormat = choice);
        var folder = new StackPanel { Orientation = Orientation.Horizontal };
        var path = new TextBlock { Text = settings.OutputFolder, ToolTip = settings.OutputFolder, MaxWidth = 190,
            TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 11, VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0) };
        path.SetResourceReference(TextBlock.ForegroundProperty, "Snap.Muted");
        folder.Children.Add(path);
        folder.Children.Add(RecordingWindow.Button("更改…", () =>
        {
            var picker = new OpenFolderDialog { InitialDirectory = settings.OutputFolder };
            if (picker.ShowDialog(window) == true)
            {
                settings.OutputFolder = picker.FolderName;
                settings.Save();
                path.Text = picker.FolderName;
                path.ToolTip = picker.FolderName;
            }
        }));
        SettingsLayout.Row(output, "保存目录", folder);

        var defaults = SettingsLayout.Group(annotation, "工具默认值");
        SettingsLayout.Slider(defaults, "默认线宽", 1, 12, settings.DefaultLineWidth, 1, v => settings.DefaultLineWidth = v, settings.Save);
        SettingsLayout.Slider(defaults, "默认字号", 10, 48, settings.DefaultFontSize, 1, v => settings.DefaultFontSize = v, settings.Save);
        SettingsLayout.Slider(defaults, "马赛克像素块", 4, 40, settings.DefaultMosaicBlockSize, 1, v => settings.DefaultMosaicBlockSize = (int)v, settings.Save, " px");
        Option(SettingsLayout.Group(annotation, "智能"), "马赛克自动识别人脸", settings.AutoMosaicFaces, v => settings.AutoMosaicFaces = v);

        var video = SettingsLayout.Group(recordOptions, "画面");
        AddChoice(video, "帧率", new[] { 30, 60 }, settings.RecordFrameRate == 60 ? 60 : 30, rate => settings.RecordFrameRate = rate, 88);
        Option(video, "包含光标", settings.RecordCursor, v => settings.RecordCursor = v);
        Option(video, "摄像头画中画", settings.RecordCamera, v => settings.RecordCamera = v);
        Option(video, "显示按键", settings.RecordShowKeys, v => settings.RecordShowKeys = v);
        Option(video, "显示鼠标点击", settings.RecordShowClicks, v => settings.RecordShowClicks = v);
        var audio = SettingsLayout.Group(recordOptions, "声音");
        Option(audio, "录制系统声音", settings.RecordSystemAudio, v => settings.RecordSystemAudio = v);
        Option(audio, "录制麦克风", settings.RecordMicrophone, v => settings.RecordMicrophone = v);

        SettingsLayout.Row(SettingsLayout.Group(privacy, "识别与打码"), "脱敏规则与识别模型",
            RecordingWindow.Button("打开设置…", RecognitionService.OpenSettings));
        SettingsLayout.Row(SettingsLayout.Group(pin, "分组"), "贴图分组", RecordingWindow.Button("管理…", pins.Groups));
        pin.Children.Add(pins.PreferencesContent());
        var product = SettingsLayout.Group(about, "TapSnap");
        SettingsLayout.Row(product, "使用指南", RecordingWindow.Button("打开…", ShowGuide), "截图、标注、贴图与录屏");
        SettingsLayout.Row(product, "桌面截图", RecordingWindow.Button("检查权限", CheckCapture));

        void Refresh()
        {
            keys.Children.Clear();
            Option(SettingsLayout.Group(keys, "冲突处理"), "尝试优先响应冲突组合", settings.PreferPriorityHotkeys,
                value => { settings.PreferPriorityHotkeys = value; BindHotkeys(); Refresh(); },
                "检测到冲突时尝试响应。系统保留快捷键仍由 Windows 处理。");
            var bindings = SettingsLayout.Group(keys, "全局快捷键");
            foreach (var (id, definition) in hotkeyActions)
            {
                var button = RecordingWindow.Button("录制", () => EditShortcut(id, operation: false));
                AutomationProperties.SetName(button, $"录制{definition.Title}快捷键");
                string displayed = settings.Hotkeys.TryGetValue(id, out var key) ? Shortcuts.Display(key) : "未分配";
                SettingsLayout.Row(bindings, definition.Title, button, displayed
                    + (conflicts.Contains(id) ? "（被系统或其他应用占用）" : priorityHotkeys.Contains(id) ? "（优先响应）" : ""));
            }
            var operationBindings = SettingsLayout.Group(keys, "框选与编辑");
            foreach (var operation in OperationShortcut.All)
            {
                var button = RecordingWindow.Button("录制", () => EditShortcut(operation.Id, operation: true));
                AutomationProperties.SetName(button, $"录制{operation.Title}快捷键");
                string displayed = operation.Binding(settings.OperationHotkeys) is { } key ? Shortcuts.Display(key) : "未分配";
                SettingsLayout.Row(operationBindings, operation.Title, button, displayed);
            }
            var reset = RecordingWindow.Button("恢复默认快捷键", () =>
            {
                settings.Hotkeys = Settings.Defaults();
                settings.OperationHotkeys = null;
                settings.Save();
                BindHotkeys();
                UpdateEditorShortcuts();
                Refresh();
            });
            reset.HorizontalAlignment = HorizontalAlignment.Left;
            keys.Children.Add(reset);
        }

        void EditShortcut(string id, bool operation)
        {
            Hotkey? recorded;
            for (int slot = 1; slot <= hotkeyActions.Count; slot++) shortcuts.Unbind(slot);
            try { recorded = Shortcuts.Record(window, allowsSingleKeys: operation); }
            finally { BindHotkeys(); }
            if (recorded is not { } key) return;
            if (key.KeyCode != 0)
            {
                var globalConflict = hotkeyActions.FirstOrDefault(pair => (operation || pair.Key != id) &&
                    settings.Hotkeys.GetValueOrDefault(pair.Key) == key).Value.Title;
                var operationConflict = OperationShortcut.All.FirstOrDefault(action => (!operation || action.Id != id) &&
                    action.Binding(settings.OperationHotkeys) == key);
                string? conflict = globalConflict ?? operationConflict?.Title;
                if (conflict is not null)
                {
                    MessageBox.Show(window, $"该快捷键已分配给“{conflict}”，请更换键位。", "快捷键冲突");
                    return;
                }
            }
            var bindings = operation
                ? new Dictionary<string, Hotkey>(settings.OperationHotkeys ?? OperationShortcut.Defaults)
                : settings.Hotkeys;
            if (key.KeyCode == 0) bindings.Remove(id);
            else bindings[id] = key;
            if (operation) settings.OperationHotkeys = bindings;
            settings.Save();
            if (operation) UpdateEditorShortcuts();
            else BindHotkeys();
            Refresh();
        }

        void UpdateEditorShortcuts()
        {
            foreach (var editor in app.Windows.OfType<EditorWindow>())
                editor.ApplyOperationHotkeys(settings.OperationHotkeys);
        }
        Refresh();
        navigation.SelectedIndex = 0;
        window.Show();
    }

    private void ToggleDesktop(bool ball)
    {
        if (ball) settings.ShowToolBall = !settings.ShowToolBall;
        else settings.ShowDesktopToolbar = !settings.ShowDesktopToolbar;
        var existing = ball ? toolBall : desktopBar;
        if (existing != null) existing.Close();
        else ShowDesktop(ball);
        settings.Save();
    }

    private void ShowDesktop(bool ball)
    {
        var window = new Window
        {
            Title = ball ? "TapSnap 悬浮球" : "TapSnap 桌面工具栏",
            SizeToContent = SizeToContent.WidthAndHeight, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
            Topmost = true, ShowInTaskbar = false, ShowActivated = false, AllowsTransparency = true,
            Background = Brushes.Transparent, UseLayoutRounding = true
        };
        var tools = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var chrome = new Border
        {
            Child = tools, Height = ball ? 46 : 34, CornerRadius = new CornerRadius(ball ? 24 : 10),
            BorderThickness = new Thickness(1), Margin = new Thickness(ball ? 3 : 8), Padding = new Thickness(ball ? 0 : 7, 0, ball ? 0 : 7, 0),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 12, ShadowDepth = 3, Direction = 270, Opacity = .20 }
        };
        chrome.SetResourceReference(Border.BackgroundProperty, "Snap.Panel");
        chrome.SetResourceReference(Border.BorderBrushProperty, "Snap.Border");
        window.Content = chrome;
        if (ball)
        {
            window.Opacity = 0.78;
            window.MouseEnter += (_, _) => window.Opacity = 1;
            window.MouseLeave += (_, _) => window.Opacity = 0.78;
        }
        Button Icon(string symbol, string title, Action action, double width = 28, double height = 28, double size = 15)
        {
            var button = new Button { Content = ToolbarGlyph.Make(symbol, size), Width = width, Height = height,
                ToolTip = title, VerticalAlignment = VerticalAlignment.Center, Cursor = System.Windows.Input.Cursors.Hand };
            button.SetResourceReference(FrameworkElement.StyleProperty, "SnapGhost");
            AutomationProperties.SetName(button, title);
            button.Click += (_, _) => Invoke(action);
            return button;
        }
        var handle = ball
            ? Icon("frame", "单击截图，右键打开工具", () => Select(CaptureAction.Edit), 44, 44, 22)
            : Icon("grip", "拖动工具栏", () => { }, width: 17, size: 12);
        if (ball) handle.Clip = new EllipseGeometry(new Point(22, 22), 22, 22);
        else handle.Cursor = System.Windows.Input.Cursors.SizeAll;
        var items = new (string Key, string Glyph)[] { ("capture", "⌗"), ("clipboardPin", "pin"), ("longShot", "↕"),
            ("record", "●"), ("ocr", "⌑"), ("history", "clipboard") };
        var context = new ContextMenu();
        foreach (var (key, glyph) in items)
        {
            var command = hotkeyActions[key];
            if (!ball) tools.Children.Add(Icon(glyph, command.Title, command.Action));
            var item = new MenuItem { Header = command.Title };
            item.Click += (_, _) => Invoke(command.Action);
            context.Items.Add(item);
        }
        var close = new MenuItem { Header = "隐藏" };
        close.Click += (_, _) => ToggleDesktop(ball);
        context.Items.Add(close);
        tools.Children.Insert(0, handle);
        chrome.ContextMenu = context;
        handle.PreviewMouseMove += (_, e) =>
        {
            if (e.LeftButton != System.Windows.Input.MouseButtonState.Pressed) return;
            e.Handled = true;
            window.DragMove();
            if (Desktop.TryWindowBounds(window, out var bounds))
            {
                if (ball)
                {
                    var area = Forms.Screen.FromPoint(new System.Drawing.Point(bounds.Left + bounds.Width / 2,
                        bounds.Top + bounds.Height / 2)).WorkingArea;
                    int x = bounds.Left + bounds.Width / 2 < area.Left + area.Width / 2
                        ? area.Left + 7 : area.Right - bounds.Width - 7;
                    int y = Math.Clamp(bounds.Y, area.Top, Math.Max(area.Top, area.Bottom - bounds.Height));
                    Desktop.Place(window, new DrawingRect(x, y, 1, 1), true);
                    settings.ToolBallX = x;
                    settings.ToolBallY = y;
                }
                else { settings.DesktopToolbarX = bounds.X; settings.DesktopToolbarY = bounds.Y; }
                settings.Save();
            }
        };
        window.SourceInitialized += (_, _) => Desktop.Exclude(window);
        window.Loaded += (_, _) =>
        {
            var r = Desktop.CursorMonitor;
            int x = ball ? settings.ToolBallX : settings.DesktopToolbarX;
            int y = ball ? settings.ToolBallY : settings.DesktopToolbarY;
            if (!Desktop.Monitors().Any(m => m.Bounds.Contains(x, y))) { x = r.Left + 25; y = r.Top + 50; }
            Desktop.Place(window, new DrawingRect(x, y, 1, 1), true);
        };
        window.Closed += (_, _) => { if (ball) toolBall = null; else desktopBar = null; };
        if (ball) toolBall = window; else desktopBar = window;
        window.Show();
    }

    private void ShowGuide()
    {
        var window = new Window { Title = "TapSnap 使用指南", Width = 465, Height = 470, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        SnapTheme.StyleWindow(window);
        var list = new StackPanel { Margin = new Thickness(15) };
        var items = new (string Title, string Steps, Action Start)[]
        {
            ("区域截图与标注", "拖动框选，按回车打开编辑器。拖动标题栏可移动整个编辑窗口。", () => Select(CaptureAction.Edit)),
            ("长截图", "框选后滚动内容，可以指定实际滚动视口。", () => Select(CaptureAction.LongShot)),
            ("录屏和 GIF", "选择区域，完成后在预览中选择区间并复制 GIF。", ToggleRecording),
            ("贴图", "截图后点贴图，或把剪贴板图片贴在桌面上。", () => Select(CaptureAction.Pin)),
            ("隐私打码", "自动识别后检查遮盖框，再复制或保存。", () => Select(CaptureAction.Privacy)),
            ("文字识别", "选择文字区域，核对识别结果并复制。", () => Select(CaptureAction.Text)),
            ("剪贴板历史", "拖动标题区移动面板，点击记录还原。", ToggleHistory),
            ("录制快捷键", "在设置里点击录制，按下你想用的组合。", ShowSettings)
        };
        foreach (var item in items)
        {
            list.Children.Add(RecordingWindow.Button(item.Title + "  ·  开始", () => { window.Close(); Invoke(item.Start); }));
            list.Children.Add(new TextBlock { Text = item.Steps, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(5, 0, 5, 8) });
        }
        window.Content = new ScrollViewer { Content = list };
        window.Show();
    }

    private void CheckCapture()
    {
        var image = Desktop.Capture(Desktop.CursorMonitor);
        Info($"桌面抓屏可用（{image.PixelWidth} × {image.PixelHeight}）。"
            + (conflicts.Count > 0 ? " 可在设置中修改被占用的快捷键。" : " 已注册当前配置的快捷键。"));
    }

    private void Info(string message, bool error = false) => MessageBox.Show(message, "TapSnap", MessageBoxButton.OK,
        error ? MessageBoxImage.Error : MessageBoxImage.Information);

    public void PrepareToExit()
    {
        if (exiting) return;
        toast.Dismiss();
        recent?.Dispose();
        pins.Shutdown();
        exiting = true;
    }

    public void Dispose()
    {
        PrepareToExit();
        shortcuts.Dispose();
        history.Dispose();
        tray.Visible = false;
        tray.Dispose();
    }
}

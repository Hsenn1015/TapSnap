using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Clipboard = System.Windows.Clipboard;
using MessageBox = System.Windows.MessageBox;

namespace TapSnap.Windows;

public enum RecognitionMode { Text, Barcode, Table, Translation, Formula }

public sealed record PrivacyCandidate(string Label, Rect Bounds, bool ApplyAutomatically);

public static class RecognitionService
{
    internal static string SettingsDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TapSnap");
    private static string SettingsPath => Path.Combine(SettingsDirectory, "recognition.json");
    private static RecognitionSettings? cachedSettings;
    private static RecognitionSettingsWindow? settingsWindow;
    private static TextRecognitionWindow? textWindow;
    private static readonly ConditionalWeakTable<BitmapSource, CachedText> CachedOcr = new();
    private sealed record CachedText(string Language, IReadOnlyList<RecognizedLine> Lines);

    internal static RecognitionSettings Settings
    {
        get
        {
            if (cachedSettings is not null)
                return cachedSettings;
            if (!File.Exists(SettingsPath))
                return cachedSettings = new RecognitionSettings();
            try
            {
                return cachedSettings = JsonSerializer.Deserialize<RecognitionSettings>(File.ReadAllText(SettingsPath))
                    ?? new RecognitionSettings();
            }
            catch (JsonException error)
            {
                throw new InvalidOperationException("识别设置文件无法读取。", error);
            }
        }
    }

    internal static void SaveSettings(RecognitionSettings settings)
    {
        Directory.CreateDirectory(SettingsDirectory);
        string temporary = SettingsPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporary, SettingsPath, true);
            cachedSettings = settings;
        }
        finally { File.Delete(temporary); }
    }

    public static bool ShouldScanAutomatically => Settings.ScanAutomatically;
    public static bool IsAiConfigured => RecognitionAi.TryEndpoint(Settings) is not null;

    public static async Task<IReadOnlyList<Rect>> FindPrivateAsync(BitmapSource image) =>
        (await ScanPrivacyAsync(image)).Where(candidate => candidate.ApplyAutomatically).Select(candidate => candidate.Bounds).ToArray();

    public static async Task<IReadOnlyList<PrivacyCandidate>> ScanPrivacyAsync(BitmapSource image,
        CancellationToken cancellationToken = default)
    {
        var settings = Settings;
        image = RecognitionEngine.Freeze(image);
        bool textEnabled = PrivacyRules.Definitions.Any(rule => rule.Kind is not (PrivacyRuleKind.Face or PrivacyRuleKind.Barcode) &&
                                                               settings.Mode(rule.Kind) != PrivacyRuleMode.Off) ||
                           settings.CustomRules.Any(rule => rule.Mode != PrivacyRuleMode.Off);
        var candidates = new List<PrivacyCandidate>();
        if (textEnabled)
        {
            var lines = await ReadTextAsync(image, settings.OcrLanguages, cancellationToken);
            candidates.AddRange(await Task.Run(() => TextCandidates(lines, settings, cancellationToken), cancellationToken));
        }
        candidates.AddRange(await AddVisualCandidatesAsync(image, settings, cancellationToken));
        return PaddedCandidates(image, candidates);
    }

    internal static async Task<IReadOnlyList<RecognizedLine>> ReadTextAsync(BitmapSource image, string language,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (CachedOcr.TryGetValue(image, out var previous) && previous.Language == language)
            return previous.Lines;
        var lines = await RecognitionEngine.ReadAsync(image, language, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        CachedOcr.AddOrUpdate(image, new CachedText(language, lines));
        return lines;
    }

    internal static IReadOnlyList<PrivacyCandidate> PaddedCandidates(BitmapSource image, IEnumerable<PrivacyCandidate> candidates)
    {
        Rect imageBounds = new(0, 0, image.PixelWidth, image.PixelHeight);
        return DeduplicateCandidates(candidates.Select(candidate =>
        {
            Rect mask = candidate.Bounds;
            mask.Inflate(candidate.Label is "二维码和条形码" or "人脸" ? 5 : 2, 2);
            mask.Intersect(imageBounds);
            return candidate with { Bounds = mask };
        }).Where(candidate => !candidate.Bounds.IsEmpty));
    }

    internal static Rect ToRect(RectangleF rectangle) => new(rectangle.X, rectangle.Y, rectangle.Width, rectangle.Height);

    internal static IReadOnlyList<PrivacyCandidate> TextCandidates(IReadOnlyList<RecognizedLine> lines,
        RecognitionSettings settings, CancellationToken cancellationToken = default) =>
        PrivacyRules.Match(lines, settings, cancellationToken: cancellationToken).Select(candidate => new PrivacyCandidate(
            candidate.Label, ToRect(candidate.Bounds), candidate.ApplyAutomatically)).ToArray();

    internal static IReadOnlyList<PrivacyCandidate> DeduplicateCandidates(IEnumerable<PrivacyCandidate> candidates) =>
        PrivacyRules.Deduplicate(candidates.Select(candidate => new PrivacyTextMatch(candidate.Label,
            new RectangleF((float)candidate.Bounds.X, (float)candidate.Bounds.Y, (float)candidate.Bounds.Width, (float)candidate.Bounds.Height),
            candidate.ApplyAutomatically))).Select(candidate => new PrivacyCandidate(
                candidate.Label, ToRect(candidate.Bounds), candidate.ApplyAutomatically)).ToArray();

    internal static async Task<IReadOnlyList<PrivacyCandidate>> AddVisualCandidatesAsync(BitmapSource image,
        RecognitionSettings settings, CancellationToken cancellationToken = default)
    {
        var candidates = new List<PrivacyCandidate>();
        var barcodeMode = settings.Mode(PrivacyRuleKind.Barcode);
        if (barcodeMode != PrivacyRuleMode.Off)
            foreach (var barcode in await RecognitionEngine.BarcodesAsync(image).WaitAsync(cancellationToken))
                if (!barcode.Bounds.IsEmpty)
                    candidates.Add(new PrivacyCandidate("二维码和条形码", barcode.Bounds, barcodeMode == PrivacyRuleMode.Automatic));
        var faceMode = settings.Mode(PrivacyRuleKind.Face);
        if (faceMode != PrivacyRuleMode.Off)
            candidates.AddRange(await RecognitionEngine.FacesAsync(image, faceMode).WaitAsync(cancellationToken));

        return candidates;
    }

    public static async Task<IReadOnlyList<Rect>> DetectMosaicAsync(BitmapSource image, bool detectsFaces, bool detectsText)
    {
        image = RecognitionEngine.Freeze(image);
        var masks = new List<Rect>();
        if (detectsText)
        {
            var text = await RecognitionEngine.ReadAsync(image, Settings.OcrLanguages);
            masks.AddRange(text.Select(line => ToRect(line.Bounds)));
        }
        if (detectsFaces)
        {
            var faces = await RecognitionEngine.FacesAsync(image, PrivacyRuleMode.Automatic);
            masks.AddRange(faces.Select(face => face.Bounds));
        }
        Rect imageBounds = new(0, 0, image.PixelWidth, image.PixelHeight);
        return masks.Select(mask =>
        {
            mask.Inflate(3, 3);
            mask.Intersect(imageBounds);
            return mask;
        }).Where(mask => !mask.IsEmpty).ToArray();
    }

    public static Task ScanPrivacyWithAiAsync(BitmapSource image, bool includeImage, Window owner,
        Action<IReadOnlyList<PrivacyCandidate>> onBatch, IProgress<string>? progress = null,
        CancellationToken cancellationToken = default) =>
        RecognitionAi.DetectAsync(RecognitionEngine.Freeze(image), includeImage, owner, Settings,
            onBatch, progress, cancellationToken);

    public static void OpenSettings() => OpenSettings(openTranslation: false);

    public static void OpenTranslationSettings() => OpenSettings(openTranslation: true);

    private static void OpenSettings(bool openTranslation)
    {
        if (settingsWindow is { } existing)
        {
            if (openTranslation) existing.ShowTranslation();
            existing.Activate();
            return;
        }
        var window = new RecognitionSettingsWindow(openTranslation);
        settingsWindow = window;
        window.Closed += (_, _) => settingsWindow = null;
        window.Show();
    }

    public static void OpenResult(BitmapSource image, RecognitionMode mode)
    {
        image = RecognitionEngine.Freeze(image);
        if (mode == RecognitionMode.Text)
        {
            textWindow?.Close();
            var window = new TextRecognitionWindow(image);
            textWindow = window;
            window.Closed += (_, _) => textWindow = null;
            window.Show();
        }
        else new RecognitionResultWindow(image, mode).Show();
    }

    public static async Task<string> FormulaAsync(BitmapSource source, CancellationToken cancellationToken = default)
    {
        string interpreter = Settings.FormulaPython;
        if (string.IsNullOrWhiteSpace(interpreter))
            interpreter = Path.Combine(SettingsDirectory, "formula-runtime", "Scripts", "python.exe");
        string helper = Path.Combine(AppContext.BaseDirectory, "Recognition", "formula_recognize.py");
        if (!File.Exists(interpreter) || !File.Exists(helper))
            throw new InvalidOperationException("请先运行 Windows 工程的 Install-Formula.ps1，或在识别设置中指定已安装 pix2tex 的 Python。");

        var start = new ProcessStartInfo
        {
            FileName = interpreter,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8
        };
        start.ArgumentList.Add(helper);
        start.Environment["PYTHONUTF8"] = "1";
        using var process = Process.Start(start) ?? throw new InvalidOperationException("无法启动本机公式识别进程。");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(120));
        var response = process.StandardOutput.ReadToEndAsync(deadline.Token);
        var discarded = process.StandardError.ReadToEndAsync(deadline.Token);
        try
        {
            await process.StandardInput.BaseStream.WriteAsync(RecognitionEngine.Png(source), deadline.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(deadline.Token);
            await discarded;
            using var document = JsonDocument.Parse(await response);
            if (process.ExitCode == 0 && document.RootElement.TryGetProperty("latex", out var value) && value.GetString() is { } latex)
                return latex;
            throw new InvalidOperationException("本机公式模型未返回结果，请检查模型安装。");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new InvalidOperationException("公式识别超时。");
        }
        catch (JsonException error)
        {
            throw new InvalidOperationException("本机公式模型返回了无法识别的结果。", error);
        }
        finally
        {
            if (!process.HasExited) process.Kill(true);
        }
    }
}

internal sealed class RecognitionResultWindow : Window
{
    private readonly BitmapSource image;
    private readonly RecognitionMode mode;
    private readonly TextBox result = new()
    {
        AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(10), FontSize = 14
    };
    private readonly TextBlock status = new() { Text = "识别中…", TextWrapping = TextWrapping.Wrap };
    private static readonly string[] Languages = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español"];
    private readonly ComboBox source = new() { ItemsSource = new[] { "自动识别" }.Concat(Languages), SelectedIndex = 0, Width = 105 };
    private readonly ComboBox target = new() { ItemsSource = Languages, SelectedIndex = 0, Width = 105 };
    private readonly CancellationTokenSource lifetime = new();
    private readonly CancellationTokenSource recognition = new();
    private WebView2? formulaView;
    private Button? copyFormula;
    private Button? cancelFormula;
    private CoreWebView2? formulaBrowser;
    private readonly TextBox translation = new()
    {
        AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(10), FontSize = 14
    };
    private Button? translate;

    public RecognitionResultWindow(BitmapSource image, RecognitionMode mode)
    {
        this.image = image;
        this.mode = mode;
        Title = "TapSnap · " + (mode switch
        {
            RecognitionMode.Table => "表格识别",
            RecognitionMode.Barcode => "二维码和条形码",
            RecognitionMode.Formula => "公式识别",
            RecognitionMode.Translation => "截图翻译",
            _ => "识别结果"
        });
        Width = 690;
        Height = 520;
        MinWidth = 350;
        MinHeight = 310;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SnapTheme.StyleWindow(this);

        var layout = new DockPanel { Margin = new Thickness(14) };
        DockPanel.SetDock(status, Dock.Top);
        layout.Children.Add(status);
        var actions = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(actions, Dock.Bottom);
        Button copy = Button(mode switch
        {
            RecognitionMode.Table => "复制 CSV",
            RecognitionMode.Formula => "复制 LaTeX",
            _ => "复制文字"
        });
        copy.SetResourceReference(StyleProperty, "SnapPrimary");
        copy.Click += (_, _) => Copy(result.Text);
        actions.Children.Add(copy);
        if (mode == RecognitionMode.Translation)
        {
            actions.Children.Add(new TextBlock { Text = "原文语言", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 4, 0) });
            actions.Children.Add(source);
            actions.Children.Add(new TextBlock { Text = "目标语言", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 4, 0) });
            actions.Children.Add(target);
            translate = Button("翻译");
            translate.Click += async (_, _) => await TranslateAsync();
            actions.Children.Add(translate);
            Button copyTranslation = Button("复制译文");
            copyTranslation.Click += (_, _) => Copy(translation.Text);
            actions.Children.Add(copyTranslation);
        }
        if (mode == RecognitionMode.Formula)
        {
            copyFormula = Button("复制公式图片");
            copyFormula.IsEnabled = false;
            copyFormula.Click += async (_, _) => await CopyFormulaImageAsync();
            actions.Children.Add(copyFormula);
            cancelFormula = Button("取消");
            cancelFormula.Click += (_, _) => recognition.Cancel();
            actions.Children.Add(cancelFormula);
        }
        Button settings = Button(mode == RecognitionMode.Translation ? "本机翻译设置" : "识别设置");
        settings.Click += (_, _) =>
        {
            if (mode == RecognitionMode.Translation) RecognitionService.OpenTranslationSettings();
            else RecognitionService.OpenSettings();
        };
        actions.Children.Add(settings);
        layout.Children.Add(actions);
        if (mode == RecognitionMode.Translation)
        {
            var panels = new Grid { Margin = new Thickness(0, 9, 0, 0) };
            panels.ColumnDefinitions.Add(new ColumnDefinition());
            panels.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
            panels.ColumnDefinitions.Add(new ColumnDefinition());
            var inputPane = LabeledPane("原文（可修改）", result);
            var outputPane = LabeledPane("翻译结果", translation);
            panels.Children.Add(inputPane);
            Grid.SetColumn(outputPane, 2);
            panels.Children.Add(outputPane);
            layout.Children.Add(panels);
        }
        else if (mode == RecognitionMode.Formula)
        {
            var panels = new Grid { Margin = new Thickness(0, 9, 0, 0) };
            panels.RowDefinitions.Add(new RowDefinition { Height = new GridLength(126), MinHeight = 90 });
            panels.RowDefinitions.Add(new RowDefinition { Height = new GridLength(9) });
            panels.RowDefinitions.Add(new RowDefinition());
            result.FontFamily = new System.Windows.Media.FontFamily("Consolas");
            panels.Children.Add(LabeledPane("LaTeX", result));
            formulaView = new WebView2 { MinHeight = 108 };
            var previewPane = LabeledPane("公式预览", formulaView);
            Grid.SetRow(previewPane, 2);
            panels.Children.Add(previewPane);
            layout.Children.Add(panels);
            result.TextChanged += async (_, _) => await UpdateFormulaPreviewAsync();
        }
        else
        {
            result.Margin = new Thickness(0, 9, 0, 0);
            layout.Children.Add(result);
        }
        Content = layout;
        Loaded += async (_, _) =>
        {
            if (formulaView is null) await RunRecognitionAsync();
            else await Task.WhenAll(RunRecognitionAsync(), InitializeFormulaPreviewAsync());
        };
        PreviewKeyDown += async (_, args) =>
        {
            if (args.Key == Key.Escape) Close();
            if (args.Key == Key.Enter && mode == RecognitionMode.Translation &&
                Keyboard.Modifiers == ModifierKeys.Control)
            {
                args.Handled = true;
                await TranslateAsync();
            }
        };
        Closed += (_, _) =>
        {
            lifetime.Cancel();
            recognition.Cancel();
            formulaBrowser = null;
            formulaView?.Dispose();
        };
    }

    private static DockPanel LabeledPane(string label, UIElement input)
    {
        var panel = new DockPanel();
        var title = new TextBlock { Text = label, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 5) };
        DockPanel.SetDock(title, Dock.Top);
        panel.Children.Add(title);
        panel.Children.Add(input);
        return panel;
    }

    private static Button Button(string title) => new()
    {
        Content = title, Padding = new Thickness(10, 5, 10, 5), Margin = new Thickness(0, 0, 6, 4)
    };

    private async Task RunRecognitionAsync()
    {
        var cancellationToken = recognition.Token;
        try
        {
            var config = RecognitionService.Settings;
            result.Text = mode switch
            {
                RecognitionMode.Formula => await RecognitionService.FormulaAsync(image, cancellationToken),
                RecognitionMode.Barcode => string.Join(Environment.NewLine, (await RecognitionEngine.BarcodesAsync(image)
                    .WaitAsync(cancellationToken)).Select(barcode => barcode.Text).Distinct()),
                RecognitionMode.Table => await RecognitionEngine.CsvAsync(image, config.OcrLanguages, cancellationToken),
                _ => RecognitionEngine.Text(await RecognitionEngine.ReadAsync(image, config.OcrLanguages, cancellationToken))
            };
            if (string.IsNullOrWhiteSpace(result.Text)) status.Text = "未识别到内容";
            else if (mode == RecognitionMode.Table) Copy(result.Text);
            else if (mode == RecognitionMode.Formula) status.Text = "识别完成，修改 LaTeX 后预览会同步更新。";
            else status.Text = "可在下方编辑识别结果";
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        { if (!lifetime.IsCancellationRequested) status.Text = "已取消识别"; }
        catch (Exception error) { status.Text = error.Message; }
        finally { if (cancelFormula is not null) cancelFormula.Visibility = Visibility.Collapsed; }
    }

    private async Task TranslateAsync()
    {
        if (translate is null || !translate.IsEnabled || string.IsNullOrWhiteSpace(result.Text)) return;
        translate.IsEnabled = false;
        source.IsEnabled = target.IsEnabled = result.IsEnabled = false;
        status.Text = "翻译中…";
        try
        {
            translation.Text = await RecognitionAi.TranslateAsync(result.Text, source.SelectedItem as string ?? "自动识别",
                target.SelectedItem as string ?? "简体中文", RecognitionService.Settings, lifetime.Token);
            status.Text = "设备端翻译完成";
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception error) { status.Text = error.Message; }
        finally { translate.IsEnabled = source.IsEnabled = target.IsEnabled = result.IsEnabled = true; }
    }

    private void Copy(string value)
    {
        if (value.Length == 0) return;
        try { Clipboard.SetText(value); status.Text = "已复制"; }
        catch (System.Runtime.InteropServices.ExternalException) { status.Text = "剪贴板正忙，请重试。"; }
    }

    private async Task InitializeFormulaPreviewAsync()
    {
        if (formulaView is not { } view) return;
        try
        {
            string directory = Path.Combine(AppContext.BaseDirectory, "Recognition", "KaTeX");
            const string localHost = "formula.tapsnap.invalid";
            string page = $"https://{localHost}/index.html";
            if (!File.Exists(Path.Combine(directory, "index.html")))
                throw new InvalidOperationException("找不到本机 KaTeX 预览资源。");
            var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: Path.Combine(RecognitionService.SettingsDirectory, "formula-preview"));
            if (lifetime.IsCancellationRequested) return;
            await view.EnsureCoreWebView2Async(environment);
            if (lifetime.IsCancellationRequested) return;
            var browser = view.CoreWebView2;
            browser.Settings.IsWebMessageEnabled = false;
            browser.Settings.AreHostObjectsAllowed = false;
            browser.Settings.AreDevToolsEnabled = false;
            browser.Settings.AreDefaultContextMenusEnabled = false;
            browser.SetVirtualHostNameToFolderMapping(localHost, directory, CoreWebView2HostResourceAccessKind.Deny);
            browser.NavigationStarting += (_, args) => args.Cancel = args.Uri != page;
            browser.NewWindowRequested += (_, args) => args.Handled = true;
            browser.NavigationCompleted += async (_, args) =>
            {
                if (!args.IsSuccess || lifetime.IsCancellationRequested) return;
                formulaBrowser = browser;
                await UpdateFormulaPreviewAsync();
            };
            browser.Navigate(page);
        }
        catch (Exception error)
        {
            if (!lifetime.IsCancellationRequested) status.Text = "本地公式预览无法启动：" + error.Message;
        }
    }

    private async Task UpdateFormulaPreviewAsync()
    {
        if (formulaBrowser is not { } browser || lifetime.IsCancellationRequested) return;
        try
        {
            await browser.ExecuteScriptAsync("window.renderFormula(" + JsonSerializer.Serialize(result.Text) + ")");
            if (copyFormula is not null) copyFormula.IsEnabled = !string.IsNullOrWhiteSpace(result.Text);
        }
        catch (Exception error)
        {
            if (!lifetime.IsCancellationRequested) status.Text = "无法更新公式预览：" + error.Message;
        }
    }

    private async Task CopyFormulaImageAsync()
    {
        if (formulaBrowser is not { } browser) return;
        try
        {
            using var png = new MemoryStream();
            await browser.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, png);
            if (lifetime.IsCancellationRequested) return;
            png.Position = 0;
            Clipboard.SetImage(BitmapFrame.Create(png, BitmapCreateOptions.None, BitmapCacheOption.OnLoad));
            status.Text = "已复制公式图片";
        }
        catch (Exception error)
        {
            if (!lifetime.IsCancellationRequested) status.Text = "无法复制公式图片：" + error.Message;
        }
    }
}

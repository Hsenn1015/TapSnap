using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using MessageBox = System.Windows.MessageBox;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;

namespace TapSnap.Windows;

internal sealed class RecognitionSettingsWindow : Window
{
    private readonly RecognitionSettings original = RecognitionService.Settings;
    private readonly Dictionary<PrivacyRuleKind, ComboBox> modes = new();
    private readonly StackPanel customEntries = new();
    private readonly List<CustomEntry> customs = new();
    private readonly CheckBox scan = new() { Content = "截图后自动检查" };
    private readonly TextBox language = new();
    private readonly CheckBox copyOcr = new() { Content = "文字识别后自动复制" };
    private readonly CheckBox collapseOcr = new() { Content = "复制时用空格替换换行" };
    private readonly TextBox domains = new();
    private readonly TextBox endpoint = new();
    private readonly TextBox model = new();
    private readonly TextBox translationEndpoint = new();
    private readonly TextBox translationModel = new();
    private readonly PasswordBox apiKey = new();
    private readonly CheckBox clearKey = new() { Content = "移除当前保存的 API Key" };
    private readonly TextBlock keyStatus = new() { TextWrapping = TextWrapping.Wrap };
    private readonly CancellationTokenSource lifetime = new();
    private readonly TextBox python = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TabControl tabs = new();

    public RecognitionSettingsWindow(bool openTranslation = false)
    {
        Title = "TapSnap · 脱敏规则与识别模型";
        Width = 650; Height = 720; MinWidth = 500; MinHeight = 455;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SnapTheme.StyleWindow(this);
        var grid = new DockPanel { Margin = new Thickness(15) };

        var footer = new DockPanel { Margin = new Thickness(0, 9, 0, 0) };
        var save = Button("保存");
        save.SetResourceReference(StyleProperty, "SnapPrimary");
        save.IsDefault = true;
        save.Click += (_, _) => Save();
        DockPanel.SetDock(save, Dock.Right);
        footer.Children.Add(save);
        footer.Children.Add(status);
        DockPanel.SetDock(footer, Dock.Bottom);
        grid.Children.Add(footer);

        void AddPage(string title, FrameworkElement content) =>
            tabs.Items.Add(new TabItem { Header = title,
                Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });
        AddPage("脱敏规则", RuleSettings());
        AddPage("识别与模型", ModelSettings());
        AddPage("本机翻译", TranslationSettings());
        if (openTranslation) ShowTranslation();
        grid.Children.Add(tabs);
        Content = grid;
        Closed += (_, _) => { lifetime.Cancel(); lifetime.Dispose(); apiKey.Clear(); };
    }

    public void ShowTranslation() => tabs.SelectedIndex = 2;

    private StackPanel RuleSettings()
    {
        var stack = new StackPanel { Margin = new Thickness(12) };
        scan.IsChecked = original.ScanAutomatically;
        stack.Children.Add(scan);
        foreach (var rule in PrivacyRules.Definitions)
        {
            var mode = ModeBox(original.Mode(rule.Kind));
            modes.Add(rule.Kind, mode);
            stack.Children.Add(Row(rule.Label, mode));
        }
        domains.Text = original.InternalDomains;
        stack.Children.Add(Row("内部域名后缀", domains));
        stack.Children.Add(new TextBlock { Text = "多个后缀用空格或逗号分隔，例如 corp.example", TextWrapping = TextWrapping.Wrap });
        stack.Children.Add(new Separator { Margin = new Thickness(0, 10, 0, 8) });
        stack.Children.Add(new TextBlock { Text = "自定义正则规则", FontWeight = FontWeights.SemiBold });
        stack.Children.Add(customEntries);
        foreach (var rule in original.CustomRules)
            AddCustom(rule);
        var add = Button("添加规则");
        add.HorizontalAlignment = HorizontalAlignment.Left;
        add.Click += (_, _) => AddCustom(new CustomPrivacyRule("", "", PrivacyRuleMode.Review));
        stack.Children.Add(add);
        return stack;
    }

    private StackPanel ModelSettings()
    {
        var stack = new StackPanel { Margin = new Thickness(12) };
        language.Text = original.OcrLanguages;
        stack.Children.Add(Row("本机 OCR 语言", language));
        stack.Children.Add(new TextBlock
        {
            Text = "留空使用自动选择。Windows 语言参照 zh-CN、en-US，Tesseract 语言参照 chi_sim+eng。",
            TextWrapping = TextWrapping.Wrap
        });
        copyOcr.IsChecked = original.OcrAutoCopy;
        collapseOcr.IsChecked = original.OcrCollapseNewlines;
        stack.Children.Add(copyOcr);
        stack.Children.Add(collapseOcr);
        stack.Children.Add(new Separator { Margin = new Thickness(0, 10, 0, 8) });
        var provider = new ComboBox { ItemsSource = new[] { "仅本机规则", "DeepSeek", "Qwen（通义千问）",
            "本机模型（Ollama 等）", "自定义兼容服务" } };
        provider.SelectedIndex = original.AiEndpoint switch
        {
            "" => 0,
            var address when address.StartsWith("https://api.deepseek.com", StringComparison.Ordinal) => 1,
            var address when address.StartsWith("https://dashscope.aliyuncs.com", StringComparison.Ordinal) => 2,
            var address when Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.IsLoopback => 3,
            _ => 4
        };
        provider.SelectionChanged += (_, _) =>
        {
            apiKey.Clear();
            clearKey.IsChecked = false;
            (endpoint.Text, model.Text) = provider.SelectedIndex switch
            {
                0 => ("", ""),
                1 => ("https://api.deepseek.com", "deepseek-flash"),
                2 => ("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
                3 => ("http://127.0.0.1:11434/v1", ""),
                _ => (endpoint.Text, model.Text)
            };
        };
        stack.Children.Add(Row("AI 补查预设", provider));
        endpoint.Text = original.AiEndpoint;
        model.Text = original.AiModel;
        stack.Children.Add(Row("服务地址", endpoint));
        stack.Children.Add(Row("模型名称", model));
        stack.Children.Add(Row("API Key", apiKey));
        var test = Button("测试连接");
        bool testing = false;
        test.HorizontalAlignment = HorizontalAlignment.Left;
        test.ToolTip = "发送一段合成文字来测试连接";
        test.Click += async (_, _) =>
        {
            testing = true;
            test.IsEnabled = false;
            status.Text = "正在用合成文字测试…";
            try
            {
                await RecognitionAi.TestAsync(AiDraft(), apiKey.Password.Trim(), lifetime.Token);
                status.Text = "模型连接成功";
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
            catch (Exception error) { status.Text = error.Message; }
            finally { testing = false; RefreshKey(); }
        };
        void RefreshKey()
        {
            var uri = RecognitionAi.TryEndpoint(AiDraft());
            test.IsEnabled = uri is not null && !testing;
            bool has = false;
            try
            {
                has = uri is not null && RecognitionAi.HasKey(uri);
                keyStatus.Text = has ? "留空保留此服务的密钥。" : "本机模型可留空。远程服务请填写对应的 API Key。";
            }
            catch (Exception error) when (error is System.Security.Cryptography.CryptographicException or JsonException or IOException)
            { keyStatus.Text = "无法读取此服务的密钥。可保存新密钥。"; }
            clearKey.IsEnabled = has;
            if (!has) clearKey.IsChecked = false;
        }
        endpoint.TextChanged += (_, _) => { apiKey.Clear(); clearKey.IsChecked = false; RefreshKey(); };
        model.TextChanged += (_, _) => RefreshKey();
        RefreshKey();
        stack.Children.Add(test);
        stack.Children.Add(clearKey);
        stack.Children.Add(keyStatus);
        stack.Children.Add(new Separator { Margin = new Thickness(0, 10, 0, 8) });
        python.Text = original.FormulaPython;
        var pythonRow = new DockPanel();
        var pick = Button("浏览…");
        DockPanel.SetDock(pick, Dock.Right);
        pick.Click += (_, _) =>
        {
            var dialog = new OpenFileDialog { Filter = "Python 解释器 (python.exe)|python.exe", CheckFileExists = true };
            if (dialog.ShowDialog(this) == true) python.Text = dialog.FileName;
        };
        pythonRow.Children.Add(pick);
        pythonRow.Children.Add(python);
        stack.Children.Add(Row("公式 Python 路径", pythonRow));
        stack.Children.Add(new TextBlock { Text = "留空使用 Install-Formula.ps1 安装的本机环境。", TextWrapping = TextWrapping.Wrap });
        return stack;
    }

    private RecognitionSettings AiDraft() => new() { AiEndpoint = endpoint.Text.Trim(), AiModel = model.Text.Trim() };

    private StackPanel TranslationSettings()
    {
        var stack = new StackPanel { Margin = new Thickness(12) };
        (translationEndpoint.Text, translationModel.Text) = RecognitionAi.TranslationDraft(original);
        stack.Children.Add(new TextBlock
        {
            Text = "启动本机兼容服务，填入已安装的模型。翻译和隐私补查可以使用不同模型。",
            TextWrapping = TextWrapping.Wrap
        });
        stack.Children.Add(Row("本机服务地址", translationEndpoint));
        stack.Children.Add(Row("本机模型名称", translationModel));
        stack.Children.Add(new TextBlock
        {
            Text = "Ollama 默认地址为 http://127.0.0.1:11434/v1，可用 ollama list 查看已安装模型。",
            TextWrapping = TextWrapping.Wrap
        });
        var test = Button("测试本机模型");
        test.HorizontalAlignment = HorizontalAlignment.Left;
        test.ToolTip = "用示例文字翻译，不读取截图";
        test.Click += async (_, _) =>
        {
            test.IsEnabled = false;
            status.Text = "正在测试本机翻译模型…";
            try
            {
                var draft = new RecognitionSettings
                {
                    TranslationEndpoint = translationEndpoint.Text.Trim(),
                    TranslationModel = translationModel.Text.Trim()
                };
                string translated = await RecognitionAi.TranslateAsync("Hello", "English", "简体中文",
                    draft, lifetime.Token, timeoutSeconds: 20);
                status.Text = string.IsNullOrWhiteSpace(translated) ? "模型没有返回译文。" : "本机翻译模型已就绪。";
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
            catch (Exception error) { status.Text = error.Message; }
            finally { test.IsEnabled = true; }
        };
        stack.Children.Add(test);
        return stack;
    }

    private void AddCustom(CustomPrivacyRule rule)
    {
        var name = new TextBox { Text = rule.Name, ToolTip = "规则名称" };
        var pattern = new TextBox { Text = rule.Pattern, ToolTip = "正则表达式" };
        var mode = ModeBox(rule.Mode);
        var panel = new StackPanel { Margin = new Thickness(0, 8, 0, 5) };
        panel.Children.Add(Row("名称", name));
        panel.Children.Add(Row("正则表达式", pattern));
        var actions = new DockPanel();
        var remove = Button("移除");
        DockPanel.SetDock(remove, Dock.Right);
        actions.Children.Add(remove);
        actions.Children.Add(Row("规则模式", mode));
        panel.Children.Add(actions);
        panel.Children.Add(new Separator());
        var entry = new CustomEntry(name, pattern, mode);
        customs.Add(entry);
        remove.Click += (_, _) =>
        {
            customs.Remove(entry);
            customEntries.Children.Remove(panel);
        };
        customEntries.Children.Add(panel);
    }

    private void Save()
    {
        try
        {
            string localEndpoint = translationEndpoint.Text.Trim();
            string localModel = translationModel.Text.Trim();
            if (localModel.Length > 0 && RecognitionAi.TryTranslationEndpoint(localEndpoint, localModel) is null)
                throw new InvalidOperationException("本机翻译地址必须指向本机服务。");
            var settings = new RecognitionSettings
            {
                ScanAutomatically = scan.IsChecked == true,
                OcrLanguages = language.Text.Trim(),
                OcrAutoCopy = copyOcr.IsChecked == true,
                OcrCollapseNewlines = collapseOcr.IsChecked == true,
                InternalDomains = domains.Text.Trim(),
                AiEndpoint = endpoint.Text.Trim(),
                AiModel = model.Text.Trim(),
                TranslationEndpoint = localEndpoint,
                TranslationModel = localModel,
                FormulaPython = python.Text.Trim()
            };
            foreach (var field in modes)
                settings.Modes[field.Key] = (PrivacyRuleMode)field.Value.SelectedIndex;
            foreach (var input in customs)
            {
                string name = input.Name.Text.Trim(), pattern = input.Pattern.Text;
                if (name.Length == 0 || pattern.Length is < 1 or > 512)
                    throw new InvalidOperationException("每条自定义规则需要名称和 1–512 个字符的正则表达式。");
                try { _ = new Regex(pattern, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(35)); }
                catch (ArgumentException) { throw new InvalidOperationException($"自定义规则「{name}」的正则语法有误。"); }
                settings.CustomRules.Add(new CustomPrivacyRule(name, pattern, (PrivacyRuleMode)input.Mode.SelectedIndex));
            }
            Uri? aiEndpoint = settings.AiEndpoint.Length > 0 || settings.AiModel.Length > 0 ? RecognitionAi.Endpoint(settings) : null;
            if (settings.FormulaPython.Length > 0 &&
                (!Path.IsPathFullyQualified(settings.FormulaPython) || !File.Exists(settings.FormulaPython)))
                throw new InvalidOperationException("请填写本机已存在的完整 Python 路径。");

            if (apiKey.Password.Length > 0 || clearKey.IsChecked == true)
                RecognitionAi.SaveKey(clearKey.IsChecked == true ? "" : apiKey.Password.Trim(), aiEndpoint);
            RecognitionService.SaveSettings(settings);
            Close();
        }
        catch (Exception error) { status.Text = error.Message; }
    }

    private static DockPanel Row(string name, FrameworkElement input)
    {
        var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
        var label = new Label { Content = name, Target = input, Width = 166, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(label, Dock.Left);
        row.Children.Add(label);
        input.MinHeight = 26;
        row.Children.Add(input);
        return row;
    }

    private static ComboBox ModeBox(PrivacyRuleMode initial) => new()
    {
        ItemsSource = new[] { "自动遮盖", "仅提示", "关闭" },
        SelectedIndex = (int)initial,
        HorizontalAlignment = HorizontalAlignment.Stretch
    };

    private static Button Button(string title) => new()
    {
        Content = title, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(3)
    };

    private sealed record CustomEntry(TextBox Name, TextBox Pattern, ComboBox Mode);
}

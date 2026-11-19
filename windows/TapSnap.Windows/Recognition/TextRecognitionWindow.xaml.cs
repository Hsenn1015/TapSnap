using System;
using System.Globalization;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using DrawingRect = System.Drawing.Rectangle;
using Forms = System.Windows.Forms;

namespace TapSnap.Windows;

internal sealed partial class TextRecognitionWindow : Window
{
    private readonly BitmapSource image;
    private readonly RecognitionImagePreview original;
    private readonly CancellationToken token;
    private readonly StatusToast toast = new();
    private OcrTextDocument? document;
    private string? recognitionError;
    private Task<string>? markdownTask;
    private bool markdownReady;
    private string? previewedSource;
    private int viewRevision;

    private bool ByLine => LineMode.IsChecked == true;
    private bool IsMarkdown => MarkdownMode.IsChecked == true;
    private bool IsSource => SourceMode.IsChecked == true;
    private bool HasText => document is { LineRows.Length: > 0 };

    internal TextRecognitionWindow(BitmapSource image)
    {
        this.image = image;
        var lifetime = new CancellationTokenSource();
        token = lifetime.Token;
        InitializeComponent();
        original = new RecognitionImagePreview(image);
        OriginalHost.Content = original;
        PositionNearCursor();

        foreach (var radio in new[] { ParagraphMode, LineMode, MarkdownMode, PreviewMode, SourceMode })
            radio.Checked += async (_, _) => await RefreshModeAsync();
        Search.TextChanged += (_, _) => FilterRows();
        MarkdownEditor.TextChanged += (_, _) => UpdateCopyButton();
        Loaded += async (_, _) => { if (document is null) await RecognizeAsync(); };
        PreviewKeyDown += (_, args) =>
        {
            if (args.Key == Key.Escape)
            {
                args.Handled = true;
                Close();
            }
            else if (args.Key == Key.F && Keyboard.Modifiers == ModifierKeys.Control && !IsMarkdown)
            {
                args.Handled = true;
                Search.Focus();
                Search.SelectAll();
            }
        };
        Closed += (_, _) =>
        {
            lifetime.Cancel();
            lifetime.Dispose();
            toast.Dismiss();
        };
    }

    private void PositionNearCursor()
    {
        var cursor = Forms.Cursor.Position;
        var screen = Forms.Screen.FromPoint(cursor);
        double scale = Desktop.ScaleForMonitor(screen.Bounds);
        var area = screen.WorkingArea;
        int margin = (int)Math.Round(12 * scale);
        area.Inflate(-margin, -margin);
        Width = Math.Min(860, area.Width / scale);
        Height = Math.Min(540, area.Height / scale);
        MinWidth = Math.Min(660, Width);
        MinHeight = Math.Min(310, Height);
        int width = (int)Math.Round(Width * scale);
        int height = (int)Math.Round(Height * scale);
        var bounds = new DrawingRect(Math.Clamp(cursor.X - width / 2, area.Left, area.Right - width),
            Math.Clamp(cursor.Y + margin, area.Top, area.Bottom - height), width, height);
        SourceInitialized += (_, _) => Desktop.Place(this, bounds);
    }

    private async Task RecognizeAsync()
    {
        try
        {
            var config = RecognitionService.Settings;
            var lines = await RecognitionService.ReadTextAsync(image, config.OcrLanguages, token);
            var text = await Task.Run(() => OcrTextDocument.From(lines), token);
            token.ThrowIfCancellationRequested();
            var updated = SetDocumentAsync(text);
            if (config.OcrAutoCopy && HasText)
                Copy(config.OcrCollapseNewlines ? string.Join(" ", text.OriginalLines.Select(line => line.Text)) : text.CopyText(false));
            await updated;
        }
        catch (Exception error)
        {
            if (token.IsCancellationRequested) return;
            recognitionError = error.Message;
            ShowHint(recognitionError);
        }
    }

    internal Task SetDocumentAsync(OcrTextDocument text)
    {
        document = text;
        return RefreshModeAsync();
    }

    private async Task RefreshModeAsync()
    {
        int revision = ++viewRevision;
        MarkdownModes.Visibility = IsMarkdown ? Visibility.Visible : Visibility.Collapsed;
        CountLabel.Visibility = SearchRow.Visibility = Rows.Visibility = IsMarkdown ? Visibility.Collapsed : Visibility.Visible;
        MarkdownEditor.Visibility = MarkdownReader.Visibility = Visibility.Collapsed;
        UpdateCopyButton();
        if (!IsMarkdown)
        {
            FilterRows();
            return;
        }

        ClearLocation();
        if (!HasText || document is not { } text)
        {
            ShowHint(DocumentHint());
            return;
        }

        try
        {
            if (!markdownReady)
            {
                ShowHint("正在整理 Markdown…");
                var source = await (markdownTask ??= Task.Run(() => OcrMarkdown.Source(text, () =>
                {
                    token.ThrowIfCancellationRequested();
                    return RecognitionEngine.DetectTable(image) is { } grid ? OcrTable.Read(grid, text.OriginalLines) : null;
                }), token));
                if (token.IsCancellationRequested || viewRevision != revision) return;
                markdownReady = true;
                MarkdownEditor.Text = source;
                UpdateCopyButton();
            }
            if (IsSource)
            {
                ShowHint(null);
                MarkdownEditor.Visibility = Visibility.Visible;
                return;
            }

            string currentSource = MarkdownEditor.Text;
            if (previewedSource != currentSource)
            {
                ShowHint("正在整理 Markdown…");
                var parsed = await Task.Run(() => OcrMarkdownPreview.Parse(currentSource), token);
                if (token.IsCancellationRequested || viewRevision != revision) return;
                MarkdownReader.Document = OcrMarkdownPreview.Render(parsed);
                previewedSource = currentSource;
            }
            ShowHint(null);
            MarkdownReader.Visibility = Visibility.Visible;
        }
        catch (Exception error)
        {
            if (token.IsCancellationRequested || viewRevision != revision) return;
            if (!markdownReady) markdownTask = null;
            ShowHint("无法整理 Markdown：" + error.Message);
        }
    }

    private void FilterRows()
    {
        if (IsMarkdown) return;
        ClearLocation();
        var all = ByLine ? document?.LineRows : document?.Paragraphs;
        string term = Search.Text.Trim();
        var comparison = CultureInfo.CurrentCulture.CompareInfo;
        var filtered = term.Length == 0 ? all : all?.Where(row => comparison.IndexOf(row.Text, term,
            CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreWidth) >= 0).ToArray();
        Rows.ItemsSource = filtered;
        if (filtered is { Length: > 0 }) Rows.ScrollIntoView(filtered[0]);
        CountLabel.Text = all is null ? "" : $"{all.Length} {(ByLine ? "行" : "段")}";
        ShowHint(filtered is { Length: 0 } && HasText ? "没有匹配的文字" : DocumentHint());
    }

    private string? DocumentHint() => recognitionError ??
        (document is null ? "识别中…" : HasText ? null : "未识别到文字");

    private void ShowHint(string? message)
    {
        Hint.Text = message ?? "";
        Hint.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ClearLocation()
    {
        Rows.SelectedItem = null;
        original.Locate(Rect.Empty);
    }

    private void UpdateCopyButton()
    {
        CopyLabel.Text = IsMarkdown ? "复制 Markdown" : "复制全部";
        AutomationProperties.SetName(CopyAll, CopyLabel.Text);
        CopyAll.ToolTip = IsMarkdown ? "复制当前 Markdown 源码" : "复制当前模式的全部文字";
        CopyAll.IsEnabled = IsMarkdown ? markdownReady && MarkdownEditor.Text.Length > 0 : HasText;
    }

    private void Locate_Click(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { DataContext: OcrReviewRow row }) return;
        Rows.SelectedItem = row;
        original.Locate(RecognitionService.ToRect(row.Bounds));
    }

    private void CopyRow_Click(object sender, RoutedEventArgs args)
    {
        if (sender is Button { DataContext: OcrReviewRow row }) Copy(row.Text);
    }

    private void CopyAll_Click(object sender, RoutedEventArgs args) =>
        Copy(IsMarkdown ? MarkdownEditor.Text : document?.CopyText(ByLine) ?? "");

    private void Close_Click(object sender, RoutedEventArgs args) => Close();

    private void Copy(string text)
    {
        if (text.Length == 0) return;
        try
        {
            Clipboard.SetText(text);
            toast.Show("已复制");
        }
        catch (System.Runtime.InteropServices.ExternalException) { toast.Show("剪贴板正忙，请重试"); }
    }
}

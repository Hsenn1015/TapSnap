using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ScreenRect = System.Drawing.Rectangle;

namespace TapSnap.Windows;

public sealed partial class EditorWindow : Window
{
    private const double ZoomStep = 1.25;
    private readonly BitmapSource source;
    private readonly AnnotationSurface canvas;
    private readonly Canvas textLayer = new() { ClipToBounds = true, IsHitTestVisible = false };
    private readonly StackPanel toolbar = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel zoomControls = new() { Orientation = Orientation.Horizontal, Width = 94, Margin = new Thickness(4, 0, 0, 0) };
    private readonly Button zoomFit;
    private IReadOnlyDictionary<string, Hotkey>? operationHotkeys;
    private readonly Border toolbarDock;
    private readonly Grid body = new();
    private readonly ScrollViewer canvasViewport;
    private readonly Border status = new() { Height = 30, Visibility = Visibility.Collapsed };
    private readonly DockPanel statusContent = new() { Margin = new Thickness(9, 0, 8, 0) };
    private readonly TextBlock statusLabel = new() { VerticalAlignment = VerticalAlignment.Center, FontSize = 11 };
    private readonly Button review = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(4, 4, 0, 4) };
    private readonly Button stop = new() { Content = "停止识别", Visibility = Visibility.Collapsed, Margin = new Thickness(4, 4, 0, 4) };
    private readonly Action<BitmapSource> copy, save, pin, scanPrivacy;
    private readonly Action startLongShot, startRecording;
    private readonly List<(string Title, Action<BitmapSource> Run)> outputs = new();
    private Action? openRules;
    private Action? stopScan;
    private Func<bool>? isAiConfigured;
    private Action<BitmapSource>? scanText, scanImage;
    private Action<BitmapSource, Int32Rect>? scanCroppedText, scanCroppedImage;
    private Func<BitmapSource, bool, bool, Task<IReadOnlyList<Rect>>>? detectMosaic;
    private Func<BitmapSource, bool>? finish;
    private string completionTitle = "完成";
    private string? scanProgress;
    private readonly SnapPalette palette;
    private readonly AnnotationStyle defaults;
    private AnnotationStyle privacyAppearance = new() { Mask = MaskStyle.Frosted, BlockSize = 8, Color = Color.FromRgb(70, 86, 108) };
    private Action<string, int, int>? savePrivacyAppearance;
    private readonly Dictionary<AnnotationTool, AnnotationStyle> styles = new();
    private readonly List<Annotation> items = new();
    private readonly List<PendingRedaction> candidates = new();
    private readonly Stack<DocumentState> undo = new(), redo = new();
    private AnnotationTool? tool;
    private int selected = -1;
    private Rect? crop;
    private double cropRatio;
    private bool scanning;
    private Popup? stylePopup;
    private TextBox? inline;
    private Annotation? inlineTag;
    private int textIndex = -1;
    private Annotation? dragOriginal;
    private DocumentState? dragBefore;
    private AnnotationHandle? resizeHandle;
    private Point? start;
    private readonly List<Point> path = new();
    private readonly List<Point> polygon = new();
    private Annotation? draft;
    private Rect? cropDraft;
    private Rect? originalCrop;
    private Guid? focusedCandidate;
    private readonly List<Rect> knownPrivacyBounds = new();
    private readonly List<Rect> ignoredPrivacyBounds = new();
    private bool showStatus;
    private int laidOutSlots;
    private bool longShotLayout;
    private bool originalLongShotPixels;
    private readonly List<Button> longShotOutputs = new();
    public Int32Rect PixelCrop
    {
        get
        {
            Rect bounds = crop ?? canvas.ImageRect;
            int left = (int)Math.Floor(bounds.Left), top = (int)Math.Floor(bounds.Top);
            return new Int32Rect(left, top, (int)Math.Ceiling(bounds.Right) - left, (int)Math.Ceiling(bounds.Bottom) - top);
        }
    }

    private sealed record DocumentState(Annotation[] Items, Rect? Crop, PendingRedaction[] Candidates, Rect[] Ignored);
    internal sealed record Draft(BitmapSource Image, DateTime CapturedAt, Annotation[] Items, Rect? Crop);
    internal DateTime CapturedAt { get; set; } = DateTime.Now;
    internal event Action? ProtectOriginal;
    internal event Action<BitmapSource>? ReviewedOutput;
    private bool privacyReviewRequired;
    internal bool LocalScanCompleted { get; set; }

    internal Draft SaveDraft()
    {
        FinishText(save: true);
        return new Draft(source, CapturedAt, items.ToArray(), crop);
    }

    internal void RestoreDraft(Draft document)
    {
        Restore(new DocumentState(document.Items, document.Crop, [], []));
        RefreshSurface();
    }

    internal void BeginPrivacyReview(bool startsLocalScan = true)
    {
        privacyReviewRequired = true;
        if (startsLocalScan) LocalScanCompleted = false;
        ProtectOriginal?.Invoke();
    }

    public EditorWindow(BitmapSource image, Action<BitmapSource> copy, Action<BitmapSource> save,
                        Action<BitmapSource> pin, Action startLongShot, Action startRecording,
                        Action<BitmapSource> scanPrivacy, bool dark = false, double defaultLineWidth = 3,
                        double defaultFontSize = 14, int defaultMosaicBlockSize = 12, bool autoMosaicFaces = false)
    {
        source = image;
        this.copy = copy;
        this.save = save;
        this.pin = pin;
        this.startLongShot = startLongShot;
        this.startRecording = startRecording;
        this.scanPrivacy = scanPrivacy;
        palette = SnapPalette.For(dark);
        defaults = new AnnotationStyle
        {
            LineWidth = defaultLineWidth, FontSize = defaultFontSize, BlockSize = defaultMosaicBlockSize,
            DetectFaces = autoMosaicFaces
        };

        Title = $"TapSnap 编辑 – {image.PixelWidth} × {image.PixelHeight}";
        MinWidth = 288;
        MinHeight = 139;
        Width = Math.Max(MinWidth, Math.Min(1200, image.PixelWidth + 14));
        Height = Math.Max(MinHeight, Math.Min(880, image.PixelHeight + 90));
        Background = palette.EditorChrome;
        Foreground = palette.Foreground;
        FontSize = 12;
        UseLayoutRounding = true;
        SnapTheme.StyleWindow(this);

        var root = new DockPanel();
        DockPanel.SetDock(status, Dock.Top);
        status.Background = palette.Panel;
        DockPanel.SetDock(stop, Dock.Right);
        stop.Click += (_, _) => stopScan?.Invoke();
        statusContent.Children.Add(stop);
        DockPanel.SetDock(review, Dock.Right);
        review.Click += (_, _) => ShowReview();
        statusContent.Children.Add(review);
        statusContent.Children.Add(statusLabel);
        status.Child = statusContent;
        root.Children.Add(status);

        var zoomOut = ZoomButton(OperationShortcut.ZoomOut, "−", 24, () => ZoomCanvas(1 / ZoomStep));
        zoomFit = ZoomButton(OperationShortcut.FitImage, "100%", 42, () => ZoomCanvas(null));
        var zoomIn = ZoomButton(OperationShortcut.ZoomIn, "+", 24, () => ZoomCanvas(ZoomStep));
        zoomControls.Children.Add(zoomOut);
        zoomControls.Children.Add(zoomFit);
        zoomControls.Children.Add(zoomIn);
        var dock = new DockPanel();
        DockPanel.SetDock(zoomControls, Dock.Right);
        dock.Children.Add(zoomControls);
        dock.Children.Add(toolbar);

        toolbarDock = new Border
        {
            Background = palette.EditorChrome,
            BorderBrush = SnapTheme.Brush(dark ? 0xfafafau : 0x0a0a0a, 31),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Height = 44,
            Padding = new Thickness(8, 0, 8, 0),
            ClipToBounds = true,
            Child = dock
        };
        DockPanel.SetDock(toolbarDock, Dock.Bottom);
        root.Children.Add(toolbarDock);
        AutomationProperties.SetName(toolbar, "标注工具栏");
        toolbarDock.SizeChanged += (_, _) => LayoutToolbar();

        canvas = new AnnotationSurface(image, palette.Canvas);
        body.Children.Add(canvas);
        body.Children.Add(textLayer);
        canvasViewport = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Background = palette.Canvas,
            Focusable = false,
            Content = body
        };
        root.Children.Add(canvasViewport);
        Content = root;

        canvas.MouseLeftButtonDown += CanvasDown;
        canvas.MouseLeftButtonUp += CanvasUp;
        canvas.MouseMove += CanvasMove;
        canvas.MouseLeave += (_, _) =>
        {
            if (start is null && polygon.Count == 0) { draft = null; RefreshSurface(); }
        };
        canvas.LostMouseCapture += (_, _) =>
        {
            if (start is not null)
            {
                CancelDrag();
                RefreshSurface();
            }
        };
        canvas.SizeChanged += (_, _) => { PositionTextBox(); UpdateZoomLabel(); };
        canvasViewport.PreviewMouseWheel += (_, e) =>
        {
            if (longShotLayout || Keyboard.Modifiers != ModifierKeys.Control) return;
            ZoomCanvas(Math.Pow(ZoomStep, e.Delta / 120d), e.GetPosition(canvasViewport));
            e.Handled = true;
        };
        PreviewKeyDown += HandleKey;
        Closed += (_, _) => { if (stylePopup is not null) stylePopup.IsOpen = false; };
        RefreshSurface();
    }

    public void AnchorToCapture(ScreenRect captured, bool opensWithPrivacyScan)
    {
        var screen = System.Windows.Forms.Screen.FromRectangle(captured);
        var visible = screen.WorkingArea;
        double dpi = Desktop.ScaleForMonitor(screen.Bounds);
        if (opensWithPrivacyScan)
        {
            showStatus = true;
            scanProgress = "正在本机识别…";
            RefreshSurface();
        }
        double toolbar = 44 + (opensWithPrivacyScan ? status.Height : 0);
        double padding = 2 * AnnotationSurface.Padding;
        double titleHeight = SystemParameters.WindowCaptionHeight + SystemParameters.ResizeFrameHorizontalBorderHeight;
        double maxWidth = visible.Width / dpi;
        double maxHeight = visible.Height / dpi - titleHeight;
        double imageWidth = source.PixelWidth / dpi;
        double imageHeight = source.PixelHeight / dpi;
        double fit = Math.Max(0.001, Math.Min(1, Math.Min((maxWidth - padding) / imageWidth,
            (maxHeight - padding - toolbar) / imageHeight)));
        Width = Math.Min(maxWidth, Math.Max(Math.Min(MinWidth, maxWidth), imageWidth * fit + padding));
        Height = Math.Min(maxHeight + titleHeight, Math.Max(Math.Min(MinHeight, maxHeight), imageHeight * fit + padding + toolbar + titleHeight));
        WindowStartupLocation = WindowStartupLocation.Manual;

        int width = Math.Clamp((int)Math.Round(Width * dpi), 1, visible.Width);
        int height = Math.Clamp((int)Math.Round(Height * dpi), 1, visible.Height);
        var rough = new ScreenRect(
            Math.Clamp(captured.Left + (captured.Width - width) / 2, visible.Left, visible.Right - width),
            Math.Clamp(captured.Top + (captured.Height - height) / 2, visible.Top, visible.Bottom - height), width, height);
        SourceInitialized += (_, _) => Desktop.Place(this, rough);
        RoutedEventHandler? loaded = null;
        loaded = (_, _) =>
        {
            Loaded -= loaded;
            if (!Desktop.TryWindowBounds(this, out var bounds)) return;
            var current = canvas.PointToScreen(new Point(canvas.ActualWidth / 2, canvas.ActualHeight / 2));
            int x = (int)Math.Round(bounds.Left + captured.Left + captured.Width / 2d - current.X);
            int y = (int)Math.Round(bounds.Top + captured.Top + captured.Height / 2d - current.Y);
            Desktop.Place(this, new ScreenRect(
                Math.Clamp(x, visible.Left, Math.Max(visible.Left, visible.Right - bounds.Width)),
                Math.Clamp(y, visible.Top, Math.Max(visible.Top, visible.Bottom - bounds.Height)),
                bounds.Width, bounds.Height), keepSize: true);
        };
        Loaded += loaded;
    }

    public void RegisterOutput(string title, Action<BitmapSource> action)
    {
        outputs.Add((title, action));
        if (IsLoaded) LayoutToolbar(force: true);
    }

    public void UseLongShotLayout()
    {
        if (longShotLayout) return;
        longShotLayout = true;
        Title = $"TapSnap 长截图预览 – {source.PixelWidth} × {source.PixelHeight}";
        Width = 620;
        Height = 720;
        MinWidth = 382;
        MinHeight = 320;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        zoomControls.Visibility = Visibility.Collapsed;
        canvasViewport.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        canvasViewport.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        canvasViewport.HorizontalContentAlignment = HorizontalAlignment.Left;
        canvasViewport.SizeChanged += (_, _) => SizeLongShotSurface();
        canvasViewport.ScrollChanged += (_, e) =>
        {
            if (e.ViewportWidthChange != 0) SizeLongShotSurface();
        };
        SourceInitialized += (_, _) => Desktop.Exclude(this);
        DpiChanged += (_, _) => SizeLongShotSurface();
        LayoutToolbar(force: true);
    }

    private void SizeLongShotSurface()
    {
        double width = originalLongShotPixels ? source.PixelWidth / VisualTreeHelper.GetDpi(this).DpiScaleX :
            canvasViewport.ViewportWidth - AnnotationSurface.Padding * 2;
        width = Math.Max(1, width);
        body.Width = width + AnnotationSurface.Padding * 2;
        body.Height = width * source.PixelHeight / source.PixelWidth + AnnotationSurface.Padding * 2;
        if (focusedCandidate is Guid id && candidates.FirstOrDefault(c => c.Id == id) is { } candidate)
            canvasViewport.ScrollToVerticalOffset(candidate.Bounds.Top * canvas.Scale);
    }

    private void BuildLongShotToolbar()
    {
        toolbar.Children.Clear();
        longShotOutputs.Clear();
        var fit = OptionAction("适合宽度");
        var pixels = OptionAction("原始像素");
        fit.Click += (_, _) => ChangeScale(false);
        pixels.Click += (_, _) => ChangeScale(true);
        var privacy = NewIcon("隐私打码", "shield");
        privacy.Click += (_, _) => Activate(Tool("隐私打码", "shield", AnnotationTool.Privacy), privacy);
        var pinOutput = OptionAction("贴图", () => Export(pin, close: true), closePopup: false);
        var copyOutput = OptionAction("复制", () => Export(copy), closePopup: false);
        var saveOutput = OptionAction("保存", SaveLongShot, closePopup: false);
        foreach (var button in new[] { fit, pixels, privacy, pinOutput, copyOutput, saveOutput }) toolbar.Children.Add(button);
        longShotOutputs.AddRange(new[] { pinOutput, copyOutput, saveOutput });
        ChangeScale(originalLongShotPixels);
        UpdateButtons();

        void ChangeScale(bool pixelMode)
        {
            double fraction = canvasViewport.ScrollableHeight > 0 ?
                canvasViewport.VerticalOffset / canvasViewport.ScrollableHeight : 0;
            originalLongShotPixels = pixelMode;
            fit.Background = pixelMode ? palette.Hover : palette.Primary;
            fit.Foreground = pixelMode ? palette.Foreground : palette.PrimaryForeground;
            pixels.Background = pixelMode ? palette.Primary : palette.Hover;
            pixels.Foreground = pixelMode ? palette.PrimaryForeground : palette.Foreground;
            SizeLongShotSurface();
            _ = Dispatcher.BeginInvoke(() => canvasViewport.ScrollToVerticalOffset(
                fraction * canvasViewport.ScrollableHeight), System.Windows.Threading.DispatcherPriority.Loaded);
        }
    }

    internal void ApplyOperationHotkeys(IReadOnlyDictionary<string, Hotkey>? bindings)
    {
        operationHotkeys = bindings;
        foreach (Button button in zoomControls.Children)
        {
            if (button.Tag is OperationShortcut action && button.ToolTip is ToolTip tip)
                tip.Content = Shortcuts.WithHint(action.Title, ShortcutLabel(action));
        }
        if (IsLoaded) LayoutToolbar(force: true);
    }

    private string? ShortcutLabel(OperationShortcut? operation) =>
        operation?.Binding(operationHotkeys) is { } binding ? Shortcuts.Display(binding) : null;

    private Button ZoomButton(OperationShortcut operation, string symbol, double width, Action run)
    {
        var button = NewIcon(operation.Title, symbol, ShortcutLabel(operation));
        button.Tag = operation;
        button.Width = width;
        button.Click += (_, _) => run();
        return button;
    }

    private void UpdateZoomLabel()
    {
        double percent = Math.Round(canvas.Scale * 100);
        zoomFit.Content = percent == 0 ? "<1%" : $"{percent:0}%";
    }

    private void ZoomCanvas(double? factor, Point? anchor = null)
    {
        if (start is not null || canvasViewport.ViewportWidth <= 0 || canvasViewport.ViewportHeight <= 0) return;
        var size = new Size(canvasViewport.ActualWidth, canvasViewport.ActualHeight);
        double fit = canvas.FitScale(size);
        double? scale = factor is double step ? Math.Clamp(canvas.Scale * step, Math.Min(.1, fit), Math.Max(8, fit)) : null;
        if (scale == canvas.ZoomScale || scale == canvas.Scale) return;
        var point = anchor ?? new Point(canvasViewport.ViewportWidth / 2, canvasViewport.ViewportHeight / 2);
        Point imagePoint = canvas.ToImage(canvasViewport.TranslatePoint(point, canvas));

        canvas.SetZoom(scale);
        double padding = 2 * AnnotationSurface.Padding;
        body.MinWidth = scale.HasValue ? Math.Ceiling(source.PixelWidth * scale.Value + padding) : 0;
        body.MinHeight = scale.HasValue ? Math.Ceiling(source.PixelHeight * scale.Value + padding) : 0;
        var visibility = scale.HasValue ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled;
        canvasViewport.HorizontalScrollBarVisibility = visibility;
        canvasViewport.VerticalScrollBarVisibility = visibility;
        canvasViewport.UpdateLayout();
        if (scale.HasValue)
        {
            Vector drift = canvas.TranslatePoint(canvas.ToWindow(imagePoint), canvasViewport) - point;
            canvasViewport.ScrollToHorizontalOffset(Math.Max(0, canvasViewport.HorizontalOffset + drift.X));
            canvasViewport.ScrollToVerticalOffset(Math.Max(0, canvasViewport.VerticalOffset + drift.Y));
            canvasViewport.UpdateLayout();
        }
        PositionTextBox();
        UpdateZoomLabel();
    }

    private void SaveLongShot()
    {
        Export(output =>
        {
            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                Filter = "PNG 图片|*.png", AddExtension = true,
                FileName = $"TapSnap-{DateTime.Now:yyyy-MM-dd-HHmmss}.png"
            };
            if (dialog.ShowDialog(this) != true) return;
            using var stream = File.Create(dialog.FileName);
            Images.Encode(output, stream, ".png");
        });
    }

    public void RegisterPrivacyActions(Action openRules, Action<BitmapSource> scanText, Action<BitmapSource> scanImage)
    {
        this.openRules = openRules;
        this.scanText = scanText;
        this.scanImage = scanImage;
    }

    public void RegisterPrivacyActions(Action openRules, Action<BitmapSource, Int32Rect> scanText,
                                       Action<BitmapSource, Int32Rect> scanImage)
    {
        this.openRules = openRules;
        scanCroppedText = scanText;
        scanCroppedImage = scanImage;
    }

    public void SetCompletionAction(Func<BitmapSource, bool> action, string? title = null)
    {
        finish = action;
        completionTitle = string.IsNullOrWhiteSpace(title) ? "完成" : title;
        if (IsLoaded) LayoutToolbar(force: true);
    }

    public void RegisterPrivacyControls(Action stopScan, Func<bool> isAiConfigured)
    {
        this.stopScan = stopScan;
        this.isAiConfigured = isAiConfigured;
    }

    public void ConfigurePrivacyAppearance(string style, int patternSize, int rgb, Action<string, int, int> saveAppearance)
    {
        privacyAppearance = defaults with
        {
            Mask = Enum.TryParse(style, ignoreCase: true, out MaskStyle mask) && Enum.IsDefined(mask) ? mask : MaskStyle.Frosted,
            BlockSize = Math.Clamp(patternSize, 3, 24),
            Color = Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb)
        };
        savePrivacyAppearance = saveAppearance;
    }

    private void RememberPrivacyAppearance(AnnotationStyle style)
    {
        privacyAppearance = style;
        savePrivacyAppearance?.Invoke((style.Mask ?? MaskStyle.Frosted).ToString(),
            Math.Clamp(style.BlockSize, 3, 24), style.Color.R << 16 | style.Color.G << 8 | style.Color.B);
    }

    public void RegisterMosaicDetection(Func<BitmapSource, bool, bool, Task<IReadOnlyList<Rect>>> detect) =>
        detectMosaic = detect;

    public void SetPrivacyScanning(bool active, string? progress = null)
    {
        scanning = active;
        scanProgress = progress;
        showStatus = true;
        RefreshSurface();
    }

    public void AddPrivacyMasks(IEnumerable<Rect> pixelRects)
    {
        var added = new List<Rect>();
        foreach (Rect rectangle in pixelRects.Select(r => Rect.Intersect(r, canvas.ImageRect)).Where(IsArea))
        {
            if (knownPrivacyBounds.Any(old => SamePrivacyRegion(old, rectangle))) continue;
            knownPrivacyBounds.Add(rectangle);
            if (!items.Any(item => item.IsPrivacyMask && SamePrivacyRegion(item.Bounds, rectangle))) added.Add(rectangle);
        }
        if (added.Count > 0)
        {
            Remember();
            foreach (Rect rectangle in added)
            {
                items.Add(FromRect(AnnotationTool.Privacy, rectangle, CurrentStyle(AnnotationTool.Privacy)));
                candidates.RemoveAll(old => SamePrivacyRegion(old.Bounds, rectangle));
            }
        }
        showStatus = true;
        RefreshSurface();
    }

    public void AddPrivacyCandidates(IEnumerable<(string Label, Rect Bounds)> found)
    {
        showStatus = true;
        foreach (var (label, bounds) in found)
        {
            Rect clipped = Rect.Intersect(bounds, canvas.ImageRect);
            if (!IsArea(clipped) || candidates.Any(item => SamePrivacyRegion(item.Bounds, clipped)) ||
                knownPrivacyBounds.Any(old => SamePrivacyRegion(old, clipped))) continue;
            knownPrivacyBounds.Add(clipped);
            candidates.Add(new PendingRedaction(Guid.NewGuid(), label, clipped));
        }
        RefreshSurface();
    }

    private static bool IsArea(Rect r) => !r.IsEmpty && r.Width > 0 && r.Height > 0;
    private static bool SamePrivacyRegion(Rect a, Rect b)
    {
        Rect overlap = Rect.Intersect(a, b);
        return IsArea(overlap) && overlap.Width * overlap.Height >= 0.8 * Math.Max(a.Width * a.Height, b.Width * b.Height);
    }

    private void Export(Action<BitmapSource> output, bool close = false, bool includeCrop = true, bool forReview = false)
    {
        if (scanning) return;
        if (!forReview && privacyReviewRequired)
        {
            var visible = includeCrop ? crop ?? canvas.ImageRect : canvas.ImageRect;
            foreach (var known in knownPrivacyBounds)
            {
                var area = Rect.Intersect(known, visible);
                if (!IsArea(area) || ignoredPrivacyBounds.Contains(known) ||
                    items.Any(i => i.IsPrivacyMask && i.Bounds.Contains(area)) ||
                    candidates.Any(c => SamePrivacyRegion(c.Bounds, known))) continue;
                candidates.Add(new PendingRedaction(Guid.NewGuid(), "重新检查遮盖", known));
            }
            if (candidates.Any(c => IsArea(Rect.Intersect(c.Bounds, visible))))
            {
                RefreshSurface();
                ShowReview();
                return;
            }
            if (!LocalScanCompleted && MessageBox.Show(this, "本机扫描未完成。已手动检查并继续输出？", "隐私复查",
                    MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
        }
        FinishText(save: true);
        try
        {
            var image = canvas.Render(includeCrop);
            if (!forReview && includeCrop && (privacyReviewRequired || items.Any(i => i.IsPrivacyMask)))
                ReviewedOutput?.Invoke(image);
            output(image);
            if (close) Close();
        }
        catch (Exception exception)
        {
            MessageBox.Show(this, exception.Message, "TapSnap", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void Print() => Export(image => PrintImage(image, Title));

    internal static void PrintImage(BitmapSource image, string title)
    {
        var dialog = new PrintDialog();
        if (dialog.ShowDialog() != true) return;
        double scale = Math.Min(dialog.PrintableAreaWidth / image.PixelWidth, dialog.PrintableAreaHeight / image.PixelHeight);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen()) dc.DrawImage(image, new Rect(0, 0, image.PixelWidth * scale, image.PixelHeight * scale));
        dialog.PrintVisual(visual, title);
    }

    private void Confirm()
    {
        if (finish is null)
        {
            Export(copy, close: true);
            return;
        }
        Export(image => { if (finish(image)) Close(); });
    }

    private AnnotationStyle CurrentStyle(AnnotationTool kind)
    {
        if (styles.TryGetValue(kind, out AnnotationStyle? style)) return style;
        return kind switch
        {
            AnnotationTool.Privacy => privacyAppearance,
            AnnotationTool.Highlight => defaults with { Color = Color.FromRgb(255, 204, 0), LineWidth = 6 },
            AnnotationTool.Text => defaults with { Bold = true },
            AnnotationTool.Watermark => defaults with { Color = Colors.White, FontSize = 24, Opacity = 0.6 },
            AnnotationTool.Number => defaults with { Bold = true },
            _ => defaults
        };
    }

    private int NextNumber() => items.Where(item => item.Tool == AnnotationTool.Number)
        .Select(item => item.Number).DefaultIfEmpty(0).Max() + 1;

    private void CanvasDown(object sender, MouseButtonEventArgs args)
    {
        Point point = canvas.ToImage(args.GetPosition(canvas));
        AnnotationHandle? cropGrip = tool == AnnotationTool.Crop && crop is Rect currentCrop ? canvas.HitHandle(currentCrop, point) : null;
        if (!canvas.ImageRect.Contains(point) && cropGrip is null) return;
        if (stylePopup is not null) stylePopup.IsOpen = false;
        FinishText(save: true);
        canvas.Focus();

        if (tool == AnnotationTool.Privacy)
        {
            PendingRedaction? candidate = candidates.LastOrDefault(item => item.Bounds.Contains(point));
            if (candidate is not null)
            {
                ApplyCandidate(candidate);
                args.Handled = true;
                return;
            }
        }

        int hit = HitIndex(point);
        if (tool == AnnotationTool.Polygon)
        {
            if (args.ClickCount == 2 || polygon.Count >= 3 && (point - polygon[0]).Length < 10 / canvas.Scale)
                FinishPolygon();
            else
                polygon.Add(point);
        }
        else if (tool == AnnotationTool.Number)
        {
            start = point;
            draft = new Annotation(AnnotationTool.Number, new[] { point }, CurrentStyle(AnnotationTool.Number), Number: NextNumber());
            canvas.CaptureMouse();
        }
        else if (tool == AnnotationTool.Eraser)
        {
            dragBefore = Snapshot();
            start = point;
            EraseAt(point);
            canvas.CaptureMouse();
        }
        else if (tool == AnnotationTool.Crop)
        {
            start = point;
            resizeHandle = cropGrip;
            originalCrop = crop is Rect prior && (cropGrip.HasValue || prior.Contains(point)) ? prior : null;
            cropDraft = null;
            if (!canvas.CaptureMouse()) EndDrag();
        }
        else if (args.ClickCount == 2 && hit >= 0 && (items[hit].Tool == AnnotationTool.Text ||
                 items[hit].Tool == AnnotationTool.Watermark && items[hit].Style.Watermark == WatermarkContent.Text))
        {
            CancelDrag();
            Select(hit);
            BeginText(items[hit], hit);
        }
        else if (selected >= 0 && items[selected].Tool != AnnotationTool.Number &&
                 canvas.HitHandle(items[selected], point) is AnnotationHandle handle)
        {
            BeginTransform(point, selected, handle);
        }
        else if (hit >= 0 && (tool != AnnotationTool.Privacy || items[hit].IsPrivacyMask))
        {
            BeginTransform(point, hit);
        }
        else if (tool is not null)
        {
            selected = -1;
            start = point;
            path.Clear();
            path.Add(point);
            canvas.CaptureMouse();
        }
        else Select(-1);
        RefreshSurface();
        args.Handled = true;
    }

    private void CanvasMove(object sender, MouseEventArgs args)
    {
        Point point = Clamp(canvas.ToImage(args.GetPosition(canvas)));
        if (start is Point down && args.LeftButton == MouseButtonState.Pressed)
        {
            if (dragOriginal is Annotation original && selected >= 0)
            {
                items[selected] = resizeHandle is AnnotationHandle handle
                    ? original.Resize(handle.Resize(original.Bounds, point - down))
                    : original.Move(point - down);
            }
            else if (tool == AnnotationTool.Crop) cropDraft = CropAt(down, canvas.ToImage(args.GetPosition(canvas)));
            else if (tool == AnnotationTool.Eraser) EraseAt(point);
            else if (tool is AnnotationTool kind) draft = CreateDraft(kind, point);
        }
        else if (tool == AnnotationTool.Number && canvas.ImageRect.Contains(canvas.ToImage(args.GetPosition(canvas))))
        {
            draft = new Annotation(AnnotationTool.Number, new[] { point }, CurrentStyle(AnnotationTool.Number), Number: NextNumber());
        }
        else if (tool == AnnotationTool.Polygon && polygon.Count > 0)
        {
            draft = new Annotation(AnnotationTool.Polygon, polygon.Append(point).ToArray(), CurrentStyle(AnnotationTool.Polygon));
        }
        RefreshSurface();
        if (resizeHandle is AnnotationHandle dragging) canvas.Cursor = dragging.RotationFreeCursor;
        else if (tool == AnnotationTool.Crop)
        {
            if (originalCrop.HasValue) canvas.Cursor = Cursors.SizeAll;
            else if (start is null && crop is Rect area)
            {
                Point mouse = canvas.ToImage(args.GetPosition(canvas));
                canvas.Cursor = canvas.HitHandle(area, mouse)?.RotationFreeCursor ??
                    (area.Contains(mouse) ? Cursors.SizeAll : Cursors.Cross);
            }
        }
        else if (selected >= 0 && items[selected].Tool != AnnotationTool.Number &&
            canvas.HitHandle(items[selected], point) is AnnotationHandle hovered)
            canvas.Cursor = hovered.RotationFreeCursor;
    }

    private void CanvasUp(object sender, MouseButtonEventArgs args)
    {
        if (start is not Point down) return;
        Point mouse = canvas.ToImage(args.GetPosition(canvas));
        Point point = Clamp(mouse);
        bool dragged = ((tool == AnnotationTool.Crop ? mouse : point) - down).Length * canvas.Scale >= 2;
        if (tool == AnnotationTool.Number)
        {
            Add(new Annotation(AnnotationTool.Number, new[] { point }, CurrentStyle(AnnotationTool.Number), Number: NextNumber()));
        }
        else if (dragBefore is DocumentState before)
        {
            if (dragOriginal is not null && selected >= 0)
            {
                items[selected] = dragged
                    ? resizeHandle is AnnotationHandle handle ? dragOriginal.Resize(handle.Resize(dragOriginal.Bounds, point - down)) : dragOriginal.Move(point - down)
                    : dragOriginal;
                if (dragged) Remember(before);
            }
            else if (!before.Items.SequenceEqual(items)) Remember(before);
        }
        else if (tool == AnnotationTool.Crop)
        {
            Rect next = CropAt(down, mouse);
            if (dragged && IsArea(next) && crop != next)
            {
                Remember();
                crop = next;
            }
        }
        else if (tool is AnnotationTool.Text or AnnotationTool.Watermark)
        {
            AnnotationTool kind = tool.Value;
            AnnotationStyle style = CurrentStyle(kind);
            Rect bounds = dragged ? new Rect(down, point) : new Rect(down, new Size(220, Math.Max(40, style.FontSize * 2.2)));
            bounds = Rect.Intersect(bounds, canvas.ImageRect);
            if (IsArea(bounds))
            {
                var mark = FromRect(kind, bounds, style) with { CapturedAt = CapturedAt };
                if (kind == AnnotationTool.Text || style.Watermark == WatermarkContent.Text) BeginText(mark, -1);
                else if (style.Watermark != WatermarkContent.Image || style.Logo != null) Add(mark);
                else if (Images.OpenImage(pngOnly: true) is { } logo)
                {
                    styles[kind] = style with { Logo = logo };
                    Add(mark with { Style = styles[kind] });
                }
            }
        }
        else if (dragged && tool is AnnotationTool current && CreateDraft(current, point) is Annotation item)
        {
            if (item.Tool == AnnotationTool.Mosaic && detectMosaic is not null && !scanning &&
                (item.Style.DetectFaces || item.Style.DetectText) && IsArea(item.Bounds))
                _ = DetectMosaic(item);
            else if (!item.IsPrivacyMask || IsArea(item.Bounds)) Add(item);
        }
        else if (tool == AnnotationTool.Magnifier)
            Add(FromRect(AnnotationTool.Magnifier, new Rect(point.X - 50, point.Y - 50, 100, 100), CurrentStyle(AnnotationTool.Magnifier)));

        EndDrag();
        if (tool == AnnotationTool.Number)
            draft = new Annotation(AnnotationTool.Number, new[] { point }, CurrentStyle(AnnotationTool.Number), Number: NextNumber());
        RefreshSurface();
        args.Handled = true;
    }

    private Rect CropAt(Point anchor, Point pointer)
    {
        if (originalCrop is not Rect initial)
            return FitCrop(new Rect(Clamp(anchor), Clamp(pointer)), Math.Sign(pointer.X - anchor.X), Math.Sign(pointer.Y - anchor.Y));
        Vector delta = pointer - anchor;
        Rect image = canvas.ImageRect;
        if (resizeHandle is AnnotationHandle handle)
            return FitCrop(Rect.Intersect(image, handle.Resize(initial, delta)), handle.X, handle.Y);
        return new Rect(Math.Clamp(initial.X + delta.X, image.Left, image.Right - initial.Width),
            Math.Clamp(initial.Y + delta.Y, image.Top, image.Bottom - initial.Height), initial.Width, initial.Height);
    }

    private Rect FitCrop(Rect bounds, int x, int y)
    {
        if (cropRatio == 0 || bounds.IsEmpty) return bounds;
        double width = Math.Min(bounds.Width, bounds.Height * cropRatio), height = width / cropRatio;
        return new Rect(bounds.Left + (bounds.Width - width) * (1 - x) / 2,
            bounds.Top + (bounds.Height - height) * (1 - y) / 2, width, height);
    }

    private void BeginTransform(Point point, int hit, AnnotationHandle? handle = null)
    {
        Select(hit, keepTool: true);
        start = point;
        dragOriginal = items[hit];
        dragBefore = Snapshot();
        resizeHandle = handle;
        draft = null;
        canvas.CaptureMouse();
    }

    private Annotation? CreateDraft(AnnotationTool kind, Point point)
    {
        if (start is not Point down || kind is AnnotationTool.Crop or AnnotationTool.Eraser) return null;
        AnnotationStyle style = CurrentStyle(kind);
        if (kind == AnnotationTool.Number) return new Annotation(kind, new[] { point }, style, Number: NextNumber());
        if (kind is AnnotationTool.Pen or AnnotationTool.Highlight or AnnotationTool.PathTag)
        {
            if ((path[^1] - point).Length * canvas.Scale > 0.8 || path.Count == 1) path.Add(point);
            return new Annotation(kind, path.ToArray(), style);
        }
        if (kind is AnnotationTool.Text or AnnotationTool.Watermark)
            return FromRect(AnnotationTool.Rectangle, new Rect(down, point), style with { Pattern = StrokePattern.Dash });
        return new Annotation(kind, new[] { down, point }, style);
    }

    private void EndDrag()
    {
        start = null;
        dragOriginal = null;
        dragBefore = null;
        resizeHandle = null;
        draft = null;
        cropDraft = null;
        originalCrop = null;
        path.Clear();
        if (canvas.IsMouseCaptured) canvas.ReleaseMouseCapture();
    }

    private void CancelDrag()
    {
        if (dragBefore is DocumentState before) Restore(before);
        EndDrag();
    }

    private void FinishPolygon()
    {
        if (polygon.Count >= 3)
            Add(new Annotation(AnnotationTool.Polygon, polygon.ToArray(), CurrentStyle(AnnotationTool.Polygon)));
        polygon.Clear();
        draft = null;
        RefreshSurface();
    }

    private void Select(int index, bool keepTool = false)
    {
        selected = index;
        if (!keepTool && index >= 0) tool = items[index].Tool;
        UpdateButtons();
    }

    private void Add(Annotation item)
    {
        if (item.IsPrivacyMask) ProtectOriginal?.Invoke();
        Remember();
        items.Add(item);
        selected = items.Count - 1;
        UpdateButtons();
    }

    private async Task DetectMosaic(Annotation item)
    {
        Rect bounds = Rect.Intersect(item.Bounds, canvas.ImageRect);
        int left = (int)Math.Floor(bounds.Left), top = (int)Math.Floor(bounds.Top);
        int width = (int)Math.Ceiling(bounds.Right) - left, height = (int)Math.Ceiling(bounds.Bottom) - top;
        SetPrivacyScanning(true);
        try
        {
            var image = new CroppedBitmap(source, new Int32Rect(left, top, width, height));
            image.Freeze();
            var detections = await detectMosaic!(image, item.Style.DetectFaces, item.Style.DetectText);
            if (!IsLoaded) return;
            var boxes = detections.Select(detection => Rect.Intersect(detection, new Rect(0, 0, width, height)))
                .Where(IsArea).ToArray();
            if (boxes.Length == 0) Add(item);
            else
            {
                Remember();
                foreach (Rect detection in boxes)
                {
                    Rect clipped = detection;
                    clipped.Offset(left, top);
                    items.Add(FromRect(AnnotationTool.Mosaic, clipped, item.Style));
                }
                selected = items.Count - 1;
            }
        }
        catch (Exception)
        {
            if (IsLoaded) Add(item);
        }
        finally
        {
            if (IsLoaded) SetPrivacyScanning(false);
        }
    }

    private void EraseAt(Point point)
    {
        int index = HitIndex(point);
        if (index < 0) return;
        items.RemoveAt(index);
        selected = -1;
    }

    private int HitIndex(Point point) => items.FindLastIndex(item => item.Hit(point, 5 / canvas.Scale));

    private Point Clamp(Point point) => new(Math.Clamp(point.X, 0, canvas.ImageRect.Width),
                                            Math.Clamp(point.Y, 0, canvas.ImageRect.Height));

    private static Annotation FromRect(AnnotationTool kind, Rect rect, AnnotationStyle style)
        => new(kind, new[] { rect.TopLeft, rect.BottomRight }, style);

    private DocumentState Snapshot() => new(items.ToArray(), crop, candidates.ToArray(), ignoredPrivacyBounds.ToArray());

    private void Remember(DocumentState? state = null)
    {
        undo.Push(state ?? Snapshot());
        redo.Clear();
    }

    private void Restore(DocumentState state)
    {
        items.Clear();
        items.AddRange(state.Items);
        candidates.Clear();
        candidates.AddRange(state.Candidates);
        ignoredPrivacyBounds.Clear();
        ignoredPrivacyBounds.AddRange(state.Ignored);
        crop = state.Crop;
        selected = -1;
    }

    private void TraverseHistory(Stack<DocumentState> from, Stack<DocumentState> to)
    {
        FinishText(save: true);
        if (!from.TryPop(out DocumentState? previous)) return;
        to.Push(Snapshot());
        Restore(previous);
        RefreshSurface();
    }

    private void HandleKey(object sender, KeyEventArgs args)
    {
        if (inline is not null || (stylePopup?.IsOpen ?? false)) return;
        if (OperationShortcut.Match(Shortcuts.FromEvent(args), operationHotkeys) is { } action &&
            RunOperationShortcut(action, args.IsRepeat))
        {
            args.Handled = true;
            return;
        }
        if (args.Key == Key.Escape)
        {
            if (start is not null) CancelDrag();
            else if (polygon.Count > 0) { polygon.Clear(); draft = null; }
            else if (tool == AnnotationTool.Crop)
            {
                if (crop is not null) { Remember(); crop = null; }
                tool = null;
            }
            else if (selected >= 0) Select(-1);
            else Close();
        }
        else if (args.Key == Key.Enter && polygon.Count > 0) FinishPolygon();
        else if (args.Key == Key.Enter && tool == AnnotationTool.Crop && crop is not null)
        {
            tool = null;
        }
        else if (args.Key is (Key.Delete or Key.Back) && selected >= 0)
        {
            Remember();
            items.RemoveAt(selected);
            Select(-1);
        }
        else return;
        args.Handled = true;
        RefreshSurface();
    }

    private bool RunOperationShortcut(OperationShortcut action, bool repeat)
    {
        Action<BitmapSource>? output = action.Output switch
        {
            CaptureAction.Copy => copy,
            CaptureAction.Save => save,
            CaptureAction.Pin when !longShotLayout => pin,
            _ => null
        };
        if (output is not null) { if (!repeat) Export(output); }
        else if (action == OperationShortcut.Undo) TraverseHistory(undo, redo);
        else if (action == OperationShortcut.Redo) TraverseHistory(redo, undo);
        else if (longShotLayout) return false;
        else if (action == OperationShortcut.ZoomIn) ZoomCanvas(ZoomStep);
        else if (action == OperationShortcut.ZoomOut) ZoomCanvas(1 / ZoomStep);
        else if (action == OperationShortcut.FitImage) ZoomCanvas(null);
        else if (action.Tool is { } annotation) { if (!repeat) PickTool(annotation); }
        else return false;
        return true;
    }

    private void BeginText(Annotation item, int index)
    {
        inlineTag = item;
        textIndex = index;
        var input = new TextBox
        {
            Text = item.Text,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(3, 1, 3, 1),
            BorderBrush = AnnotationDrawing.Brush(Color.FromRgb(60, 146, 255)),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        AutomationProperties.SetName(input, "文字标注");
        bool composing = false;
        TextCompositionManager.AddPreviewTextInputStartHandler(input, (_, args) =>
            composing = args.TextComposition.AutoComplete == TextCompositionAutoComplete.Off);
        TextCompositionManager.AddPreviewTextInputUpdateHandler(input, (_, args) =>
            composing = args.TextComposition.CompositionText.Length > 0 || args.TextComposition.SystemCompositionText.Length > 0);
        TextCompositionManager.AddPreviewTextInputHandler(input, (_, _) => composing = false);
        input.LostKeyboardFocus += (_, _) => composing = false;
        input.PreviewKeyDown += (_, args) =>
        {
            if (composing || args.Key == Key.ImeProcessed) return;
            if (args.Key == Key.Escape) { FinishText(save: false); args.Handled = true; }
            if (args.Key == Key.Enter && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
                { FinishText(save: true); args.Handled = true; }
        };
        inline = input;
        textLayer.IsHitTestVisible = true;
        textLayer.Children.Add(input);
        PositionTextBox();
        input.Focus();
        input.CaretIndex = input.Text.Length;
        RefreshSurface();
    }

    private void PositionTextBox()
    {
        if (inline is not TextBox input || inlineTag is not Annotation item) return;
        Rect bounds = item.Bounds;
        Point topLeft = canvas.ToWindow(bounds.TopLeft);
        Canvas.SetLeft(input, topLeft.X);
        Canvas.SetTop(input, topLeft.Y);
        input.Width = Math.Max(36, bounds.Width * canvas.Scale);
        input.MinHeight = bounds.Height * canvas.Scale;
        input.MaxHeight = Math.Max(input.MinHeight, canvas.ActualHeight - topLeft.Y);
        input.FontSize = Math.Max(8, item.Style.FontSize * canvas.Scale);
        input.FontFamily = new FontFamily(item.Style.FontFamily);
        input.FontWeight = item.Style.Bold ? FontWeights.Bold : FontWeights.Normal;
        input.FontStyle = item.Style.Italic ? FontStyles.Italic : FontStyles.Normal;
        var decorations = new TextDecorationCollection();
        if (item.Style.Underline) decorations.Add(TextDecorations.Underline);
        if (item.Style.Strikethrough) decorations.Add(TextDecorations.Strikethrough);
        input.TextDecorations = decorations;
        input.TextAlignment = item.Style.Alignment;
        input.Foreground = AnnotationDrawing.Brush(item.Style.Color);
        input.Background = item.Style.TextBackground is Color bg ? AnnotationDrawing.Brush(bg) : AnnotationDrawing.Brush(Colors.White, 0.8);
    }

    private void FinishText(bool save)
    {
        if (inline is not TextBox input || inlineTag is not Annotation item) return;
        int index = textIndex;
        inline = null;
        inlineTag = null;
        textIndex = -1;
        textLayer.Children.Remove(input);
        textLayer.IsHitTestVisible = false;
        if (save && !string.IsNullOrWhiteSpace(input.Text) && (index < 0 || item.Text != input.Text))
        {
            double height = Math.Max(item.Bounds.Height, input.ExtentHeight / canvas.Scale + 6);
            Rect bounds = item.Bounds;
            bounds.Height = Math.Min(height, canvas.ImageRect.Bottom - bounds.Y);
            Annotation edited = FromRect(item.Tool, bounds, item.Style) with { Text = input.Text, CapturedAt = item.CapturedAt };
            if (index < 0) Add(edited);
            else { Remember(); items[index] = edited; }
        }
        canvas.Focus();
        RefreshSurface();
    }

    private void RefreshSurface()
    {
        canvas.Items = items;
        canvas.Draft = draft;
        canvas.Crop = crop;
        canvas.DraftCrop = cropDraft;
        canvas.IsCropping = tool == AnnotationTool.Crop;
        canvas.Selected = selected;
        canvas.Editing = textIndex;
        canvas.Candidates = candidates;
        canvas.SelectedCandidate = focusedCandidate;
        canvas.InvalidateVisual();
        canvas.Cursor = tool == AnnotationTool.Number && draft is not null ? Cursors.None :
            tool == AnnotationTool.Text ? Cursors.IBeam : tool is null ? Cursors.Arrow : Cursors.Cross;
        status.Visibility = showStatus ? Visibility.Visible : Visibility.Collapsed;
        review.Content = $"待打码 {candidates.Count}";
        review.Visibility = candidates.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        stop.Visibility = scanning && stopScan is not null ? Visibility.Visible : Visibility.Collapsed;
        statusLabel.Text = scanProgress ?? (scanning ? "正在扫描图片…" :
            items.Count(item => item.IsPrivacyMask) is int masked && masked > 0 ? $"已打码 {masked} 处" :
            candidates.Count > 0 ? "请选择要遮盖的内容" : "未识别到敏感内容");
        UpdateButtons();
    }

    private void ApplyCandidate(PendingRedaction candidate)
    {
        Remember();
        candidates.Remove(candidate);
        knownPrivacyBounds.Add(candidate.Bounds);
        focusedCandidate = null;
        items.Add(FromRect(AnnotationTool.Privacy, candidate.Bounds, CurrentStyle(AnnotationTool.Privacy)));
        selected = items.Count - 1;
        RefreshSurface();
    }

    private void ShowReview()
    {
        var panel = new StackPanel { Width = 276, Margin = new Thickness(11) };
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 7) };
        var popup = new Popup
        {
            PlacementTarget = review, Placement = PlacementMode.Bottom, AllowsTransparency = true, StaysOpen = false,
            Child = new Border { Background = palette.Panel, BorderBrush = palette.Border,
                BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Child = panel }
        };
        var apply = OptionAction("全部打码", () =>
        {
            var pending = candidates.ToArray();
            Remember();
            candidates.Clear();
            focusedCandidate = null;
            foreach (PendingRedaction candidate in pending)
            {
                knownPrivacyBounds.Add(candidate.Bounds);
                items.Add(FromRect(AnnotationTool.Privacy, candidate.Bounds, CurrentStyle(AnnotationTool.Privacy)));
            }
            RefreshSurface();
            popup.IsOpen = false;
        }, closePopup: false);
        DockPanel.SetDock(apply, Dock.Right);
        header.Children.Add(apply);
        header.Children.Add(new TextBlock { Text = "待打码", Foreground = palette.Foreground, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center });
        panel.Children.Add(header);
        var rows = new StackPanel();
        panel.Children.Add(new ScrollViewer { MaxHeight = 220, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = rows });
        foreach (PendingRedaction candidate in candidates)
        {
            var row = new DockPanel();
            void RemoveRow() { rows.Children.Remove(row); if (rows.Children.Count == 0) popup.IsOpen = false; }
            var locate = OptionAction("定位", () =>
            {
                focusedCandidate = candidate.Id;
                var bounds = new Rect(canvas.ToWindow(candidate.Bounds.TopLeft), canvas.ToWindow(candidate.Bounds.BottomRight));
                bounds.Inflate(14, 14);
                canvas.BringIntoView(bounds);
                RefreshSurface();
                popup.IsOpen = false;
            }, closePopup: false);
            var mask = OptionAction("打码", () => { ApplyCandidate(candidate); RemoveRow(); }, closePopup: false);
            var ignore = OptionAction("×", () =>
            {
                Remember();
                candidates.Remove(candidate);
                knownPrivacyBounds.Add(candidate.Bounds);
                ignoredPrivacyBounds.Add(candidate.Bounds);
                if (focusedCandidate == candidate.Id) focusedCandidate = null;
                RefreshSurface();
                RemoveRow();
            }, closePopup: false);
            ignore.ToolTip = $"忽略{candidate.Label}";
            foreach (var button in new[] { ignore, mask, locate })
            {
                DockPanel.SetDock(button, Dock.Right);
                row.Children.Add(button);
            }
            row.Children.Add(new TextBlock { Text = candidate.Label, TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center, Foreground = palette.Foreground });
            rows.Children.Add(row);
        }
        popup.IsOpen = true;
    }
}

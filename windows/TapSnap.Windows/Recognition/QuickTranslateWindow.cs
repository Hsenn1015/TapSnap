using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using DrawingRect = System.Drawing.Rectangle;
using Forms = System.Windows.Forms;

namespace TapSnap.Windows;

internal sealed class QuickTranslateWindow : Window
{
    private readonly BitmapSource image;
    private readonly DrawingRect anchorRegion;
    private readonly CancellationTokenSource lifetime = new();
    private readonly StatusToast toast = new();
    private CancellationTokenSource? translateCts;

    private QuickTranslateStyle style;
    private string sourceCode = "auto";
    private string targetCode;
    private string sourceText = "";
    private string translatedText = "";
    private string? errorMessage;
    private bool recognizing = true;
    private bool translating;
    private bool pinned;
    private bool editingSource;
    private bool menuOpen;
    private int bilingualMode = 1; // 0: 仅译文, 1: 双语对照, 2: 原文优先
    private double fontSize;
    private bool isDark;

    private readonly Grid root = new();
    private TextBox? sourceBox;
    private TextBox? resultBox;
    private TextBlock? statusLabel;
    private TextBlock? detectedLabel;
    private Button? engineButton;
    private Button? pinButton;
    private Button? sourceLangButton;
    private Button? targetLangButton;
    private Button? editToggleButton;

    public QuickTranslateWindow(BitmapSource image, DrawingRect anchorRegion)
    {
        this.image = image;
        this.anchorRegion = anchorRegion;
        var ts = RecognitionService.Settings.Translation;
        style = ts.QuickTranslateStyle;
        targetCode = ts.TargetLanguage;
        fontSize = Math.Clamp(ts.QuickTranslateFontSize, 11, 22);
        isDark = SnapTheme.IsDark;

        Title = "TapSnap 截图秒译";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = 440;
        MinWidth = 310;
        MaxWidth = 760;
        MinHeight = 160;
        MaxHeight = 680;
        SizeToContent = SizeToContent.Height;
        UseLayoutRounding = true;
        Content = root;

        RebuildLayout();
        PositionNearAnchor();

        Loaded += async (_, _) => await RecognizeAndTranslateAsync();
        Deactivated += (_, _) =>
        {
            if (!pinned && !menuOpen && !editingSource)
                Close();
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                e.Handled = true;
                Close();
            }
            else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control &&
                     Keyboard.FocusedElement is not TextBox && !string.IsNullOrWhiteSpace(translatedText))
            {
                e.Handled = true;
                CopyText(translatedText);
            }
            else if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control && editingSource)
            {
                e.Handled = true;
                CommitSourceEdit();
            }
        };
        Closed += (_, _) =>
        {
            lifetime.Cancel();
            lifetime.Dispose();
            translateCts?.Cancel();
            translateCts?.Dispose();
            toast.Dismiss();
        };
    }

    private void PositionNearAnchor()
    {
        var screen = Forms.Screen.FromRectangle(anchorRegion);
        double scale = Desktop.ScaleForMonitor(screen.Bounds);
        var area = screen.WorkingArea;
        int w = (int)Math.Round(Width * scale);
        int estH = (int)Math.Round(300 * scale);
        int gap = (int)Math.Round(10 * scale);
        int x = Math.Clamp(anchorRegion.Left + (anchorRegion.Width - w) / 2, area.Left + 8, Math.Max(area.Left + 8, area.Right - w - 8));
        int yBelow = anchorRegion.Bottom + gap;
        int yAbove = anchorRegion.Top - estH - gap;
        int y = yBelow + estH <= area.Bottom - 8
            ? yBelow
            : (yAbove >= area.Top + 8 ? yAbove : Math.Clamp(yBelow, area.Top + 8, Math.Max(area.Top + 8, area.Bottom - estH - 8)));

        SourceInitialized += (_, _) =>
        {
            Desktop.Place(this, new DrawingRect(x, y, w, estH), keepSize: true, raiseTopmost: true);
            Desktop.ApplyCaptureVisibility(this);
        };
    }

    private SolidColorBrush SurfaceBrush() => style switch
    {
        QuickTranslateStyle.CleanCard => SnapTheme.Brush(isDark ? 0x1c1e22u : 0xffffffu, 250),
        QuickTranslateStyle.LiquidGlass => SnapTheme.Brush(isDark ? 0x141b2du : 0xf4f8ffu, 236),
        QuickTranslateStyle.Editorial => SnapTheme.Brush(isDark ? 0x16181du : 0xfdfdfeu, 246),
        QuickTranslateStyle.InlineBilingual => SnapTheme.Brush(isDark ? 0x201c16u : 0xfffcf5u, 248),
        QuickTranslateStyle.DynamicBubble => SnapTheme.Brush(isDark ? 0x131f1cu : 0xf7fefbu, 246),
        _ => SnapTheme.Brush(isDark ? 0x1c1e22u : 0xffffffu, 250)
    };

    private SolidColorBrush BlockBrush() => style switch
    {
        QuickTranslateStyle.CleanCard => SnapTheme.Brush(isDark ? 0x25282eu : 0xf4f5f7u),
        QuickTranslateStyle.LiquidGlass => SnapTheme.Brush(isDark ? 0x1d2740u : 0xe8f1ffu, 200),
        QuickTranslateStyle.Editorial => SnapTheme.Brush(isDark ? 0x1e2128u : 0xf5f6f8u),
        QuickTranslateStyle.InlineBilingual => SnapTheme.Brush(isDark ? 0x2c261bu : 0xfdf3dcu, 220),
        QuickTranslateStyle.DynamicBubble => SnapTheme.Brush(isDark ? 0x1a2c27u : 0xeaf9f2u, 210),
        _ => SnapTheme.Brush(isDark ? 0x25282eu : 0xf4f5f7u)
    };

    private SolidColorBrush AccentBrush() => style switch
    {
        QuickTranslateStyle.CleanCard => SnapTheme.Brush(0x2563ebu),
        QuickTranslateStyle.LiquidGlass => SnapTheme.Brush(0x38bdf8u),
        QuickTranslateStyle.Editorial => SnapTheme.Brush(0x6366f1u),
        QuickTranslateStyle.InlineBilingual => SnapTheme.Brush(0xd97706u),
        QuickTranslateStyle.DynamicBubble => SnapTheme.Brush(0x10b981u),
        _ => SnapTheme.Brush(0x2563ebu)
    };

    private SolidColorBrush BorderBrushForStyle() => style switch
    {
        QuickTranslateStyle.LiquidGlass => SnapTheme.Brush(isDark ? 0x3b82f6u : 0x93c5fdu, 150),
        QuickTranslateStyle.InlineBilingual => SnapTheme.Brush(isDark ? 0xd97706u : 0xf59e0bu, 150),
        QuickTranslateStyle.DynamicBubble => SnapTheme.Brush(isDark ? 0x10b981u : 0x6ee7b7u, 150),
        _ => SnapTheme.Brush(isDark ? 0xffffffu : 0x0f172au, isDark ? (byte)32 : (byte)28)
    };

    private SolidColorBrush FgBrush() => SnapTheme.Brush(isDark ? 0xf3f4f6u : 0x111827u);
    private SolidColorBrush MutedBrush() => SnapTheme.Brush(isDark ? 0x9ca3afu : 0x6b7280u);

    private void RebuildLayout()
    {
        root.Children.Clear();
        sourceBox = null;
        resultBox = null;
        statusLabel = null;
        detectedLabel = null;
        engineButton = null;
        pinButton = null;
        sourceLangButton = null;
        targetLangButton = null;
        editToggleButton = null;

        var outerContainer = new Grid { Margin = new Thickness(16) };

        var cardBorder = new Border
        {
            Background = SurfaceBrush(),
            BorderBrush = BorderBrushForStyle(),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(style == QuickTranslateStyle.DynamicBubble ? 16 : 13),
            Effect = new DropShadowEffect
            {
                BlurRadius = 22,
                ShadowDepth = 6,
                Direction = 270,
                Opacity = isDark ? 0.45 : 0.20,
                Color = Colors.Black
            }
        };

        var cardGrid = new Grid();
        cardBorder.Child = cardGrid;

        if (style == QuickTranslateStyle.Editorial)
        {
            cardGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3.5) });
            cardGrid.ColumnDefinitions.Add(new ColumnDefinition());
            var stripe = new Border
            {
                CornerRadius = new CornerRadius(13, 0, 0, 13),
                Background = new LinearGradientBrush(
                    Color.FromRgb(0x63, 0x66, 0xf1),
                    Color.FromRgb(0x06, 0xb6, 0xd4),
                    90)
            };
            cardGrid.Children.Add(stripe);
            var body = BuildEditorialBody();
            Grid.SetColumn(body, 1);
            cardGrid.Children.Add(body);
        }
        else if (style == QuickTranslateStyle.DynamicBubble)
        {
            outerContainer.ColumnDefinitions.Add(new ColumnDefinition());
            outerContainer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            cardGrid.Children.Add(BuildDynamicBubbleBody());
            outerContainer.Children.Add(cardBorder);
            var rail = BuildDynamicBubbleSideRail();
            Grid.SetColumn(rail, 1);
            outerContainer.Children.Add(rail);
            AddResizeGrip(cardGrid);
            root.Children.Add(outerContainer);
            SyncUiState();
            return;
        }
        else if (style == QuickTranslateStyle.CleanCard)
        {
            cardGrid.Children.Add(BuildCleanCardBody());
        }
        else if (style == QuickTranslateStyle.LiquidGlass)
        {
            cardGrid.Children.Add(BuildLiquidGlassBody());
        }
        else
        {
            cardGrid.Children.Add(BuildInlineBilingualBody());
        }

        AddResizeGrip(cardGrid);
        outerContainer.Children.Add(cardBorder);
        root.Children.Add(outerContainer);
        SyncUiState();
    }

    // --- Style 1: CleanCard (极简分块卡片 - Bento 4-zone) ---

    private UIElement BuildCleanCardBody()
    {
        var stack = new StackPanel { Margin = new Thickness(11, 8, 11, 11) };

        // 1. Draggable top chrome bar
        var topBar = CreateDragHeader();
        pinButton = IconActionButton(pinned ? "📌" : "📍", "置顶窗口", TogglePin, pinned);
        DockPanel.SetDock(pinButton, Dock.Left);
        topBar.Children.Add(pinButton);

        var rightTools = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        rightTools.Children.Add(IconActionButton("Aa", "字号", OpenFontMenu));
        rightTools.Children.Add(IconActionButton("🎨", "切换样式", OpenStyleMenu));
        rightTools.Children.Add(IconActionButton("⚙", "翻译设置", RecognitionService.OpenTranslationSettings));
        rightTools.Children.Add(IconActionButton("×", "关闭", Close));
        DockPanel.SetDock(rightTools, Dock.Right);
        topBar.Children.Add(rightTools);
        stack.Children.Add(topBar);

        // 2. Source block
        var sourceCard = new Border
        {
            Background = BlockBrush(),
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(10, 8, 10, 7),
            Margin = new Thickness(0, 4, 0, 7)
        };
        var sourceStack = new StackPanel();
        sourceBox = CreateSelectableTextBox(readOnly: !editingSource, maxHeight: 168);
        sourceStack.Children.Add(sourceBox);

        var sourceFooter = new DockPanel { Margin = new Thickness(0, 5, 0, 0) };
        var leftSourceBtns = new StackPanel { Orientation = Orientation.Horizontal };
        leftSourceBtns.Children.Add(IconActionButton("📋", "复制原文", () => CopyText(sourceBox?.Text ?? sourceText)));
        detectedLabel = new TextBlock
        {
            FontSize = 11,
            Foreground = AccentBrush(),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(6, 0, 0, 0)
        };
        leftSourceBtns.Children.Add(detectedLabel);
        sourceFooter.Children.Add(leftSourceBtns);

        editToggleButton = IconActionButton(editingSource ? "✓" : "✎", editingSource ? "完成并重译" : "编辑原文", ToggleSourceEdit);
        DockPanel.SetDock(editToggleButton, Dock.Right);
        sourceFooter.Children.Add(editToggleButton);
        sourceStack.Children.Add(sourceFooter);
        sourceCard.Child = sourceStack;
        stack.Children.Add(sourceCard);

        // 3. Language swap bar
        var langBar = new Border
        {
            Background = BlockBrush(),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8, 4, 8, 4),
            Margin = new Thickness(0, 0, 0, 7)
        };
        var langGrid = new Grid();
        langGrid.ColumnDefinitions.Add(new ColumnDefinition());
        langGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        langGrid.ColumnDefinitions.Add(new ColumnDefinition());

        sourceLangButton = PillTextButton($"{TranslationCatalog.LanguageDisplayName(sourceCode)} ▾", OpenSourceLanguageMenu);
        sourceLangButton.HorizontalAlignment = HorizontalAlignment.Center;
        var swapBtn = IconActionButton("⇄", "互换语言", SwapLanguages);
        Grid.SetColumn(swapBtn, 1);
        targetLangButton = PillTextButton($"{TranslationCatalog.LanguageDisplayName(targetCode)} ▾", OpenTargetLanguageMenu);
        targetLangButton.HorizontalAlignment = HorizontalAlignment.Center;
        Grid.SetColumn(targetLangButton, 2);

        langGrid.Children.Add(sourceLangButton);
        langGrid.Children.Add(swapBtn);
        langGrid.Children.Add(targetLangButton);
        langBar.Child = langGrid;
        stack.Children.Add(langBar);

        // 4. Result block
        var resultCard = new Border
        {
            Background = BlockBrush(),
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(10, 8, 10, 8)
        };
        var resultStack = new StackPanel();
        var resultHeader = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        engineButton = PillTextButton("", OpenEngineMenu);
        engineButton.FontWeight = FontWeights.SemiBold;
        DockPanel.SetDock(engineButton, Dock.Left);
        resultHeader.Children.Add(engineButton);

        statusLabel = new TextBlock
        {
            FontSize = 11,
            Foreground = MutedBrush(),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        DockPanel.SetDock(statusLabel, Dock.Right);
        resultHeader.Children.Add(statusLabel);
        resultStack.Children.Add(resultHeader);

        resultBox = CreateSelectableTextBox(readOnly: true, maxHeight: 240);
        resultStack.Children.Add(resultBox);

        var resultFooter = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 5, 0, 0) };
        resultFooter.Children.Add(IconActionButton("📋", "复制译文", () => CopyText(translatedText)));
        resultFooter.Children.Add(IconActionButton("↻", "重新翻译", () => _ = RunTranslateAsync()));
        resultStack.Children.Add(resultFooter);

        resultCard.Child = resultStack;
        stack.Children.Add(resultCard);
        return stack;
    }

    // --- Style 2: LiquidGlass (液态玻璃语义胶囊) ---

    private UIElement BuildLiquidGlassBody()
    {
        var stack = new StackPanel { Margin = new Thickness(12, 10, 12, 11) };
        var header = CreateDragHeader();
        var badge = new Border
        {
            Background = AccentBrush(),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(7, 2, 7, 2),
            Margin = new Thickness(0, 0, 6, 0),
            Child = new TextBlock { Text = "译", Foreground = Brushes.White, FontSize = 11, FontWeight = FontWeights.SemiBold }
        };
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(badge);
        engineButton = PillTextButton("", OpenEngineMenu);
        left.Children.Add(engineButton);
        targetLangButton = PillTextButton($"{TranslationCatalog.LanguageDisplayName(targetCode)} ▾", OpenTargetLanguageMenu);
        left.Children.Add(targetLangButton);
        DockPanel.SetDock(left, Dock.Left);
        header.Children.Add(left);

        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        pinButton = IconActionButton(pinned ? "📌" : "📍", "置顶", TogglePin, pinned);
        right.Children.Add(pinButton);
        right.Children.Add(IconActionButton("Aa", "字号", OpenFontMenu));
        right.Children.Add(IconActionButton("🎨", "样式", OpenStyleMenu));
        right.Children.Add(IconActionButton("📋", "复制译文", () => CopyText(translatedText)));
        right.Children.Add(IconActionButton("×", "关闭", Close));
        DockPanel.SetDock(right, Dock.Right);
        header.Children.Add(right);
        stack.Children.Add(header);

        resultBox = CreateSelectableTextBox(readOnly: true, maxHeight: 240);
        resultBox.Margin = new Thickness(2, 6, 2, 4);
        stack.Children.Add(resultBox);

        var divider = new Border { Height = 1, Background = BorderBrushForStyle(), Margin = new Thickness(0, 4, 0, 5) };
        stack.Children.Add(divider);

        sourceBox = CreateSelectableTextBox(readOnly: true, maxHeight: 90, muted: true, fontScale: 0.88);
        stack.Children.Add(sourceBox);

        statusLabel = new TextBlock { FontSize = 11, Foreground = MutedBrush(), Margin = new Thickness(2, 4, 0, 0) };
        stack.Children.Add(statusLabel);
        return stack;
    }

    // --- Style 3: Editorial (聚光取词取景器) ---

    private UIElement BuildEditorialBody()
    {
        var stack = new StackPanel { Margin = new Thickness(12, 10, 12, 9) };
        resultBox = CreateSelectableTextBox(readOnly: true, maxHeight: 260);
        stack.Children.Add(resultBox);

        statusLabel = new TextBlock { FontSize = 11, Foreground = MutedBrush(), Margin = new Thickness(0, 4, 0, 0) };
        stack.Children.Add(statusLabel);

        var footer = CreateDragHeader();
        footer.Margin = new Thickness(0, 6, 0, 0);
        var left = new StackPanel { Orientation = Orientation.Horizontal };
        engineButton = PillTextButton("", OpenEngineMenu);
        targetLangButton = PillTextButton($"{TranslationCatalog.LanguageDisplayName(targetCode)} ▾", OpenTargetLanguageMenu);
        left.Children.Add(engineButton);
        left.Children.Add(targetLangButton);
        DockPanel.SetDock(left, Dock.Left);
        footer.Children.Add(left);

        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        pinButton = IconActionButton(pinned ? "📌" : "📍", "置顶", TogglePin, pinned);
        right.Children.Add(pinButton);
        right.Children.Add(IconActionButton("Aa", "字号", OpenFontMenu));
        right.Children.Add(IconActionButton("🎨", "样式", OpenStyleMenu));
        right.Children.Add(IconActionButton("📋", "复制译文", () => CopyText(translatedText)));
        right.Children.Add(IconActionButton("×", "关闭", Close));
        DockPanel.SetDock(right, Dock.Right);
        footer.Children.Add(right);
        stack.Children.Add(footer);
        return stack;
    }

    // --- Style 4: InlineBilingual (原地双语高亮卡) ---

    private UIElement BuildInlineBilingualBody()
    {
        var stack = new StackPanel { Margin = new Thickness(12, 9, 12, 10) };
        var header = CreateDragHeader();

        var modePanel = new StackPanel { Orientation = Orientation.Horizontal };
        string[] modeLabels = ["仅译文", "双语", "原文"];
        for (int i = 0; i < modeLabels.Length; i++)
        {
            int idx = i;
            var btn = PillTextButton(modeLabels[idx], () => { bilingualMode = idx; RebuildLayout(); });
            if (bilingualMode == idx)
            {
                btn.Background = AccentBrush();
                btn.Foreground = Brushes.White;
            }
            modePanel.Children.Add(btn);
        }
        DockPanel.SetDock(modePanel, Dock.Left);
        header.Children.Add(modePanel);

        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        engineButton = PillTextButton("", OpenEngineMenu);
        right.Children.Add(engineButton);
        pinButton = IconActionButton(pinned ? "📌" : "📍", "置顶", TogglePin, pinned);
        right.Children.Add(pinButton);
        right.Children.Add(IconActionButton("🎨", "样式", OpenStyleMenu));
        right.Children.Add(IconActionButton("📋", "复制译文", () => CopyText(translatedText)));
        right.Children.Add(IconActionButton("×", "关闭", Close));
        DockPanel.SetDock(right, Dock.Right);
        header.Children.Add(right);
        stack.Children.Add(header);

        if (bilingualMode != 2)
        {
            resultBox = CreateSelectableTextBox(readOnly: true, maxHeight: 220);
            resultBox.Margin = new Thickness(2, 7, 2, 4);
            stack.Children.Add(resultBox);
        }
        if (bilingualMode != 0)
        {
            var srcBorder = new Border
            {
                Background = BlockBrush(),
                CornerRadius = new CornerRadius(7),
                Padding = new Thickness(8, 6, 8, 6),
                Margin = new Thickness(0, 4, 0, 2)
            };
            sourceBox = CreateSelectableTextBox(readOnly: true, maxHeight: 120, muted: bilingualMode == 1, fontScale: 0.9);
            srcBorder.Child = sourceBox;
            stack.Children.Add(srcBorder);
        }

        statusLabel = new TextBlock { FontSize = 11, Foreground = MutedBrush(), Margin = new Thickness(2, 4, 0, 0) };
        stack.Children.Add(statusLabel);
        return stack;
    }

    // --- Style 5: DynamicBubble (灵动岛气泡卡 + 外侧动作豆) ---

    private UIElement BuildDynamicBubbleBody()
    {
        var stack = new StackPanel { Margin = new Thickness(13, 10, 13, 11) };
        var header = CreateDragHeader();
        var pill = new Border
        {
            Background = AccentBrush(),
            CornerRadius = new CornerRadius(11),
            Padding = new Thickness(8, 2, 8, 2),
            Child = new TextBlock { Text = "秒译", Foreground = Brushes.White, FontSize = 11, FontWeight = FontWeights.SemiBold }
        };
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(pill);
        engineButton = PillTextButton("", OpenEngineMenu);
        engineButton.Margin = new Thickness(4, 0, 0, 0);
        targetLangButton = PillTextButton($"{TranslationCatalog.LanguageDisplayName(targetCode)} ▾", OpenTargetLanguageMenu);
        left.Children.Add(engineButton);
        left.Children.Add(targetLangButton);
        DockPanel.SetDock(left, Dock.Left);
        header.Children.Add(left);
        stack.Children.Add(header);

        resultBox = CreateSelectableTextBox(readOnly: true, maxHeight: 240);
        resultBox.Margin = new Thickness(0, 7, 0, 4);
        stack.Children.Add(resultBox);

        statusLabel = new TextBlock { FontSize = 11, Foreground = MutedBrush() };
        stack.Children.Add(statusLabel);
        return stack;
    }

    private UIElement BuildDynamicBubbleSideRail()
    {
        var rail = new StackPanel
        {
            Margin = new Thickness(6, 4, 0, 0),
            VerticalAlignment = VerticalAlignment.Top
        };
        Button Bean(string glyph, string tip, Action click, bool active = false)
        {
            var btn = new Button
            {
                Content = glyph,
                ToolTip = tip,
                Width = 28,
                Height = 28,
                Margin = new Thickness(0, 0, 0, 5),
                FontSize = 12,
                Foreground = active ? Brushes.White : FgBrush(),
                Background = active ? AccentBrush() : SurfaceBrush(),
                BorderBrush = BorderBrushForStyle(),
                BorderThickness = new Thickness(1),
                Cursor = Cursors.Hand,
                Focusable = false
            };
            btn.Click += (_, _) => click();
            return btn;
        }
        pinButton = Bean(pinned ? "📌" : "📍", "置顶", TogglePin, pinned);
        rail.Children.Add(pinButton);
        rail.Children.Add(Bean("📋", "复制译文", () => CopyText(translatedText)));
        rail.Children.Add(Bean("Aa", "字号", OpenFontMenu));
        rail.Children.Add(Bean("🎨", "样式", OpenStyleMenu));
        rail.Children.Add(Bean("⚙", "设置", RecognitionService.OpenTranslationSettings));
        rail.Children.Add(Bean("×", "关闭", Close));
        return rail;
    }

    // --- Shared Controls ---

    private DockPanel CreateDragHeader()
    {
        var header = new DockPanel { Background = Brushes.Transparent, Cursor = Cursors.SizeAll };
        header.MouseLeftButtonDown += (_, e) =>
        {
            if (e.LeftButton == MouseButtonState.Pressed)
                try { DragMove(); } catch (InvalidOperationException) { }
        };
        return header;
    }

    private TextBox CreateSelectableTextBox(bool readOnly, double maxHeight, bool muted = false, double fontScale = 1.0) => new()
    {
        IsReadOnly = readOnly,
        AcceptsReturn = !readOnly,
        TextWrapping = TextWrapping.Wrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        BorderThickness = new Thickness(readOnly ? 0 : 1),
        Background = readOnly ? Brushes.Transparent : SurfaceBrush(),
        Foreground = muted ? MutedBrush() : FgBrush(),
        FontSize = Math.Round(fontSize * fontScale, 1),
        MaxHeight = maxHeight,
        Padding = new Thickness(readOnly ? 0 : 4)
    };

    private Button IconActionButton(string label, string tip, Action action, bool active = false)
    {
        var btn = new Button
        {
            Content = label,
            ToolTip = tip,
            MinWidth = 24,
            Height = 24,
            Padding = new Thickness(4, 0, 4, 0),
            Margin = new Thickness(2, 0, 0, 0),
            FontSize = 11.5,
            Background = active ? AccentBrush() : Brushes.Transparent,
            Foreground = active ? Brushes.White : MutedBrush(),
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand,
            Focusable = false
        };
        btn.Click += (_, _) => action();
        return btn;
    }

    private Button PillTextButton(string label, Action action)
    {
        var btn = new Button
        {
            Content = label,
            Height = 24,
            Padding = new Thickness(7, 0, 7, 0),
            Margin = new Thickness(2, 0, 2, 0),
            FontSize = 11.5,
            Background = Brushes.Transparent,
            Foreground = FgBrush(),
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand,
            Focusable = false
        };
        btn.Click += (_, _) => action();
        return btn;
    }

    private void AddResizeGrip(Grid cardGrid)
    {
        var thumb = new Thumb
        {
            Width = 14,
            Height = 14,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Cursor = Cursors.SizeNWSE,
            Opacity = 0.01
        };
        thumb.DragDelta += (_, e) =>
        {
            SizeToContent = SizeToContent.Manual;
            Width = Math.Clamp(ActualWidth + e.HorizontalChange, MinWidth, MaxWidth);
            Height = Math.Clamp(ActualHeight + e.VerticalChange, MinHeight, MaxHeight);
        };
        if (cardGrid.ColumnDefinitions.Count > 1)
            Grid.SetColumnSpan(thumb, cardGrid.ColumnDefinitions.Count);
        cardGrid.Children.Add(thumb);
    }

    // --- OCR & Translation Pipeline ---

    private async Task RecognizeAndTranslateAsync()
    {
        recognizing = true;
        errorMessage = null;
        SyncUiState();
        try
        {
            var config = RecognitionService.Settings;
            var lines = await RecognitionService.ReadTextAsync(image, config.OcrLanguages, lifetime.Token);
            sourceText = RecognitionEngine.Text(lines).Trim();
            recognizing = false;
            if (sourceText.Length == 0)
            {
                errorMessage = "未识别到文字";
                SyncUiState();
                return;
            }
            SyncUiState();
            await RunTranslateAsync();
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            recognizing = false;
            errorMessage = error.Message;
            SyncUiState();
        }
    }

    private async Task RunTranslateAsync()
    {
        string text = (editingSource && sourceBox is not null ? sourceBox.Text : sourceText).Trim();
        if (text.Length == 0) return;
        sourceText = text;
        translateCts?.Cancel();
        translateCts?.Dispose();
        translateCts = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        var ct = translateCts.Token;

        translating = true;
        errorMessage = null;
        translatedText = "";
        SyncUiState();
        try
        {
            string final = await TranslationEngine.TranslateAsync(
                sourceText, sourceCode, targetCode, RecognitionService.Settings,
                partial => Dispatcher.BeginInvoke(() =>
                {
                    if (ct.IsCancellationRequested) return;
                    translatedText = partial;
                    if (resultBox is not null) resultBox.Text = translatedText;
                }),
                ct);
            if (!ct.IsCancellationRequested)
            {
                translatedText = final;
                translating = false;
                SyncUiState();
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (!ct.IsCancellationRequested)
            {
                translating = false;
                errorMessage = error.Message;
                SyncUiState();
            }
        }
    }

    private void SyncUiState()
    {
        var ts = RecognitionService.Settings.Translation;
        if (engineButton is not null)
            engineButton.Content = $"{ts.ActiveDisplayName()} ▾";
        if (sourceLangButton is not null)
            sourceLangButton.Content = $"{TranslationCatalog.LanguageDisplayName(sourceCode)} ▾";
        if (targetLangButton is not null)
            targetLangButton.Content = $"{TranslationCatalog.LanguageDisplayName(targetCode)} ▾";
        if (detectedLabel is not null)
        {
            string detected = string.IsNullOrWhiteSpace(sourceText)
                ? ""
                : $"已识别 {TranslationCatalog.LanguageDisplayName(TranslationCatalog.DetectLanguageCode(sourceText))}";
            detectedLabel.Text = detected;
        }
        if (sourceBox is not null && !editingSource)
            sourceBox.Text = recognizing ? "正在识别文字…" : sourceText;
        if (resultBox is not null)
        {
            if (!string.IsNullOrEmpty(errorMessage))
                resultBox.Text = errorMessage;
            else if (recognizing)
                resultBox.Text = "正在识别选区文字…";
            else if (translating && translatedText.Length == 0)
                resultBox.Text = $"正在使用 {ts.ActiveDisplayName()} 翻译…";
            else
                resultBox.Text = translatedText;
        }
        if (statusLabel is not null)
        {
            statusLabel.Text = !string.IsNullOrEmpty(errorMessage)
                ? "可点击引擎名即时切换"
                : recognizing ? "识别中…"
                : translating ? "翻译中…"
                : "";
        }
    }

    // --- Interactive Actions ---

    private void TogglePin()
    {
        pinned = !pinned;
        RebuildLayout();
    }

    private void ToggleSourceEdit()
    {
        if (editingSource) CommitSourceEdit();
        else
        {
            editingSource = true;
            RebuildLayout();
            sourceBox?.Focus();
        }
    }

    private void CommitSourceEdit()
    {
        if (sourceBox is not null) sourceText = sourceBox.Text.Trim();
        editingSource = false;
        RebuildLayout();
        _ = RunTranslateAsync();
    }

    private void SwapLanguages()
    {
        string detected = sourceCode == "auto"
            ? TranslationCatalog.DetectLanguageCode(sourceText)
            : sourceCode;
        string resolvedTarget = TranslationCatalog.ResolveTargetLanguage(targetCode, sourceText, sourceCode);
        sourceCode = resolvedTarget;
        targetCode = detected;
        SyncUiState();
        _ = RunTranslateAsync();
    }

    private void ShowContextMenu(Button? anchor, ContextMenu menu)
    {
        menuOpen = true;
        menu.Closed += (_, _) => menuOpen = false;
        menu.PlacementTarget = anchor;
        menu.IsOpen = true;
    }

    private void OpenEngineMenu()
    {
        var menu = new ContextMenu();
        var ts = RecognitionService.Settings.Translation;
        void AddEngine(string label, bool selected, Action apply)
        {
            var item = new MenuItem { Header = label, IsChecked = selected };
            item.Click += (_, _) =>
            {
                apply();
                RecognitionService.SaveSettings(RecognitionService.Settings);
                SyncUiState();
                _ = RunTranslateAsync();
            };
            menu.Items.Add(item);
        }
        foreach (TranslationApiProvider api in Enum.GetValues<TranslationApiProvider>())
        {
            var p = api;
            AddEngine(TranslationCatalog.ApiTitle(p),
                ts.Provider == TranslationProviderKind.Api && ts.ApiProvider == p,
                () => { ts.Provider = TranslationProviderKind.Api; ts.ApiProvider = p; });
        }
        menu.Items.Add(new Separator());
        AddEngine("本机模型", ts.Provider == TranslationProviderKind.Local,
            () => ts.Provider = TranslationProviderKind.Local);
        AddEngine("在线模型（DeepSeek）",
            ts.Provider == TranslationProviderKind.Online && ts.OnlinePreset == OnlineModelPreset.DeepSeek,
            () => { ts.Provider = TranslationProviderKind.Online; ts.OnlinePreset = OnlineModelPreset.DeepSeek; });
        AddEngine("在线模型（通义千问）",
            ts.Provider == TranslationProviderKind.Online && ts.OnlinePreset == OnlineModelPreset.Qwen,
            () => { ts.Provider = TranslationProviderKind.Online; ts.OnlinePreset = OnlineModelPreset.Qwen; });
        AddEngine("在线模型（自定义）",
            ts.Provider == TranslationProviderKind.Online && ts.OnlinePreset == OnlineModelPreset.Custom,
            () => { ts.Provider = TranslationProviderKind.Online; ts.OnlinePreset = OnlineModelPreset.Custom; });
        menu.Items.Add(new Separator());
        var cfg = new MenuItem { Header = "配置翻译服务…" };
        cfg.Click += (_, _) => RecognitionService.OpenTranslationSettings();
        menu.Items.Add(cfg);
        ShowContextMenu(engineButton, menu);
    }

    private void OpenSourceLanguageMenu()
    {
        var menu = new ContextMenu();
        foreach (var option in TranslationCatalog.SourceLanguages)
        {
            var opt = option;
            var item = new MenuItem { Header = opt.DisplayName, IsChecked = sourceCode.Equals(opt.Code, StringComparison.OrdinalIgnoreCase) };
            item.Click += (_, _) =>
            {
                sourceCode = opt.Code;
                SyncUiState();
                _ = RunTranslateAsync();
            };
            menu.Items.Add(item);
        }
        ShowContextMenu(sourceLangButton, menu);
    }

    private void OpenTargetLanguageMenu()
    {
        var menu = new ContextMenu();
        foreach (var option in TranslationCatalog.TargetLanguages)
        {
            var opt = option;
            var item = new MenuItem { Header = opt.DisplayName, IsChecked = targetCode.Equals(opt.Code, StringComparison.OrdinalIgnoreCase) };
            item.Click += (_, _) =>
            {
                targetCode = opt.Code;
                RecognitionService.Settings.Translation.TargetLanguage = opt.Code;
                RecognitionService.SaveSettings(RecognitionService.Settings);
                SyncUiState();
                _ = RunTranslateAsync();
            };
            menu.Items.Add(item);
        }
        ShowContextMenu(targetLangButton, menu);
    }

    private void OpenStyleMenu()
    {
        var menu = new ContextMenu();
        foreach (QuickTranslateStyle candidate in Enum.GetValues<QuickTranslateStyle>())
        {
            var s = candidate;
            var item = new MenuItem { Header = TranslationCatalog.QuickStyleName(s), IsChecked = style == s };
            item.Click += (_, _) =>
            {
                style = s;
                RecognitionService.Settings.Translation.QuickTranslateStyle = s;
                RecognitionService.SaveSettings(RecognitionService.Settings);
                RebuildLayout();
            };
            menu.Items.Add(item);
        }
        ShowContextMenu(null, menu);
    }

    private void OpenFontMenu()
    {
        var menu = new ContextMenu();
        foreach (double size in new[] { 12d, 14d, 16d, 18d })
        {
            double s = size;
            var item = new MenuItem { Header = $"{s:0} pt", IsChecked = Math.Abs(fontSize - s) < 0.5 };
            item.Click += (_, _) =>
            {
                fontSize = s;
                RecognitionService.Settings.Translation.QuickTranslateFontSize = s;
                RecognitionService.SaveSettings(RecognitionService.Settings);
                RebuildLayout();
            };
            menu.Items.Add(item);
        }
        ShowContextMenu(null, menu);
    }

    private void CopyText(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        try
        {
            Clipboard.SetText(text);
            toast.Show("已复制");
        }
        catch (System.Runtime.InteropServices.ExternalException) { toast.Show("剪贴板正忙，请重试"); }
    }
}

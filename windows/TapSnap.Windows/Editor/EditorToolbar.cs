using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using System.Windows.Shapes;

namespace TapSnap.Windows;

public sealed partial class EditorWindow
{
    private sealed record DockTool(string Title, string Symbol, Action Run, AnnotationTool? Tool = null,
                                   bool Options = false, bool Export = false, int Priority = 0);

    private readonly Dictionary<Button, DockTool> dockButtons = new();
    private Button? undoButton, redoButton;
    private static readonly (string Value, string Label)[] InstalledFonts = Fonts.SystemFontFamilies
        .Select(family => (Value: family.Source, Label: family.Source))
        .Distinct().OrderBy(font => font.Label, StringComparer.CurrentCultureIgnoreCase).ToArray();

    private void LayoutToolbar(bool force = false)
    {
        if (longShotLayout)
        {
            if (longShotOutputs.Count == 0) BuildLongShotToolbar();
            return;
        }
        int slots = Math.Max(5, (int)((toolbarDock.ActualWidth - 42) / 29));
        if (!force && laidOutSlots == slots) return;
        laidOutSlots = slots;

        foreach (Button existing in dockButtons.Keys) ToolTipService.SetIsEnabled(existing, false);
        dockButtons.Clear();
        toolbar.Children.Clear();
        var tools = new[]
        {
            Tool("箭头", "↗", AnnotationTool.Arrow), Tool("矩形", "□", AnnotationTool.Rectangle),
            Tool("椭圆", "○", AnnotationTool.Ellipse), Tool("直线", "╱", AnnotationTool.Line),
            Tool("画笔", "✎", AnnotationTool.Pen, priority: 2), Tool("文字标注", "T", AnnotationTool.Text, priority: 1),
            Tool("马赛克", "▦", AnnotationTool.Mosaic, priority: 2), Tool("荧光笔", "▱", AnnotationTool.Highlight, priority: 2),
            Tool("序号", "#", AnnotationTool.Number, priority: 2), Tool("多边形", "⬠", AnnotationTool.Polygon, priority: 2),
            Tool("聚光灯", "◐", AnnotationTool.Spotlight, priority: 2), Tool("橡皮擦", "◇", AnnotationTool.Eraser, false, 2),
            Tool("放大镜", "⌕", AnnotationTool.Magnifier, priority: 2)
        };
        var actions = new List<DockTool>
        {
            Tool("隐私打码", "shield", AnnotationTool.Privacy, priority: 2),
            Tool("裁剪", "⌗", AnnotationTool.Crop, priority: 3),
            new("贴图", "pin", () => Export(pin), Export: true, Priority: 3),
            new("复制", "▢", () => Export(copy), Export: true),
            new("保存", "↓", () => Export(save), Export: true),
            new("打印", "⎙", Print, Export: true, Priority: 3)
        };
        var overflow = new List<DockTool>();
        foreach (var (title, run) in outputs)
        {
            var action = new DockTool(title, title == "文字识别" ? "⌑" : title[..1], () => Export(run), Export: true, Priority: 4);
            if (title == "文字识别") actions.Add(action);
            else overflow.Add(action);
        }
        overflow.Add(new DockTool("长截图", "↕", () => SwitchCapture(startLongShot)));
        overflow.Add(new DockTool("录屏", "●", () => SwitchCapture(startRecording)));
        overflow.Add(Tool("水印", "水", AnnotationTool.Watermark));
        overflow.Add(Tool("路径标签", "⌁", AnnotationTool.PathTag));

        var visible = tools.Concat(actions).OrderBy(item => item.Priority).Take(Math.Max(0, slots - 5)).ToHashSet();
        var hidden = tools.Concat(actions).Where(item => !visible.Contains(item)).Concat(overflow).ToList();
        foreach (DockTool entry in tools.Where(visible.Contains)) AddButton(entry);
        AddDivider();
        undoButton = AddButton(new DockTool("撤销（Ctrl+Z）", "↶", () => TraverseHistory(undo, redo)));
        redoButton = AddButton(new DockTool("重做（Ctrl+Y）", "↷", () => TraverseHistory(redo, undo)));
        AddDivider();
        foreach (DockTool entry in actions.Where(visible.Contains)) AddButton(entry);
        Button more = NewIcon("更多工具与操作", "⌄");
        more.Click += (_, _) => ShowOverflow(more, hidden);
        toolbar.Children.Add(more);
        AddDivider();
        AddButton(new DockTool("关闭编辑器", "×", Close));
        Button confirm = AddButton(new DockTool(completionTitle, "✓", Confirm, Export: true));
        confirm.Margin = new Thickness(2, 0, 1, 0);
        confirm.Tag = true;
        UpdateButtons();
    }

    private DockTool Tool(string title, string symbol, AnnotationTool kind, bool options = true, int priority = 0) =>
        new(title, symbol, () => PickTool(kind), kind, options, Priority: priority);

    private void SwitchCapture(Action begin)
    {
        FinishText(save: true);
        begin();
    }

    private Button AddButton(DockTool tool)
    {
        Button button = NewIcon(tool.Title, tool.Symbol);
        button.Click += (_, _) => Activate(tool, button);
        toolbar.Children.Add(button);
        dockButtons.Add(button, tool);
        return button;
    }

    private Button NewIcon(string label, string symbol)
    {
        var control = new Button
        {
            Width = 28,
            Height = 28,
            Margin = new Thickness(0, 0, 1, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Content = ToolbarGlyph.Make(symbol),
            Cursor = Cursors.Hand,
            Focusable = false,
            ToolTip = new ToolTip
            {
                Content = label, Padding = new Thickness(9, 5, 9, 5), Background = palette.Panel,
                Foreground = palette.Foreground, BorderBrush = palette.Border, FontSize = 11,
                Placement = PlacementMode.Top, VerticalOffset = -4
            },
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new ScaleTransform(1, 1),
            Template = IconTemplate()
        };
        ToolTipService.SetInitialShowDelay(control, 300);
        ToolTipService.SetShowOnDisabled(control, true);
        control.ToolTipOpening += (_, e) => e.Handled = stylePopup?.IsOpen == true;
        if (SystemParameters.ClientAreaAnimation)
        {
            var scale = (ScaleTransform)control.RenderTransform;
            void Animate(double target)
            {
                var duration = TimeSpan.FromMilliseconds(115);
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(target, duration));
                scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(target, duration));
            }
            control.PreviewMouseLeftButtonDown += (_, _) => Animate(0.92);
            control.PreviewMouseLeftButtonUp += (_, _) => Animate(1);
            control.LostMouseCapture += (_, _) => Animate(1);
        }
        AutomationProperties.SetName(control, label);
        return control;
    }

    private ControlTemplate IconTemplate()
    {
        var border = new FrameworkElementFactory(typeof(Border)) { Name = "Pill" };
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        var outer = new FrameworkElementFactory(typeof(Grid));
        outer.AppendChild(border);
        var hoverFill = new FrameworkElementFactory(typeof(Border)) { Name = "Hover" };
        hoverFill.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        hoverFill.SetValue(Border.BackgroundProperty, palette.Muted);
        hoverFill.SetValue(OpacityProperty, 0d);
        outer.AppendChild(hoverFill);
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        outer.AppendChild(presenter);

        var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(OpacityProperty, 0.14, "Hover"));
        var press = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
        press.Setters.Add(new Setter(OpacityProperty, 0.73, "Pill"));
        var disabled = new Trigger { Property = IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(OpacityProperty, 0.32));
        var template = new ControlTemplate(typeof(Button)) { VisualTree = outer };
        template.Triggers.Add(hover);
        template.Triggers.Add(press);
        template.Triggers.Add(disabled);
        return template;
    }

    private void AddDivider() => toolbar.Children.Add(new Border
    {
        Height = 20,
        Width = 1,
        Margin = new Thickness(3, 0, 4, 0),
        VerticalAlignment = VerticalAlignment.Center,
        Background = palette.Border
    });

    private void UpdateButtons()
    {
        foreach (Button output in longShotOutputs) output.IsEnabled = !scanning;
        foreach (var (button, entry) in dockButtons)
        {
            bool highlighted = button.Tag is true || entry.Tool is AnnotationTool kind &&
                (selected >= 0 ? items[selected].Tool == kind : tool == kind);
            button.Background = highlighted ? palette.Primary : Brushes.Transparent;
            button.Foreground = highlighted ? palette.PrimaryForeground : palette.Foreground;
            button.IsEnabled = !entry.Export || !scanning;
        }
        if (undoButton is not null) undoButton.IsEnabled = undo.Count > 0;
        if (redoButton is not null) redoButton.IsEnabled = redo.Count > 0;
    }

    private void Activate(DockTool entry, FrameworkElement anchor)
    {
        bool close = stylePopup?.IsOpen == true && stylePopup.Tag is AnnotationTool shown && shown == entry.Tool;
        if (stylePopup is not null) stylePopup.IsOpen = false;
        if (entry.Export && scanning) return;
        entry.Run();
        if (entry.Tool == AnnotationTool.Crop && tool != AnnotationTool.Crop) return;
        if (entry.Options && entry.Tool is AnnotationTool kind && !close) ShowOptions(anchor, kind, entry.Title);
    }

    private void ShowOverflow(Button anchor, List<DockTool> contents)
    {
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Top,
            Foreground = palette.Foreground, Background = palette.Panel, BorderBrush = palette.Border };
        foreach (DockTool entry in contents)
        {
            var item = new MenuItem { Header = entry.Title, Icon = ToolbarGlyph.Make(entry.Symbol),
                IsEnabled = !entry.Export || !scanning };
            item.Click += (_, _) => _ = Dispatcher.BeginInvoke(() => Activate(entry, anchor), DispatcherPriority.Background);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    private void PickTool(AnnotationTool kind)
    {
        FinishText(save: true);
        CancelDrag();
        if (tool == AnnotationTool.Polygon && kind != tool) FinishPolygon();
        if (selected >= 0 && items[selected].Tool != kind) Select(-1);
        if (kind == AnnotationTool.Crop)
        {
            tool = tool == AnnotationTool.Crop ? null : AnnotationTool.Crop;
        }
        else tool = kind;
        RefreshSurface();
    }

    private AnnotationStyle StyleFor(AnnotationTool kind, int entry) =>
        entry >= 0 && entry < items.Count && items[entry].Tool == kind ? items[entry].Style : CurrentStyle(kind);

    private void SetStyle(AnnotationTool kind, int entry, Func<AnnotationStyle, AnnotationStyle> change, bool record = true)
    {
        AnnotationStyle previous = StyleFor(kind, entry);
        AnnotationStyle next = change(previous);
        if (previous == next) return;
        if (kind != AnnotationTool.Privacy || entry < 0) styles[kind] = next;
        if (kind == AnnotationTool.Privacy && entry < 0 && record) RememberPrivacyAppearance(next);
        if (entry >= 0 && entry < items.Count && items[entry].Tool == kind)
        {
            if (record) Remember();
            items[entry] = items[entry] with { Style = next };
        }
        RefreshSurface();
    }

    private void ShowOptions(FrameworkElement anchor, AnnotationTool kind, string title)
    {
        int target = selected >= 0 && items[selected].Tool == kind ? selected : -1;
        AnnotationStyle style = StyleFor(kind, target);
        var stack = new StackPanel { Margin = new Thickness(13), Width = kind is AnnotationTool.Privacy or AnnotationTool.Mosaic ? 302 : 294 };
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 7) };
        if (kind == AnnotationTool.Privacy && openRules is not null)
        {
            var rules = OptionAction("规则与模型", openRules, closePopup: true);
            DockPanel.SetDock(rules, Dock.Right);
            header.Children.Add(rules);
        }
        header.Children.Add(new TextBlock { Text = kind == AnnotationTool.Privacy ? title : $"{title}样式",
            FontSize = 13, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center, Foreground = palette.Foreground });
        stack.Children.Add(header);
        if (kind == AnnotationTool.Privacy)
            stack.Children.Add(new TextBlock { Text = "拖动打码。点已有打码块可移动、缩放或删除。",
                Foreground = palette.Muted, FontSize = 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 7) });
        var box = new Border
        {
            Background = palette.Panel, BorderBrush = palette.Border, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(11), Child = stack,
            Margin = new Thickness(8), Effect = new DropShadowEffect { BlurRadius = 14, ShadowDepth = 2, Opacity = 0.22 }
        };
        stylePopup = new Popup
        {
            PlacementTarget = anchor,
            Placement = PlacementMode.Top,
            VerticalOffset = -8,
            StaysOpen = false,
            AllowsTransparency = true,
            PopupAnimation = SystemParameters.ClientAreaAnimation ? PopupAnimation.Fade : PopupAnimation.None,
            Child = box,
            Tag = kind
        };
        if (kind == AnnotationTool.Crop)
        {
            stack.Children.Add(Segments(new[] { (0d, "自由"), (1d, "1:1"), (4d / 3, "4:3"), (16d / 9, "16:9"), (9d / 16, "9:16") },
                cropRatio, value =>
                {
                    cropRatio = value;
                    if (value > 0)
                    {
                        Remember();
                        crop = FitCrop(crop ?? canvas.ImageRect, 0, 0);
                        RefreshSurface();
                    }
                    stylePopup.IsOpen = false;
                }));
            stylePopup.IsOpen = true;
            return;
        }

        void Range(string title, double low, double high, double value, Func<AnnotationStyle, double, AnnotationStyle> change, double step = 1)
        {
            var text = new TextBlock { Text = title, Width = 69, VerticalAlignment = VerticalAlignment.Center, Foreground = palette.Foreground };
            var number = new TextBlock { Text = value.ToString("0.##"), Width = 35, HorizontalAlignment = HorizontalAlignment.Right, TextAlignment = TextAlignment.Right, Foreground = palette.Muted };
            var slider = new Slider { Minimum = low, Maximum = high, Value = value, TickFrequency = step, IsSnapToTickEnabled = true,
                Margin = new Thickness(0, 2, 8, 2) };
            bool dragging = false;
            DocumentState? before = null;
            slider.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) =>
            {
                dragging = true;
                if (target >= 0) before = Snapshot();
            }));
            slider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) =>
            {
                if (before is not null && !before.Items.SequenceEqual(items)) Remember(before);
                before = null;
                dragging = false;
                UpdateButtons();
            }));
            slider.ValueChanged += (_, args) =>
            {
                SetStyle(kind, target, last => change(last, args.NewValue), !dragging);
                number.Text = args.NewValue.ToString("0.##");
            };
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            DockPanel.SetDock(number, Dock.Right);
            row.Children.Add(number);
            row.Children.Add(text);
            row.Children.Add(slider);
            stack.Children.Add(row);
        }

        var colorOptions = new StackPanel();
        bool editsSecondColor = false;

        void Choice<T>(string name, T value, (T Value, string Label)[] entries,
            Func<AnnotationStyle, T, AnnotationStyle> change, bool segmented = false)
        {
            if (segmented)
            {
                stack.Children.Add(Labeled(name, Segments(entries, value, picked =>
                {
                    SetStyle(kind, target, last => change(last, picked));
                    if (name is "形状" or "背景") BuildColors();
                })));
                return;
            }
            int current = Array.FindIndex(entries, item => EqualityComparer<T>.Default.Equals(item.Value, value));
            var combo = new ComboBox { ItemsSource = entries.Select(item => item.Label), SelectedIndex = current,
                MaxHeight = 26, MaxDropDownHeight = 250 };
            combo.SelectionChanged += (_, _) =>
            {
                if (combo.SelectedIndex >= 0) SetStyle(kind, target, last => change(last, entries[combo.SelectedIndex].Value));
            };
            stack.Children.Add(Labeled(name, combo));
        }

        void Flag(string label, bool value, Func<AnnotationStyle, bool, AnnotationStyle> change)
        {
            var check = new CheckBox { Content = label, IsChecked = value, Margin = new Thickness(0, 4, 12, 4), Foreground = palette.Foreground };
            check.Click += (_, _) => SetStyle(kind, target, last => change(last, check.IsChecked == true));
            stack.Children.Add(check);
        }

        if (kind is AnnotationTool.Arrow or AnnotationTool.Rectangle or AnnotationTool.Ellipse or AnnotationTool.Line or
            AnnotationTool.Pen or AnnotationTool.Highlight or AnnotationTool.Polygon or AnnotationTool.Magnifier or AnnotationTool.PathTag)
        {
            Range("线宽", 1, 20, style.LineWidth, (last, value) => last with { LineWidth = value });
            if (kind != AnnotationTool.Highlight)
                Choice("线型", style.Pattern, new[] { (StrokePattern.Solid, "实线"), (StrokePattern.Dash, "虚线"),
                    (StrokePattern.Dot, "点线") }, (last, value) => last with { Pattern = value }, segmented: true);
        }
        if (kind is AnnotationTool.Rectangle or AnnotationTool.Ellipse or AnnotationTool.Polygon)
            Choice("形状", style.Fill, new[] { (ShapeFill.Outline, "描边"), (ShapeFill.Fill, "填充"),
                (ShapeFill.Both, "描边＋填充") }, (last, value) => last with { Fill = value }, segmented: true);
        if (kind == AnnotationTool.Rectangle)
            Range("圆角", 0, 40, style.CornerRadius, (last, value) => last with { CornerRadius = value });
        if (kind == AnnotationTool.Arrow)
            Choice("箭头", style.Arrow, new[] { (ArrowHead.Solid, "实心"), (ArrowHead.Hollow, "空心"),
                (ArrowHead.Open, "线条") }, (last, value) => last with { Arrow = value }, segmented: true);
        if (kind is AnnotationTool.Text or AnnotationTool.Watermark or AnnotationTool.Number)
        {
            Range("字号", 8, 96, style.FontSize, (last, value) => last with { FontSize = value });
            Choice("字体", style.FontFamily, InstalledFonts, (last, value) => last with { FontFamily = value });
            if (kind == AnnotationTool.Text)
            {
                var formats = new UniformGrid { Rows = 1, Columns = 4 };
                void Format(string name, string mark, bool current, Func<AnnotationStyle, bool, AnnotationStyle> change)
                {
                    var button = OptionAction(mark);
                    button.FontSize = 12;
                    button.ToolTip = name;
                    AutomationProperties.SetName(button, name);
                    void StyleButton()
                    {
                        button.Background = current ? palette.Primary : palette.Hover;
                        button.Foreground = current ? palette.PrimaryForeground : palette.Foreground;
                    }
                    button.Click += (_, _) => { current = !current; SetStyle(kind, target, last => change(last, current)); StyleButton(); };
                    StyleButton();
                    formats.Children.Add(button);
                }
                Format("加粗", "B", style.Bold, (last, value) => last with { Bold = value });
                Format("斜体", "𝑰", style.Italic, (last, value) => last with { Italic = value });
                Format("下划线", "U̲", style.Underline, (last, value) => last with { Underline = value });
                Format("删除线", "S̶", style.Strikethrough, (last, value) => last with { Strikethrough = value });
                stack.Children.Add(Labeled("样式", formats));
                Choice("对齐", style.Alignment, new[] { (TextAlignment.Left, "左"), (TextAlignment.Center, "居中"),
                    (TextAlignment.Right, "右") }, (last, value) => last with { Alignment = value }, segmented: true);
                Choice("背景", style.TextBackground is null ? 0 : style.RoundedBackground ? 2 : 1,
                    new[] { (0, "无"), (1, "矩形"), (2, "圆角") }, (last, value) => last with
                    {
                        TextBackground = value == 0 ? null : last.TextBackground ?? Color.FromArgb(184, 255, 255, 255),
                        RoundedBackground = value == 2
                    }, segmented: true);
            }
            else
            {
                Flag("加粗", style.Bold, (last, value) => last with { Bold = value });
                Flag("斜体", style.Italic, (last, value) => last with { Italic = value });
            }
        }
        if (kind == AnnotationTool.Number)
        {
            Choice("序号格式", style.Number, new[] { (NumberStyle.Arabic, "1, 2, 3"), (NumberStyle.Circled, "①, ②, ③"),
                (NumberStyle.Lowercase, "a, b, c"), (NumberStyle.Uppercase, "A, B, C") }, (last, value) => last with { Number = value });
            Flag("空心徽标", style.NumberOutlined, (last, value) => last with { NumberOutlined = value });
        }
        if (kind == AnnotationTool.Watermark)
        {
            Choice("水印内容", style.Watermark, new[] { (WatermarkContent.Text, "文字"), (WatermarkContent.DateTime, "日期和时间"),
                (WatermarkContent.Date, "仅日期"), (WatermarkContent.Image, "图片") }, (last, value) => last with { Watermark = value });
            stack.Children.Add(OptionAction("选择 PNG 图片…", () =>
            {
                if (Images.OpenImage(pngOnly: true) is { } logo)
                    SetStyle(kind, target, last => last with { Watermark = WatermarkContent.Image, Logo = logo });
            }, closePopup: true));
            Range("角度", -90, 90, style.Angle, (last, value) => last with { Angle = value }, step: 5);
            Flag("平铺", style.Tiled, (last, value) => last with { Tiled = value });
        }
        if (kind == AnnotationTool.Magnifier)
            Choice("倍率", style.Zoom, new[] { (1.5, "1.5×"), (2d, "2×"), (3d, "3×"), (4d, "4×"), (6d, "6×") },
                (last, value) => last with { Zoom = value });
        if (kind is AnnotationTool.Privacy or AnnotationTool.Mosaic)
        {
            AddMaskStyles(stack, kind, target, style);
            stylePopup.Closed += (_, _) =>
            {
                if (kind == AnnotationTool.Privacy && target < 0 && CurrentStyle(kind) != privacyAppearance)
                    RememberPrivacyAppearance(CurrentStyle(kind));
            };
        }
        if (kind == AnnotationTool.Mosaic && detectMosaic is not null)
        {
            Flag("自动识别人脸", style.DetectFaces, (last, value) => last with { DetectFaces = value });
            Flag("自动识别文字", style.DetectText, (last, value) => last with { DetectText = value });
        }
        if (kind == AnnotationTool.Privacy)
        {
            stack.Children.Add(new Border { Background = palette.Border, Height = 1, Margin = new Thickness(0, 7, 0, 6) });
            var controls = new WrapPanel();
            var scan = OptionAction("扫描图片", () => scanPrivacy(source), closePopup: true);
            scan.IsEnabled = !scanning;
            scan.Background = new SolidColorBrush(Color.FromRgb(0, 110, 238));
            scan.Foreground = Brushes.White;
            controls.Children.Add(scan);
            if (scanCroppedText is not null || scanText is not null || scanCroppedImage is not null || scanImage is not null)
            {
                bool configured = isAiConfigured?.Invoke() != false;
                var ai = OptionAction(configured ? "AI 补查 ⌄" : "AI 补查");
                ai.IsEnabled = !scanning;
                var choices = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 0),
                    Visibility = Visibility.Collapsed };
                if (scanCroppedImage is not null)
                    choices.Children.Add(OptionAction("图片定位", () => Export(image => scanCroppedImage(image, PixelCrop), forReview: true), closePopup: true));
                else if (scanImage is not null)
                    choices.Children.Add(OptionAction("图片定位", () => Export(scanImage, includeCrop: false, forReview: true), closePopup: true));
                if (scanCroppedText is not null)
                    choices.Children.Add(OptionAction("仅文字", () => Export(image => scanCroppedText(image, PixelCrop), forReview: true), closePopup: true));
                else if (scanText is not null)
                    choices.Children.Add(OptionAction("仅文字", () => Export(scanText, includeCrop: false, forReview: true), closePopup: true));
                ai.Click += (_, _) =>
                {
                    if (!configured)
                    {
                        if (stylePopup is not null) stylePopup.IsOpen = false;
                        openRules?.Invoke();
                        return;
                    }
                    choices.Visibility = choices.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
                };
                controls.Children.Add(ai);
                stack.Children.Add(controls);
                stack.Children.Add(choices);
            }
            else stack.Children.Add(controls);
        }
        if (kind is not (AnnotationTool.Privacy or AnnotationTool.Mosaic or AnnotationTool.Spotlight or AnnotationTool.Magnifier))
        {
            BuildColors();
            stack.Children.Add(colorOptions);
        }
        if (kind is not (AnnotationTool.Privacy or AnnotationTool.Mosaic or AnnotationTool.Magnifier))
            Range("整体不透明度", 0.1, 1, style.Opacity, (last, value) => last with { Opacity = value }, step: 0.05);

        stylePopup.IsOpen = true;

        void BuildColors()
        {
            colorOptions.Children.Clear();
            var current = StyleFor(kind, target);
            bool text = kind == AnnotationTool.Text, shape = kind is AnnotationTool.Rectangle or AnnotationTool.Ellipse or AnnotationTool.Polygon;
            bool both = (text && current.TextBackground.HasValue) || (shape && current.Fill == ShapeFill.Both);
            bool secondary = (shape && current.Fill == ShapeFill.Fill) || (both && editsSecondColor);
            if (both)
            {
                colorOptions.Children.Add(Segments(new[] { (false, text ? "文字" : "描边"),
                    (true, text ? "背景" : "填充") }, editsSecondColor, value =>
                {
                    editsSecondColor = value;
                    BuildColors();
                }));
            }
            Color color = !secondary ? current.Color : text ? current.TextBackground ?? current.Color :
                current.FillColor ?? (current.Fill == ShapeFill.Both ? Color.FromArgb((byte)(current.Color.A / 4), current.Color.R,
                    current.Color.G, current.Color.B) : current.Color);
            AddColors(colorOptions, color, (picked, record) => SetStyle(kind, target, last => !secondary
                ? last with { Color = picked }
                : text ? last with { TextBackground = picked } : last with { FillColor = picked }, record),
                target, preserveFavoriteOpacity: secondary);
        }
    }

    private FrameworkElement Segments<T>((T Value, string Label)[] entries, T selected, Action<T> pick)
    {
        var rail = new UniformGrid { Rows = 1, Columns = entries.Length, Margin = new Thickness(0, 2, 0, 3) };
        var values = new List<(Button Button, T Value)>();
        foreach (var (value, label) in entries)
        {
            var button = OptionAction(label);
            button.Margin = new Thickness(1);
            button.Click += (_, _) => { selected = value; pick(value); RefreshSelection(); };
            rail.Children.Add(button);
            values.Add((button, value));
        }
        RefreshSelection();
        return rail;

        void RefreshSelection()
        {
            foreach (var (button, value) in values)
            {
                bool active = EqualityComparer<T>.Default.Equals(selected, value);
                button.Background = active ? palette.Primary : palette.Hover;
                button.Foreground = active ? palette.PrimaryForeground : palette.Foreground;
            }
        }
    }

    private Button OptionAction(string title, Action? run = null, bool closePopup = false)
    {
        var button = new Button { Content = title, Margin = new Thickness(0, 2, 6, 2), Padding = new Thickness(8, 3, 8, 3),
            Foreground = palette.Foreground, Background = palette.Hover, BorderBrush = palette.Border, Cursor = Cursors.Hand };
        button.Click += (_, _) =>
        {
            if (closePopup && stylePopup is not null) stylePopup.IsOpen = false;
            run?.Invoke();
        };
        return button;
    }


    private FrameworkElement Labeled(string label, FrameworkElement control)
    {
        var result = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
        var text = new TextBlock { Text = label, Width = 69, VerticalAlignment = VerticalAlignment.Center, Foreground = palette.Foreground };
        result.Children.Add(text);
        result.Children.Add(control);
        AutomationProperties.SetName(control, label);
        return result;
    }

    private void AddColors(Panel container, Color current, Action<Color, bool> set, int target,
        bool preserveFavoriteOpacity, bool supportsOpacity = true, bool showFavorites = true)
    {
        var swatches = new List<(Button Button, Color Color)>();
        if (showFavorites)
        {
            var row = new WrapPanel { Margin = new Thickness(0, 3, 0, 5) };
            foreach (Color color in new[] { Color.FromRgb(255, 59, 48), Color.FromRgb(255, 149, 0),
                         Color.FromRgb(255, 204, 0), Color.FromRgb(52, 199, 89), Color.FromRgb(0, 122, 255),
                         Color.FromRgb(175, 82, 222), Colors.Black, Colors.White })
            {
                var button = NewIcon($"颜色 {Hex(color)}", "");
                button.Width = 27;
                button.Height = 28;
                button.Content = new Ellipse { Fill = AnnotationDrawing.Brush(color), Width = 19, Height = 19,
                    Stroke = palette.Border, StrokeThickness = 1 };
                swatches.Add((button, color));
                row.Children.Add(button);
            }
            container.Children.Add(row);
        }

        var panel = new StackPanel { Margin = new Thickness(9, 6, 9, 6) };
        container.Children.Add(new Border { Background = palette.Panel, BorderBrush = palette.Border,
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Child = panel });
        var valueLine = new StackPanel { Orientation = Orientation.Horizontal };
        var preview = new Border { Width = 30, Height = 26, CornerRadius = new CornerRadius(5),
            BorderThickness = new Thickness(1), BorderBrush = palette.Border, Margin = new Thickness(0, 0, 8, 0) };
        valueLine.Children.Add(preview);
        var hex = new TextBox { Width = 94, FontFamily = new FontFamily("Consolas"), Padding = new Thickness(6, 3, 6, 3),
            Foreground = palette.Foreground, Background = palette.Hover, BorderBrush = palette.Border };
        AutomationProperties.SetName(hex, "十六进制颜色");
        valueLine.Children.Add(hex);
        panel.Children.Add(valueLine);

        var spectrum = new LinearGradientBrush { StartPoint = new Point(0, 0.5), EndPoint = new Point(1, 0.5) };
        for (int angle = 0; angle <= 360; angle += 30)
            spectrum.GradientStops.Add(new GradientStop(HueColor(angle, byte.MaxValue), angle / 360d));
        var hue = new Border { Background = spectrum, Height = 10, Margin = new Thickness(0, 9, 0, 8),
            CornerRadius = new CornerRadius(5), Focusable = true, Cursor = Cursors.Hand, ToolTip = "色相" };
        AutomationProperties.SetName(hue, "色相");
        panel.Children.Add(hue);

        bool changing = false;
        DocumentState? gestureStart = null;
        var alpha = new Slider { Minimum = 0, Maximum = 1, TickFrequency = 0.01, Value = current.A / 255d,
            Margin = new Thickness(8, 0, 0, 0), IsMoveToPointEnabled = true, ToolTip = "颜色不透明度" };
        AutomationProperties.SetName(alpha, "颜色不透明度");
        if (supportsOpacity)
        {
            var alphaRow = new DockPanel { Margin = new Thickness(0, 1, 0, 0) };
            alphaRow.Children.Add(new TextBlock { Text = "颜色不透明度", Foreground = palette.Muted,
                VerticalAlignment = VerticalAlignment.Center, FontSize = 11 });
            alphaRow.Children.Add(alpha);
            panel.Children.Add(alphaRow);
        }
        void BeginGesture()
        {
            if (!changing && target >= 0) gestureStart = Snapshot();
            changing = true;
        }
        void EndGesture()
        {
            if (gestureStart is not null && !gestureStart.Items.SequenceEqual(items)) Remember(gestureStart);
            gestureStart = null;
            changing = false;
            UpdateButtons();
        }
        void ReadColor()
        {
            string color = hex.Text.Trim().TrimStart('#');
            if (color.Length == 3)
                color = string.Concat(color.SelectMany(c => new[] { c, c }));
            if ((color.Length == 6 || supportsOpacity && color.Length == 8) &&
                uint.TryParse(color, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out uint rgba))
            {
                byte a = color.Length == 8 ? (byte)rgba : supportsOpacity ? current.A : byte.MaxValue;
                if (color.Length == 8) rgba >>= 8;
                Apply(Color.FromArgb(a, (byte)(rgba >> 16), (byte)(rgba >> 8), (byte)rgba), record: true);
            }
            else hex.Text = Hex(current);
        }
        hex.KeyDown += (_, args) =>
        {
            if (args.Key != Key.Enter) return;
            ReadColor();
            args.Handled = true;
        };
        hex.LostKeyboardFocus += (_, _) => ReadColor();
        hue.MouseLeftButtonDown += (_, e) =>
        {
            hue.Focus();
            hue.CaptureMouse();
            BeginGesture();
            SetHue(e.GetPosition(hue).X);
        };
        hue.MouseMove += (_, e) =>
        {
            if (hue.IsMouseCaptured && e.LeftButton == MouseButtonState.Pressed) SetHue(e.GetPosition(hue).X);
        };
        hue.MouseLeftButtonUp += (_, _) => hue.ReleaseMouseCapture();
        hue.LostMouseCapture += (_, _) => { if (changing) EndGesture(); };
        hue.KeyDown += (_, e) =>
        {
            if (e.Key is not (Key.Left or Key.Right or Key.Up or Key.Down)) return;
            var color = System.Drawing.Color.FromArgb(current.R, current.G, current.B);
            double angle = color.GetHue() + (e.Key is Key.Right or Key.Up ? 3 : -3);
            Apply(HueColor(Math.Clamp(angle, 0, 360), current.A), record: true);
            e.Handled = true;
        };
        foreach (var (button, color) in swatches)
            button.Click += (_, _) => Apply(preserveFavoriteOpacity ?
                Color.FromArgb(current.A, color.R, color.G, color.B) : color, record: true);
        alpha.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => BeginGesture()));
        alpha.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) => EndGesture()));
        alpha.ValueChanged += (_, args) =>
        {
            byte channel = (byte)Math.Round(args.NewValue * 255);
            if (channel != current.A)
                Apply(Color.FromArgb(channel, current.R, current.G, current.B), record: !changing);
        };
        UpdateVisual();

        void SetHue(double x) => Apply(HueColor(Math.Clamp(x / Math.Max(1, hue.ActualWidth), 0, 1) * 360, current.A), record: false);
        static string Hex(Color color) => color.A == byte.MaxValue ? $"#{color.R:X2}{color.G:X2}{color.B:X2}" :
            $"#{color.R:X2}{color.G:X2}{color.B:X2}{color.A:X2}";
        void Apply(Color color, bool record)
        {
            if (color != current)
            {
                current = color;
                set(color, record);
            }
            UpdateVisual();
        }
        void UpdateVisual()
        {
            hex.Text = Hex(current);
            preview.Background = AnnotationDrawing.Brush(current);
            alpha.Value = current.A / 255d;
            foreach (var (button, color) in swatches)
                button.Background = color.R == current.R && color.G == current.G && color.B == current.B
                    ? palette.Hover : Brushes.Transparent;
        }
    }

    private static Color HueColor(double angle, byte opacity)
    {
        double segment = angle % 360 / 60;
        const double brightness = 0.95, saturation = 0.85;
        double chroma = brightness * saturation;
        double x = chroma * (1 - Math.Abs(segment % 2 - 1));
        var (r, g, b) = (int)segment switch
        {
            0 => (chroma, x, 0d), 1 => (x, chroma, 0d), 2 => (0d, chroma, x),
            3 => (0d, x, chroma), 4 => (x, 0d, chroma), _ => (chroma, 0d, x)
        };
        double offset = brightness - chroma;
        byte Channel(double value) => (byte)Math.Round((value + offset) * 255);
        return Color.FromArgb(opacity, Channel(r), Channel(g), Channel(b));
    }

    private void AddMaskStyles(Panel container, AnnotationTool kind, int target, AnnotationStyle style)
    {
        var tiles = new UniformGrid { Columns = 3, Margin = new Thickness(0, 1, 0, 4) };
        List<(MaskStyle? Mask, bool Blur, string Label)> options =
        [
            (MaskStyle.Frosted, false, "羽化柔焦"), (MaskStyle.Erase, false, "同色擦除"),
            (MaskStyle.Mosaic, false, "低对比马赛克"), (MaskStyle.Graphite, false, "石墨"),
            (MaskStyle.Mist, false, "雾白"), (MaskStyle.Stripes, false, "斜纹"), (MaskStyle.Solid, false, "自选色")
        ];
        if (kind == AnnotationTool.Mosaic)
        {
            options.Insert(0, (null, true, "模糊"));
            options.Insert(0, (null, false, "马赛克"));
        }
        var buttons = new List<(Button Button, Image Preview, MaskStyle? Mask, bool Blur)>();
        var config = new StackPanel();
        foreach (var (mask, blur, label) in options)
        {
            var layout = new StackPanel { Margin = new Thickness(3) };
            var image = new Image { Width = 90, Height = 56, Stretch = Stretch.Fill };
            image.Clip = new RectangleGeometry(new Rect(0, 0, 90, 56), 5, 5);
            layout.Children.Add(image);
            layout.Children.Add(new TextBlock { Text = label, Foreground = palette.Foreground,
                HorizontalAlignment = HorizontalAlignment.Center, FontSize = 11, Margin = new Thickness(0, 3, 0, 0) });
            var button = new Button { Content = layout, Margin = new Thickness(1), ToolTip = label, Cursor = Cursors.Hand,
                BorderThickness = new Thickness(0), Padding = new Thickness(0), Template = IconTemplate() };
            AutomationProperties.SetName(button, label);
            button.Click += (_, _) =>
            {
                SetStyle(kind, target, last =>
                {
                    if (kind != AnnotationTool.Mosaic) return last with { Mask = mask, MosaicBlur = blur };
                    if (mask is null)
                        return last with { Mask = null, MosaicBlur = blur,
                            BlockSize = last.Mask is null ? last.BlockSize : defaults.BlockSize };
                    if (last.Mask is not null) return last with { Mask = mask, MosaicBlur = false };
                    return last with { Mask = mask, MosaicBlur = false, BlockSize = privacyAppearance.BlockSize,
                        Color = privacyAppearance.Color };
                });
                RefreshSelection();
            };
            tiles.Children.Add(button);
            buttons.Add((button, image, mask, blur));
        }
        container.Children.Add(tiles);
        container.Children.Add(config);

        void DrawSamples()
        {
            AnnotationStyle value = StyleFor(kind, target);
            foreach (var (button, image, mask, blur) in buttons)
            {
                button.Background = value.Mask == mask && value.MosaicBlur == blur
                    ? AnnotationDrawing.Brush(Color.FromRgb(0, 122, 255), 0.18) : Brushes.Transparent;
                image.Source = RedactionStylePreview.Render(value with { Mask = mask, MosaicBlur = blur });
            }
        }

        void RefreshSelection()
        {
            DrawSamples();
            config.Children.Clear();
            AnnotationStyle value = StyleFor(kind, target);
            if (value.Mask == MaskStyle.Solid)
            {
                AddColors(config, Color.FromRgb(value.Color.R, value.Color.G, value.Color.B), (color, record) =>
                {
                    SetStyle(kind, target, last => last with { Color = color }, record);
                    DrawSamples();
                }, target, preserveFavoriteOpacity: false, supportsOpacity: false, showFavorites: false);
            }
            else if (value.Mask is null or MaskStyle.Mosaic or MaskStyle.Stripes)
            {
                bool classic = value.Mask is null;
                string title = value.Mask switch { MaskStyle.Mosaic => "色块大小", MaskStyle.Stripes => "斜纹间距", _ => "强度" };
                var slider = new Slider { Minimum = classic ? 2 : 3, Maximum = classic ? 64 : 24,
                    TickFrequency = classic ? 2 : 1, IsSnapToTickEnabled = true, Value = value.BlockSize };
                bool dragging = false;
                DocumentState? before = null;
                slider.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) =>
                { dragging = true; if (target >= 0) before = Snapshot(); }));
                slider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) =>
                {
                    if (before is not null && !before.Items.SequenceEqual(items)) Remember(before);
                    if (kind == AnnotationTool.Privacy && target < 0 && CurrentStyle(kind) != privacyAppearance)
                        RememberPrivacyAppearance(CurrentStyle(kind));
                    dragging = false;
                    before = null;
                    UpdateButtons();
                }));
                var number = new TextBlock { Text = slider.Value.ToString("0"), Foreground = palette.Muted,
                    MinWidth = 23, VerticalAlignment = VerticalAlignment.Center, TextAlignment = TextAlignment.Right };
                var control = new DockPanel();
                DockPanel.SetDock(number, Dock.Right);
                control.Children.Add(number);
                control.Children.Add(slider);
                slider.ValueChanged += (_, e) =>
                {
                    number.Text = e.NewValue.ToString("0");
                    SetStyle(kind, target, last => last with { BlockSize = (int)e.NewValue }, !dragging);
                    DrawSamples();
                };
                config.Children.Add(Labeled(title, control));
            }
        }

        RefreshSelection();
    }
}

using System.Windows.Media.Animation;
using System.Windows.Input;
using System.Windows.Controls.Primitives;
using System.Windows.Automation;
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Shapes;

namespace TapSnap.Windows;

internal static class ToolbarGlyph
{
    public static FrameworkElement Make(string symbol, double size = 15)
    {
        string outline = symbol switch
        {
            "↗" => "M3,13 L13,3 M5,3 H13 V11",
            "□" => "M2,4 H14 V12 H2 Z",
            "○" => "M14,8 A6,6 0 1 1 2,8 A6,6 0 1 1 14,8Z",
            "╱" => "M2,14 L14,2",
            "✎" => "M8,2 L12,8 L10,13 H6 L4,8 Z M8,2 V7 M8,7 A1,1 0 1 1 8,9 A1,1 0 0 1 8,7",
            "T" => "M3,2 H13 Q14,2 14,3 V13 Q14,14 13,14 H3 Q2,14 2,13 V3 Q2,2 3,2Z M5,5 H11 M8,5 V11",
            "▦" => "M2,2 H4 V4 H2Z M7,2 H9 V4 H7Z M12,2 H14 V4 H12Z M2,7 H4 V9 H2Z M7,7 H9 V9 H7Z M12,7 H14 V9 H12Z M2,12 H4 V14 H2Z M7,12 H9 V14 H7Z M12,12 H14 V14 H12Z",
            "▱" => "M3,11 L9,3 Q10,2 11,3 L13,4 Q14,5 13,6 L7,13 H3Z M5,9 L8,11 M1,15 H14",
            "#" => "M6,2 L4,14 M12,2 L10,14 M3,6 H14 M2,10 H13",
            "⬠" => "M8,2 L14,7 L12,14 H4 L2,7 Z",
            "◐" => "M14,8 A6,6 0 1 1 2,8 A6,6 0 1 1 14,8Z",
            "◇" => "M2,10 L9,3 Q10,2 11,3 L14,6 Q15,7 14,8 L8,14 H6Z M5,7 L11,11 M8,14 H14",
            "⌕" => "M11,7 A4.5,4.5 0 1 1 2,7 A4.5,4.5 0 1 1 11,7Z M10,10 L14,14",
            "shield" => "M8,1 L14,3 V8 Q14,12 8,15 Q2,12 2,8 V3Z M6,7 V6 A2,2 0 0 1 10,6 V7 M5,7 H11 V11 H5 Z",
            "⌗" => "M5,2 V11 H14 M2,5 H11 V14",
            "pin" => "M5,2 H11 M6,2 V7 L4,10 H12 L10,7 V2 M8,10 V15",
            "▢" => "M6,5 H14 V14 H6Z M10,5 V2 H2 V11 H6",
            "↓" => "M3,8 V14 H13 V8 M8,2 V10 M5,7 L8,10 L11,7",
            "⎙" => "M5,6 V2 H11 V6 M4,12 H2 V6 H14 V12 H12 M5,9 H11 V15 H5Z M11,8 H12",
            "⌑" => "M5,2 H2 V5 M11,2 H14 V5 M2,11 V14 H5 M14,11 V14 H11 M5,6 H11 M5,8 H11 M5,10 H9",
            "↕" => "M8,2 V14 M4,6 L8,2 L12,6 M4,10 L8,14 L12,10",
            "●" => "M14,8 A6,6 0 1 1 2,8 A6,6 0 1 1 14,8Z M10,8 A2,2 0 1 1 6,8 A2,2 0 1 1 10,8Z",
            "水" => "M8,2 Q13,8 13,10 A5,5 0 1 1 3,10 Q3,8 8,2Z",
            "⌁" => "M2,3 H8 L14,9 L9,14 L2,7Z M5,5 H6",
            "↶" => "M6,3 L2,7 L6,11 M2,7 H9 Q14,7 14,13",
            "↷" => "M10,3 L14,7 L10,11 M14,7 H7 Q2,7 2,13",
            "⌄" => "M4,6 L8,10 L12,6",
            "×" => "M3,3 L13,13 M3,13 L13,3",
            "✓" => "M2,8 L6,12 L14,4",
            "delete" => "M3,4 H13 M6,4 V2 H10 V4 M4,4 L5,14 H11 L12,4 M7,7 V11 M9,7 V11",
            "clipboard" => "M5,3 H3 V14 H13 V3 H11 M5,2 H11 V5 H5Z M6,8 H10 M6,11 H10",
            "image" => "M2,3 H14 V13 H2Z M2,11 L6,7 L9,10 L11,8 L14,11 M11,5 H12",
            "lock" => "M5,7 V5 A3,3 0 1 1 11,5 V7 M3,7 H13 V14 H3Z M8,10 V11",
            "text" => "M2,3 H14 M2,6 H10 M2,9 H14 M2,12 H8",
            "info" => "M14,8 A6,6 0 1 1 2,8 A6,6 0 1 1 14,8Z M8,7 V11 M8,5 V5.1",
            "settings" => "M6,2 H10 L10.5,4 L12,5 L14,4.5 L15.5,7 L14,8.5 V9.5 L15,11 L13.5,13 L11.5,12.5 L10,13.5 L9.5,15 H6.5 L6,13.5 L4.5,12.5 L2.5,13 L1,11 L2,9.5 V8.5 L0.5,7 L2,4.5 L4,5 L5.5,4 Z M10,8.5 A2,2 0 1 1 6,8.5 A2,2 0 1 1 10,8.5Z",
            "keyboard" => "M2,4 H14 Q15,4 15,5 V11 Q15,12 14,12 H2 Q1,12 1,11 V5 Q1,4 2,4Z M4,6.5 H4.1 M7,6.5 H7.1 M10,6.5 H10.1 M12,6.5 H12.1 M4,9.5 H4.1 M6,9.5 H11",
            "edit" => "M3,3 H8 M3,3 V13 H13 V8 M6,10 L7,7 L12,2 L14,4 L9,9Z",
            "frame" => "M2,6 V2 H6 M10,2 H14 V6 M14,10 V14 H10 M6,14 H2 V10",
            "grip" => "M6,3 H6.1 M10,3 H10.1 M6,8 H6.1 M10,8 H10.1 M6,13 H6.1 M10,13 H10.1",
            "pause" => "M6,3 V13 M10,3 V13",
            "previous-frame" => "M3,3 V13 M13,3 L6,8 L13,13 Z",
            "next-frame" => "M13,3 V13 M3,3 L10,8 L3,13 Z",
            "play" => "M5,2 L13,8 L5,14 Z",
            _ => string.Empty
        };
        if (outline.Length == 0)
            return new TextBlock { Text = symbol, HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center, FontSize = size - 1 };
        var path = new Path
        {
            Data = Geometry.Parse(outline), StrokeThickness = 1.35, StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round, IsHitTestVisible = false
        };
        path.SetBinding(Shape.StrokeProperty, new Binding("Foreground") { RelativeSource = new RelativeSource(
            RelativeSourceMode.FindAncestor, typeof(Control), 1) });
        if (symbol == "▦") path.SetBinding(Shape.FillProperty, new Binding("Stroke") { Source = path });
        var viewport = new Canvas { Width = 16, Height = 16, IsHitTestVisible = false };
        if (symbol is "◐" or "●")
        {
            var fill = new Path { Data = Geometry.Parse(symbol == "◐" ? "M8,2 A6,6 0 0 0 8,14 Z" :
                "M10,8 A2,2 0 1 1 6,8 A2,2 0 1 1 10,8 Z") };
            fill.SetBinding(Shape.FillProperty, new Binding("Stroke") { Source = path });
            viewport.Children.Add(fill);
        }
        viewport.Children.Add(path);
        return new Viewbox { Width = size, Height = size, Stretch = Stretch.Uniform, Child = viewport };
    }

    internal static Button CreateButton(string label, string symbol, SnapPalette palette, string? shortcut = null)
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
                Content = shortcut is null ? label : $"{label} {shortcut}",
                Padding = new Thickness(9, 5, 9, 5), Background = palette.Panel,
                Foreground = palette.Foreground, BorderBrush = palette.Border, FontSize = 11,
                Placement = PlacementMode.Top, VerticalOffset = -4
            },
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new ScaleTransform(1, 1),
            Foreground = palette.Foreground, Background = Brushes.Transparent,
            Template = IconTemplate(palette)
        };
        ToolTipService.SetInitialShowDelay(control, 300);
        ToolTipService.SetShowOnDisabled(control, true);
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

    internal static ControlTemplate IconTemplate(SnapPalette palette)
    {
        var border = new FrameworkElementFactory(typeof(Border)) { Name = "Pill" };
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        var outer = new FrameworkElementFactory(typeof(Grid));
        outer.AppendChild(border);
        var hoverFill = new FrameworkElementFactory(typeof(Border)) { Name = "Hover" };
        hoverFill.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        hoverFill.SetValue(Border.BackgroundProperty, palette.Muted);
        hoverFill.SetValue(UIElement.OpacityProperty, 0d);
        outer.AppendChild(hoverFill);
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        outer.AppendChild(presenter);

        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(UIElement.OpacityProperty, 0.14, "Hover"));
        var press = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
        press.Setters.Add(new Setter(UIElement.OpacityProperty, 0.73, "Pill"));
        var disabled = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        disabled.Setters.Add(new Setter(UIElement.OpacityProperty, 0.32));
        var template = new ControlTemplate(typeof(Button)) { VisualTree = outer };
        template.Triggers.Add(hover);
        template.Triggers.Add(press);
        template.Triggers.Add(disabled);
        return template;
    }

    internal static Border Divider(SnapPalette palette) => new Border
    {
        Height = 20,
        Width = 1,
        Margin = new Thickness(3, 0, 4, 0),
        VerticalAlignment = VerticalAlignment.Center,
        Background = palette.Border
    };
}

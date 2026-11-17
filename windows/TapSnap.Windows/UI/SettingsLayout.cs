using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace TapSnap.Windows;

internal static class SettingsLayout
{
    public static StackPanel Group(Panel page, string title)
    {
        var caption = new TextBlock { Text = title, FontSize = 11, FontWeight = FontWeights.Medium, Margin = new Thickness(4, 0, 0, 6) };
        caption.SetResourceReference(TextBlock.ForegroundProperty, "Snap.Muted");
        page.Children.Add(caption);
        var rows = new StackPanel();
        var card = new Border
        {
            Child = rows, Margin = new Thickness(0, 0, 0, 16), CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1)
        };
        card.SetResourceReference(Border.BackgroundProperty, "Snap.Panel");
        card.SetResourceReference(Border.BorderBrushProperty, "Snap.Border");
        page.Children.Add(card);
        return rows;
    }

    public static void Toggle(Panel group, string title, bool value, Action<bool> change, string? subtitle = null)
    {
        var toggle = new CheckBox { Content = Label(title, subtitle, emphasized: true), IsChecked = value };
        toggle.SetResourceReference(FrameworkElement.StyleProperty, "SnapSwitch");
        AutomationProperties.SetName(toggle, title);
        toggle.Click += (_, _) => change(toggle.IsChecked == true);
        AddRow(group, toggle);
    }

    public static void Row(Panel group, string title, FrameworkElement control, string? subtitle = null)
    {
        var line = new DockPanel { MinHeight = 38, Margin = new Thickness(13, 2, 13, 2) };
        DockPanel.SetDock(control, Dock.Right);
        control.VerticalAlignment = VerticalAlignment.Center;
        line.Children.Add(control);
        line.Children.Add(Label(title, subtitle));
        AddRow(group, line);
    }

    public static void Slider(Panel group, string title, double min, double max, double value, double step,
        Action<double> change, Action commit, string unit = "")
    {
        var slider = new Slider
        {
            Minimum = min, Maximum = max, Value = Math.Clamp(value, min, max), TickFrequency = step,
            IsSnapToTickEnabled = true, IsMoveToPointEnabled = true, Width = 150
        };
        AutomationProperties.SetName(slider, title);
        var readout = new TextBlock
        {
            Text = $"{slider.Value:0}{unit}", MinWidth = 48, Margin = new Thickness(8, 0, 0, 0),
            FontSize = 11, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center
        };
        readout.SetResourceReference(TextBlock.ForegroundProperty, "Snap.Muted");
        slider.ValueChanged += (_, _) => { readout.Text = $"{slider.Value:0}{unit}"; change(slider.Value); };
        slider.LostKeyboardFocus += (_, _) => commit();
        slider.PreviewMouseLeftButtonUp += (_, _) => commit();
        var controls = new StackPanel { Orientation = Orientation.Horizontal };
        controls.Children.Add(slider);
        controls.Children.Add(readout);
        Row(group, title, controls);
    }

    private static void AddRow(Panel group, UIElement row)
    {
        if (group.Children.Count > 0)
        {
            var divider = new Border { Height = 1, Margin = new Thickness(13, 0, 0, 0) };
            divider.SetResourceReference(Border.BackgroundProperty, "Snap.Border");
            group.Children.Add(divider);
        }
        group.Children.Add(row);
    }

    private static StackPanel Label(string title, string? subtitle, bool emphasized = false)
    {
        var label = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
        label.Children.Add(new TextBlock { Text = title, FontSize = 12, FontWeight = emphasized ? FontWeights.Medium : FontWeights.Normal, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrEmpty(subtitle))
        {
            var detail = new TextBlock { Text = subtitle, FontSize = 11, TextWrapping = TextWrapping.Wrap };
            detail.SetResourceReference(TextBlock.ForegroundProperty, "Snap.Muted");
            label.Children.Add(detail);
        }
        return label;
    }
}

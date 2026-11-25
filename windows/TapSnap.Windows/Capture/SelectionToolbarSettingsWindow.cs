using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace TapSnap.Windows;

internal sealed class SelectionToolbarSettingsWindow : Window
{
    private readonly Settings settings;
    private readonly SnapPalette palette = SnapPalette.For(SnapTheme.IsDark);
    private readonly StackPanel preview = new() { Orientation = Orientation.Horizontal };
    private readonly StackPanel rows = new();
    private readonly Button add = new() { Content = "添加按钮  ⌄" };
    private readonly Button reset = new() { Content = "恢复默认布局" };
    private ToolbarItem[]? pinned;

    internal SelectionToolbarSettingsWindow(Settings settings)
    {
        this.settings = settings;
        if (settings.SelectionToolbarActions is { } saved) pinned = SelectionToolbarModel.PinnedActions(saved);
        Title = "自定义框选工具栏";
        Width = 475;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        SnapTheme.StyleWindow(this);

        var layout = new StackPanel { Margin = new Thickness(20) };
        layout.Children.Add(new Border
        {
            Child = preview, Height = 44, Padding = new Thickness(6, 0, 5, 0),
            HorizontalAlignment = HorizontalAlignment.Center, CornerRadius = new CornerRadius(9),
            Background = palette.EditorChrome, BorderBrush = palette.Border, BorderThickness = new Thickness(1),
            IsHitTestVisible = false, Margin = new Thickness(0, 0, 0, 14)
        });
        var rowHeader = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        DockPanel.SetDock(add, Dock.Right);
        rowHeader.Children.Add(add);
        rowHeader.Children.Add(new TextBlock { Text = "常用按钮", FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center });
        layout.Children.Add(rowHeader);
        AutomationProperties.SetName(add, "添加按钮");
        layout.Children.Add(new Border
        {
            Child = new ScrollViewer { Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            Height = 185, Background = palette.Panel, BorderBrush = palette.Border,
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9),
            Margin = new Thickness(0, 0, 0, 12)
        });

        var footer = new DockPanel();
        DockPanel.SetDock(reset, Dock.Left);
        footer.Children.Add(reset);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        buttons.Children.Add(new Button { Content = "取消", IsCancel = true, Margin = new Thickness(0, 0, 6, 0) });
        var save = new Button { Content = "保存", IsDefault = true };
        save.SetResourceReference(StyleProperty, "SnapPrimary");
        save.Click += (_, _) => Save();
        buttons.Children.Add(save);
        footer.Children.Add(buttons);
        layout.Children.Add(footer);
        Content = layout;

        add.Click += (_, _) => add.ContextMenu.IsOpen = true;
        reset.Click += (_, _) => { pinned = null; Refresh(); };
        Refresh();
    }

    private void Refresh()
    {
        var identifiers = pinned?.Select(item => item.Id).ToArray();
        var dock = SelectionToolbarModel.Layout(SelectionToolbarModel.Slots(396), true, true, identifiers);
        var items = pinned ?? [.. dock.Tools, .. dock.Outputs];
        preview.Children.Clear();
        foreach (var item in dock.Tools) preview.Children.Add(ToolbarGlyph.CreateButton(item.Title, item.Symbol, palette));
        if (dock.Tools.Length > 0) preview.Children.Add(ToolbarGlyph.Divider(palette));
        foreach (var item in dock.Outputs) preview.Children.Add(ToolbarGlyph.CreateButton(item.Title, item.Symbol, palette));
        preview.Children.Add(ToolbarGlyph.CreateButton("更多工具与操作", "⌄", palette));
        preview.Children.Add(ToolbarGlyph.Divider(palette));
        preview.Children.Add(ToolbarGlyph.CreateButton("取消框选", "×", palette));
        var confirm = ToolbarGlyph.CreateButton("复制", "✓", palette);
        confirm.Background = palette.Primary;
        confirm.Foreground = palette.PrimaryForeground;
        preview.Children.Add(confirm);

        rows.Children.Clear();
        for (int i = 0; i < items.Length; i++)
        {
            int index = i;
            var item = items[index];
            var row = new DockPanel { Height = 30, Margin = new Thickness(11, 0, 9, 0) };
            var controls = new StackPanel { Orientation = Orientation.Horizontal };
            controls.Children.Add(RowButton("⌃", $"向左移动 {item.Title}", index > 0, () => Move(items, index, index - 1)));
            controls.Children.Add(RowButton("⌄", $"向右移动 {item.Title}", index < items.Length - 1, () => Move(items, index, index + 1)));
            controls.Children.Add(RowButton("⊖", $"将 {item.Title} 移入更多", true, () =>
            {
                pinned = items.Where(candidate => candidate != item).ToArray();
                Refresh();
            }));
            DockPanel.SetDock(controls, Dock.Right);
            row.Children.Add(controls);
            var glyph = new ContentControl { Content = ToolbarGlyph.Make(item.Symbol, 14),
                Foreground = palette.Muted, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
            row.Children.Add(glyph);
            row.Children.Add(new TextBlock { Text = item.Title, VerticalAlignment = VerticalAlignment.Center });
            if (index > 0) rows.Children.Add(new Border { Height = 1, Background = palette.Border });
            rows.Children.Add(row);
        }
        if (items.Length == 0) rows.Children.Add(new TextBlock
            { Text = "常用按钮已全部收起", Foreground = palette.Muted, Margin = new Thickness(11) });

        var menu = new ContextMenu { PlacementTarget = add, Placement = PlacementMode.Bottom,
            Background = palette.Panel, Foreground = palette.Foreground, BorderBrush = palette.Border };
        foreach (var item in SelectionToolbarModel.AvailableActions.Except(items))
        {
            var entry = new MenuItem { Header = item.Title, Icon = ToolbarGlyph.Make(item.Symbol) };
            entry.Click += (_, _) => { pinned = [item, .. items]; Refresh(); };
            menu.Items.Add(entry);
        }
        add.ContextMenu = menu;
        add.IsEnabled = menu.Items.Count > 0;
        reset.IsEnabled = pinned is not null;
    }

    private void Move(IReadOnlyList<ToolbarItem> items, int index, int destination)
    {
        var updated = items.ToArray();
        (updated[index], updated[destination]) = (updated[destination], updated[index]);
        pinned = updated;
        Refresh();
    }

    private static Button RowButton(string symbol, string title, bool enabled, Action action)
    {
        var button = new Button { Content = symbol, Width = 27, Height = 27, ToolTip = title, IsEnabled = enabled };
        button.SetResourceReference(StyleProperty, "SnapGhost");
        AutomationProperties.SetName(button, title);
        button.Click += (_, _) => action();
        return button;
    }

    private void Save()
    {
        var previous = settings.SelectionToolbarActions;
        settings.SelectionToolbarActions = pinned?.Select(item => item.Id).ToArray();
        try { settings.Save(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            settings.SelectionToolbarActions = previous;
            MessageBox.Show(this, error.Message, "无法保存工具栏设置", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        DialogResult = true;
    }
}

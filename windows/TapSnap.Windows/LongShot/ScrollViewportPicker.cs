using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using PixelRect = System.Drawing.Rectangle;
using WinButton = System.Windows.Controls.Button;
using WinImage = System.Windows.Controls.Image;
using WinPoint = System.Windows.Point;
using WinShape = System.Windows.Shapes.Rectangle;

namespace TapSnap.Windows;

internal sealed class ScrollViewportPicker : Window
{
    private readonly Canvas canvas = new() { Cursor = Cursors.Cross };
    private readonly WinShape selectionBox = new()
    {
        Stroke = Brushes.MediumPurple,
        StrokeThickness = 2,
        Fill = new SolidColorBrush(Color.FromArgb(48, 130, 96, 222)),
        Visibility = Visibility.Collapsed,
        IsHitTestVisible = false
    };
    private readonly WinButton apply = new() { Content = "确认滚动区域", IsDefault = true, IsEnabled = false, Padding = new Thickness(10, 4, 10, 4) };
    private readonly BitmapSource source;
    private WinPoint? anchor;

    public PixelRect? Selection { get; private set; }

    public ScrollViewportPicker(BitmapSource source, PixelRect placement, string style)
    {
        this.source = source;
        Title = "选择会滚动的部分";
        WindowStartupLocation = WindowStartupLocation.Manual;
        WindowStyle = WindowStyle.None;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        SizeToContent = SizeToContent.Manual;
        SourceInitialized += (_, _) => Desktop.Place(this, placement);
        Loaded += (_, _) => Desktop.Place(this, placement);
        var image = new WinImage { Source = source, Stretch = Stretch.Fill, IsHitTestVisible = false };
        var outline = new SelectionBorder(style);
        SizeChanged += (_, _) =>
        {
            image.Width = outline.Width = ActualWidth;
            image.Height = outline.Height = ActualHeight;
        };
        canvas.ClipToBounds = true;
        canvas.Background = Brushes.White;
        canvas.Children.Add(image);
        canvas.Children.Add(selectionBox);
        canvas.Children.Add(outline);
        canvas.MouseLeftButtonDown += (_, e) =>
        {
            if (canvas.CaptureMouse())
            {
                anchor = e.GetPosition(canvas);
                UpdateSelection(anchor.Value);
            }
        };
        canvas.MouseMove += (_, e) =>
        {
            if (anchor.HasValue)
                UpdateSelection(e.GetPosition(canvas));
        };
        canvas.MouseLeftButtonUp += (_, e) =>
        {
            if (!anchor.HasValue)
                return;
            UpdateSelection(e.GetPosition(canvas));
            anchor = null;
            canvas.ReleaseMouseCapture();
        };
        canvas.LostMouseCapture += (_, _) => anchor = null;

        var controls = new WrapPanel { Cursor = Cursors.Arrow, HorizontalAlignment = HorizontalAlignment.Center };
        var hint = new TextBlock { Text = "框选会滚动的正文", Foreground = Brushes.White,
            Margin = new Thickness(8, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        var cancel = RecordingWindow.Button("取消 Esc", Close);
        apply.Click += (_, _) => { if (Selection.HasValue) DialogResult = true; };
        controls.Children.Add(hint);
        controls.Children.Add(cancel);
        controls.Children.Add(apply);
        controls.MouseLeftButtonDown += (_, e) => e.Handled = true;
        var footer = new Border { Background = SelectionBorder.BrushFor(0x151720, .92), Padding = new Thickness(6),
            CornerRadius = new CornerRadius(8), Child = controls, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(8) };
        SizeChanged += (_, _) =>
        {
            hint.Visibility = ActualWidth >= 270 ? Visibility.Visible : Visibility.Collapsed;
            footer.Margin = ActualWidth >= 190 ? new Thickness(8) : new Thickness(1);
            footer.Padding = ActualWidth >= 190 ? new Thickness(6) : new Thickness(1);
        };
        var layout = new Grid();
        layout.Children.Add(canvas);
        layout.Children.Add(footer);
        Content = layout;
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { e.Handled = true; Close(); }
            if (e.Key == Key.Enter && Selection.HasValue) { e.Handled = true; DialogResult = true; }
        };
        SelectionChanged += area => outline.Update(SelectionBorder.Outline(area,
            new Rect(0, 0, canvas.ActualWidth, canvas.ActualHeight)), false);
    }

    private event Action<Rect>? SelectionChanged;

    private void UpdateSelection(WinPoint cursor)
    {
        if (anchor is not { } start)
            return;
        var end = new WinPoint(Math.Clamp(cursor.X, 0, canvas.ActualWidth), Math.Clamp(cursor.Y, 0, canvas.ActualHeight));
        var area = new Rect(start, end);
        Canvas.SetLeft(selectionBox, area.Left);
        Canvas.SetTop(selectionBox, area.Top);
        selectionBox.Width = area.Width;
        selectionBox.Height = area.Height;
        selectionBox.Visibility = Visibility.Visible;

        double scaleX = source.PixelWidth / canvas.ActualWidth;
        double scaleY = source.PixelHeight / canvas.ActualHeight;
        var pixels = PixelRect.FromLTRB(
            (int)Math.Floor(area.Left * scaleX),
            (int)Math.Floor(area.Top * scaleY),
            Math.Min(source.PixelWidth, (int)Math.Ceiling(area.Right * scaleX)),
            Math.Min(source.PixelHeight, (int)Math.Ceiling(area.Bottom * scaleY)));
        Selection = pixels.Width > 16 && pixels.Height > 32 ? pixels : null;
        apply.IsEnabled = Selection.HasValue;
        SelectionChanged?.Invoke(area);
    }
}

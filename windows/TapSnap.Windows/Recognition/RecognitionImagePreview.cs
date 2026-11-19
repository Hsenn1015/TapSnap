using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace TapSnap.Windows;

internal sealed class RecognitionImagePreview : DockPanel
{
    private readonly Rect pixels;
    private readonly Image artwork;
    private readonly Rectangle highlight = new()
    {
        Stroke = Brushes.DodgerBlue, StrokeThickness = 2,
        Fill = SnapTheme.Brush(0x1e90ff, 40), IsHitTestVisible = false, Visibility = Visibility.Collapsed
    };
    private readonly Canvas canvas = new() { HorizontalAlignment = HorizontalAlignment.Center, ClipToBounds = true };
    private readonly ScrollViewer viewport = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto
    };
    private Rect location = Rect.Empty;
    private double zoom = 1;
    private double scale;
    private bool revealPending;

    internal RecognitionImagePreview(BitmapSource source)
    {
        pixels = new Rect(0, 0, source.PixelWidth, source.PixelHeight);
        artwork = new Image { Source = source, Stretch = Stretch.Fill };
        canvas.Children.Add(artwork);
        canvas.Children.Add(highlight);
        viewport.Content = canvas;
        viewport.SetResourceReference(BackgroundProperty, "Snap.Panel");
        AutomationProperties.SetName(viewport, "识别原图");
        viewport.SizeChanged += (_, _) => ResizeImage();

        var toolbar = new DockPanel { Height = 43, Margin = new Thickness(10, 0, 10, 0) };
        var zoomControls = new StackPanel { Orientation = Orientation.Horizontal };
        var zoomOut = Button("−", "缩小原图");
        var fit = Button("适合宽度", "适合宽度");
        var zoomIn = Button("+", "放大原图");
        fit.Width = double.NaN;
        fit.Padding = new Thickness(7, 0, 7, 0);
        fit.SetResourceReference(BackgroundProperty, "Snap.Hover");
        void SetZoom(double factor)
        {
            zoom = Math.Clamp(factor, 0.5, 4);
            zoomOut.IsEnabled = zoom > 0.5;
            zoomIn.IsEnabled = zoom < 4;
            fit.SetResourceReference(BackgroundProperty, zoom == 1 ? "Snap.Hover" : "Snap.Panel");
            ResizeImage();
        }
        zoomOut.Click += (_, _) => SetZoom(zoom / 1.5);
        fit.Click += (_, _) => SetZoom(1);
        zoomIn.Click += (_, _) => SetZoom(zoom * 1.5);
        zoomControls.Children.Add(zoomOut);
        zoomControls.Children.Add(fit);
        zoomControls.Children.Add(zoomIn);
        SetDock(zoomControls, Dock.Right);
        toolbar.Children.Add(zoomControls);
        toolbar.Children.Add(new TextBlock { Text = "原图", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        SetDock(toolbar, Dock.Top);
        Children.Add(toolbar);
        var divider = new Border { Height = 1 };
        divider.SetResourceReference(BackgroundProperty, "Snap.Border");
        SetDock(divider, Dock.Top);
        Children.Add(divider);
        Children.Add(viewport);
    }

    internal void Locate(Rect region)
    {
        location = Rect.Intersect(region, pixels);
        UpdateHighlight();
        Reveal();
    }

    private void ResizeImage()
    {
        // Reserve the vertical scrollbar width so showing it cannot change the fit.
        if (viewport.ActualWidth <= SystemParameters.VerticalScrollBarWidth) return;
        scale = (viewport.ActualWidth - SystemParameters.VerticalScrollBarWidth) / pixels.Width * zoom;
        artwork.Width = canvas.Width = pixels.Width * scale;
        artwork.Height = canvas.Height = pixels.Height * scale;
        UpdateHighlight();
        Reveal();
    }

    private void UpdateHighlight()
    {
        bool visible = scale > 0 && !location.IsEmpty && location.Width > 0 && location.Height > 0;
        highlight.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (!visible) return;
        Canvas.SetLeft(highlight, location.Left * scale);
        Canvas.SetTop(highlight, location.Top * scale);
        highlight.Width = location.Width * scale;
        highlight.Height = location.Height * scale;
    }

    private void Reveal()
    {
        if (highlight.Visibility != Visibility.Visible || revealPending) return;
        revealPending = true;
        _ = Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            revealPending = false;
            if (highlight.Visibility == Visibility.Visible)
                highlight.BringIntoView(new Rect(-8, -8, highlight.Width + 16, highlight.Height + 16));
        }));
    }

    private static Button Button(string title, string label)
    {
        var control = new Button { Content = title, ToolTip = label, Width = 28, Height = 28, Margin = new Thickness(3, 0, 0, 0) };
        control.SetResourceReference(StyleProperty, "SnapGhost");
        control.SetResourceReference(BackgroundProperty, "Snap.Hover");
        AutomationProperties.SetName(control, label);
        return control;
    }
}

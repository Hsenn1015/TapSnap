using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace TapSnap.Windows;

internal sealed class ImageOutputWindow : Window
{
    private readonly StackPanel controls = new() { Orientation = Orientation.Horizontal };
    private readonly Image preview = new() { Height = 160, Stretch = Stretch.Uniform, Margin = new Thickness(0, 12, 0, 8) };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button accept = new() { IsDefault = true, Margin = new Thickness(8, 0, 0, 0) };

    private ImageOutputWindow(Window owner, string title, string action)
    {
        Title = title;
        Owner = owner;
        Width = 445;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        SnapTheme.StyleWindow(this);
        accept.Content = action;
        var layout = new StackPanel { Margin = new Thickness(16) };
        layout.Children.Add(controls);
        layout.Children.Add(preview);
        layout.Children.Add(status);
        var footer = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0) };
        footer.Children.Add(new Button { IsCancel = true, Content = "取消" });
        footer.Children.Add(accept);
        layout.Children.Add(footer);
        Content = layout;
    }

    private static BitmapSource Draw(int width, int height, Action<DrawingContext> paint)
    {
        if (width < 1 || height < 1 || (long)width * height > 64_000_000)
            throw new ArgumentException("输出画布上限为 6400 万像素。");
        var visual = new DrawingVisual();
        RenderOptions.SetBitmapScalingMode(visual, BitmapScalingMode.HighQuality);
        using (var ctx = visual.RenderOpen()) paint(ctx);
        var result = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        result.Render(visual);
        result.Freeze();
        return result;
    }

    public static void Export(Window owner, BitmapSource image, string directory, string defaultFormat)
    {
        var panel = new ImageOutputWindow(owner, "导出图片", "保存…");
        var axis = new ComboBox { ItemsSource = new[] { "宽度", "高度", "最长边" }, SelectedIndex = 2, Width = 80 };
        int Reference() => axis.SelectedIndex switch { 0 => image.PixelWidth, 1 => image.PixelHeight, _ => Math.Max(image.PixelWidth, image.PixelHeight) };
        var pixels = new TextBox { Text = Reference().ToString(), Width = 80, Margin = new Thickness(6, 0, 6, 0) };
        var format = new ComboBox { ItemsSource = Settings.SaveFormats, SelectedItem = defaultFormat, Width = 75 };
        if (format.SelectedIndex < 0) format.SelectedIndex = 0;
        panel.controls.Children.Add(axis);
        panel.controls.Children.Add(pixels);
        panel.controls.Children.Add(new TextBlock { Text = "px", Margin = new Thickness(0, 3, 18, 0) });
        panel.controls.Children.Add(format);
        int generation = 0;
        byte[]? encoded = null;
        async void Update()
        {
            int id = ++generation;
            encoded = null;
            panel.accept.IsEnabled = false;
            panel.preview.Source = null;
            if (!int.TryParse(pixels.Text, out int target) || target <= 0)
            {
                panel.status.Text = "请输入有效的正整数像素尺寸。";
                return;
            }
            panel.status.Text = "正在计算文件大小…";
            try
            {
                await Task.Delay(140);
                if (generation != id || !panel.IsVisible) return;
                double factor = (double)target / Reference();
                int w = checked((int)Math.Max(1, Math.Round(image.PixelWidth * factor, MidpointRounding.AwayFromZero)));
                int h = checked((int)Math.Max(1, Math.Round(image.PixelHeight * factor, MidpointRounding.AwayFromZero)));
                var resized = w == image.PixelWidth && h == image.PixelHeight ? image :
                    Draw(w, h, ctx => ctx.DrawImage(image, new Rect(0, 0, w, h)));
                string extension = "." + format.SelectedItem;
                var bytes = await Task.Run(() =>
                {
                    using var data = new MemoryStream();
                    Images.Encode(resized, data, extension);
                    return data.ToArray();
                });
                if (generation != id || !panel.IsVisible) return;
                encoded = bytes;
                panel.preview.Source = resized;
                panel.status.Text = $"{w} × {h} px · {bytes.Length:N0} 字节";
                panel.accept.IsEnabled = true;
            }
            catch (Exception error) { if (generation == id) panel.status.Text = error.Message; }
        }
        axis.SelectionChanged += (_, _) => { pixels.Text = Reference().ToString(); Update(); };
        pixels.TextChanged += (_, _) => Update();
        format.SelectionChanged += (_, _) => Update();
        panel.Loaded += (_, _) => Update();
        panel.Closed += (_, _) => generation++;
        panel.accept.Click += (_, _) =>
        {
            if (encoded == null) return;
            string ext = (string)format.SelectedItem;
            var save = new SaveFileDialog { FileName = $"TapSnap-{DateTime.Now:yyyy-MM-dd-HHmmss}", DefaultExt = ext,
                Filter = $"{ext.ToUpperInvariant()} 图片|*.{ext}", InitialDirectory = Directory.Exists(directory) ? directory : "" };
            if (save.ShowDialog(panel) != true) return;
            string temporary = Path.Combine(Path.GetDirectoryName(save.FileName)!, Path.GetRandomFileName());
            try
            {
                File.WriteAllBytes(temporary, encoded);
                File.Move(temporary, save.FileName, true);
                panel.DialogResult = true;
            }
            catch (Exception error) { panel.status.Text = error.Message; }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        };
        panel.ShowDialog();
    }

    public static BitmapSource? Combine(Window owner, BitmapSource first, BitmapSource second)
    {
        var panel = new ImageOutputWindow(owner, "拼接两张图片", "打开合成图");
        var axis = new ComboBox { ItemsSource = new[] { "左右", "上下" }, SelectedIndex = 0, Width = 100 };
        var swap = new Button { Content = "交换顺序", Margin = new Thickness(8, 0, 0, 0) };
        panel.controls.Children.Add(axis);
        panel.controls.Children.Add(swap);
        BitmapSource? result = null;
        void Update()
        {
            bool vertical = axis.SelectedIndex == 1;
            int w = vertical ? Math.Max(first.PixelWidth, second.PixelWidth) : first.PixelWidth + second.PixelWidth;
            int h = vertical ? first.PixelHeight + second.PixelHeight : Math.Max(first.PixelHeight, second.PixelHeight);
            try
            {
                result = Draw(w, h, ctx =>
                {
                    ctx.DrawImage(first, new Rect(0, 0, first.PixelWidth, first.PixelHeight));
                    ctx.DrawImage(second, new Rect(vertical ? 0 : first.PixelWidth, vertical ? first.PixelHeight : 0,
                        second.PixelWidth, second.PixelHeight));
                });
                panel.status.Text = $"{w} × {h} px";
            }
            catch (Exception error) { result = null; panel.status.Text = error.Message; }
            panel.preview.Source = result;
            panel.accept.IsEnabled = result != null;
        }
        swap.Click += (_, _) => { (first, second) = (second, first); Update(); };
        axis.SelectionChanged += (_, _) => Update();
        panel.accept.Click += (_, _) => panel.DialogResult = true;
        Update();
        return panel.ShowDialog() == true ? result : null;
    }
}

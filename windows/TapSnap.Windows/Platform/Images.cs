using System;
using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace TapSnap.Windows;

internal static class Images
{
    public static void Copy(BitmapSource image)
    {
        var data = new DataObject();
        using var stream = new MemoryStream();
        Encode(image, stream, ".png");
        data.SetData("PNG", new MemoryStream(stream.ToArray()), false);
        data.SetImage(image);
        Clipboard.SetDataObject(data, true);
    }

    public static bool SaveWithDialog(BitmapSource image)
    {
        var picker = new SaveFileDialog
        {
            FileName = "TapSnap-" + DateTime.Now.ToString("yyyy-MM-dd-HHmmss"),
            Filter = "PNG 图片|*.png|JPEG 图片|*.jpg|WebP 图片|*.webp|AVIF 图片|*.avif|HEIC 图片|*.heic|TIFF 图片|*.tiff|BMP 图片|*.bmp|GIF 图片|*.gif",
            AddExtension = true
        };
        if (picker.ShowDialog() != true) return false;
        try { Save(image, picker.FileName); return true; }
        catch (NotSupportedException ex)
        {
            MessageBox.Show(ex.Message, "无法保存图片", MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }
    }

    public static void Save(BitmapSource image, string path)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (AdvancedImageFormats.Supports(extension))
        {
            // Do not replace an existing file if an optional codec fails.
            using var encoded = new MemoryStream();
            Encode(image, encoded, extension);
            encoded.Position = 0;
            using var file = File.Create(path);
            encoded.CopyTo(file);
            return;
        }
        using var stream = File.Create(path);
        Encode(image, stream, extension);
    }

    public static void Encode(BitmapSource image, Stream stream, string extension)
    {
        extension = extension.ToLowerInvariant();
        if (AdvancedImageFormats.Supports(extension))
        {
            AdvancedImageFormats.Encode(image, stream, extension);
            return;
        }
        BitmapEncoder encoder = extension switch
        {
            ".jpg" or ".jpeg" => new JpegBitmapEncoder { QualityLevel = 95 },
            ".gif" => new GifBitmapEncoder(),
            ".bmp" => new BmpBitmapEncoder(),
            ".tiff" or ".tif" => new TiffBitmapEncoder(),
            _ => new PngBitmapEncoder()
        };
        encoder.Frames.Add(BitmapFrame.Create(image));
        encoder.Save(stream);
    }

    public static BitmapSource Read(string path)
    {
        using var stream = File.OpenRead(path);
        var extension = Path.GetExtension(path).ToLowerInvariant();
        return AdvancedImageFormats.Supports(extension) ? AdvancedImageFormats.Decode(stream, extension) : Decode(stream);
    }

    internal static BitmapSource Decode(Stream stream)
    {
        var bitmap = BitmapFrame.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        bitmap.Freeze();
        return bitmap;
    }
}

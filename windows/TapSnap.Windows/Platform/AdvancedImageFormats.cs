using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using WinBitmapEncoder = Windows.Graphics.Imaging.BitmapEncoder;

namespace TapSnap.Windows;

internal static class AdvancedImageFormats
{
    public static bool Supports(string extension) => extension is ".webp" or ".avif" or ".heic" or ".heif";

    public static BitmapSource Decode(Stream source, string extension)
    {
        using var rendered = new MemoryStream();
        RasterCodecs.DecodeToPng(source, rendered, extension);
        rendered.Position = 0;
        return Images.Decode(rendered);
    }

    public static void Encode(BitmapSource image, Stream output, string extension)
    {
        int stride = checked(image.PixelWidth * 4);
        var pixels = new byte[checked(image.PixelHeight * stride)];
        var bgra = image.Format == PixelFormats.Bgra32 ? image : new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
        bgra.CopyPixels(pixels, stride, 0);
        if (extension is ".heic" or ".heif")
        {
            int width = image.PixelWidth, height = image.PixelHeight;
            try
            {
                var encoded = Task.Run(() => EncodeHeifAsync(pixels, (uint)width, (uint)height)).GetAwaiter().GetResult();
                output.Write(encoded);
            }
            catch (System.Runtime.InteropServices.COMException ex)
            {
                throw new NotSupportedException("这台 Windows 电脑无法编码 HEIC。请安装 HEIF 图像扩展和支持编码的 HEVC 编解码器，或选择 WebP、AVIF、PNG。", ex);
            }
            return;
        }

        RasterCodecs.Encode(pixels, (uint)image.PixelWidth, (uint)image.PixelHeight, output, extension);
    }

    private static async Task<byte[]> EncodeHeifAsync(byte[] pixels, uint width, uint height)
    {
        // The Windows HEIF encoder uses HEVC by default and needs an installed HEVC encoder.
        using var encoded = new InMemoryRandomAccessStream();
        var encoder = await WinBitmapEncoder.CreateAsync(WinBitmapEncoder.HeifEncoderId, encoded);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, width, height, 96, 96, pixels);
        await encoder.FlushAsync();
        encoded.Seek(0);
        using var reader = new DataReader(encoded.GetInputStreamAt(0));
        uint length = checked((uint)encoded.Size);
        if (length == 0 || await reader.LoadAsync(length) != length)
            throw new IOException("HEIC 编码没有产生完整的图片。");
        var bytes = new byte[length];
        reader.ReadBytes(bytes);
        return bytes;
    }
}

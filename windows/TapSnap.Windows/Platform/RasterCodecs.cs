using System;
using System.IO;
using ImageMagick;

namespace TapSnap.Windows;

internal static class RasterCodecs
{
    public static void DecodeToPng(Stream source, Stream destination, string extension)
    {
        // Select one raster decoder and frame explicitly.
        using var image = new MagickImage(source, new MagickReadSettings
        {
            Format = Format(extension),
            FrameIndex = 0,
            FrameCount = 1
        });
        image.AutoOrient();
        image.Write(destination, MagickFormat.Png32);
    }

    public static void Encode(byte[] bgra, uint width, uint height, Stream output, string extension)
    {
        using var image = new MagickImage();
        image.ReadPixels(bgra, new PixelReadSettings(width, height, StorageType.Char, "BGRA"));
        image.Quality = extension == ".webp" ? 100u : 92u;
        image.Write(output, Format(extension));
    }

    private static MagickFormat Format(string extension) => extension switch
    {
        ".webp" => MagickFormat.WebP,
        ".avif" => MagickFormat.Avif,
        ".heic" or ".heif" => MagickFormat.Heic,
        _ => throw new ArgumentException("不支持的图片格式。", nameof(extension))
    };
}

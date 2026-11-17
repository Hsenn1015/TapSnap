using ImageMagick;
using TapSnap.Windows;

const uint width = 47, height = 33;
var pixels = new byte[width * height * 4];
for (uint y = 0; y < height; y++)
for (uint x = 0; x < width; x++)
{
    uint i = (x + y * width) * 4;
    pixels[i] = (byte)(x * 5);
    pixels[i + 1] = (byte)(y * 7);
    pixels[i + 2] = 200;
    pixels[i + 3] = x < width / 2 ? (byte)127 : (byte)255;
}

foreach (string extension in new[] { ".webp", ".avif" })
{
    using var encoded = new MemoryStream();
    RasterCodecs.Encode(pixels, width, height, encoded, extension);
    var header = encoded.ToArray();
    bool matchesFormat = extension == ".webp" ? header.AsSpan(8, 4).SequenceEqual("WEBP"u8) :
        header.AsSpan(4, 8).SequenceEqual("ftypavif"u8);
    Require(matchesFormat, $"{extension} 的文件头应对应真实编码");

    using var png = new MemoryStream();
    encoded.Position = 0;
    RasterCodecs.DecodeToPng(encoded, png, extension);
    png.Position = 0;
    using var decoded = new MagickImage(png, MagickFormat.Png);
    Require(decoded.Width == width && decoded.Height == height, $"{extension} 应保留原始尺寸");
    Require(decoded.HasAlpha, $"{extension} 应保留透明通道");
    using var colors = decoded.GetPixels();
    Require(Math.Abs(colors.GetPixel(5, 10).ToArray()[3] - 127) < 8, $"{extension} 应保留半透明像素");
    Console.WriteLine($"通过：{extension} 写入和读取保留文件格式、尺寸和半透明像素");
}

// A 47 × 33 synthetic gradient encoded with macOS sips, independent of the production decoder.
using (var fixture = File.OpenRead(Path.Combine(AppContext.BaseDirectory, "synthetic.heic")))
using (var png = new MemoryStream())
{
    RasterCodecs.DecodeToPng(fixture, png, ".heic");
    png.Position = 0;
    using var decoded = new MagickImage(png, MagickFormat.Png);
    Require(decoded.Width == width && decoded.Height == height, "HEIC 解码应保留原始尺寸");
    using var colors = decoded.GetPixels();
    Require(colors.GetPixel(0, 0).ToArray()[1] < colors.GetPixel(40, 0).ToArray()[1], "HEIC 解码应保留从左到右的渐变");
    Console.WriteLine("通过：独立生成的 HEIC 图片能解码为原始尺寸和色彩渐变");
}

static void Require(bool condition, string title)
{
    if (!condition) throw new InvalidOperationException(title);
}

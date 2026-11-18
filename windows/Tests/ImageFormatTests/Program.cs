using ImageMagick;
using TapSnap.Windows;

if (args is ["--gif-fixture", string artwork, string path])
{
    using var output = File.Create(path);
    foreach (var frame in GifFixture.Frames(artwork)) output.Write(frame);
    return;
}

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

using (var stream = new MemoryStream())
using (var binary = new BinaryWriter(stream, System.Text.Encoding.UTF8, true))
{
    const int w = 64, h = 32;
    var frame = Enumerable.Repeat((byte)255, w * h * 4).ToArray();
    var gif = new RecordingGifWriter(binary, w, h);
    gif.Append(frame, 7);
    gif.Append(frame, 6);
    int p = (w * 8 + 10) * 4, q = (w * 9 + 23) * 4;
    frame[p] = frame[p + 1] = 0;
    frame[q] = frame[q + 2] = 0;
    gif.Append(frame, 7);
    Array.Fill(frame, (byte)255);
    gif.Append(frame, ushort.MaxValue);
    gif.Append(frame, 8);
    gif.Finish();
    stream.Position = 0;
    using var decoded = new MagickImageCollection(stream);
    Require(decoded.Count == 4 && decoded[0].AnimationDelay == 13 &&
            decoded[2].AnimationDelay == ushort.MaxValue && decoded[3].AnimationDelay == 8,
            "相同帧合并时长，超过 GIF 延迟上限仍能完整播放");
    Require(decoded[1].Page.X == 10 && decoded[1].Page.Y == 8 && decoded[1].Width == 14 && decoded[1].Height == 2,
            "两处局部变化只写入最小矩形");
    decoded.Coalesce();
    using var changed = decoded[1].GetPixels();
    using var cleared = decoded[2].GetPixels();
    using var held = decoded[3].GetPixels();
    Require(changed.GetPixel(10, 8).ToColor()!.R == 255 && changed.GetPixel(10, 8).ToColor()!.G == 0 &&
            changed.GetPixel(23, 9).ToColor()!.G == 255 && changed.GetPixel(23, 9).ToColor()!.R == 0 &&
            changed.GetPixel(16, 8).ToColor()!.R == 255 && changed.GetPixel(16, 8).ToColor()!.G == 255 &&
            cleared.GetPixel(10, 8).ToColor()!.G == 255 && held.GetPixel(10, 8).ToColor()!.G == 255,
            "透明差分保留背景，旧标记清除后不残影");
    Console.WriteLine("通过：GIF 局部刷新、透明像素、静止帧、总时长和长停顿");
}

static void Require(bool condition, string title)
{
    if (!condition) throw new InvalidOperationException(title);
}

using System;
using System.Drawing;
using TapSnap.Windows;

const int viewHeight = 145;
const int viewWidth = 174;
const int firstShift = 49;
const int lastShift = 101;
const int width = 260;
const int height = 191;
var body = new Rectangle(32, 18, viewWidth, viewHeight);
var page = new byte[viewWidth * (viewHeight + lastShift) * 4];
new Random(2134).NextBytes(page);
for (int i = 3; i < page.Length; i += 4)
    page[i] = 255;

TestFixedRegions(new Rectangle(0, body.Top, body.Width, body.Height));
TestFixedRegions(body);
TestFixedRegions(new Rectangle(width - body.Width, body.Top, body.Width, body.Height));
TestRejectedFrames();
TestFloatingButton();
Console.WriteLine("Long screenshot pixel checks passed.");

void TestFixedRegions(Rectangle viewport)
{
    var first = Capture(viewport, 0);
    var stitcher = new ScrollStitcher(first);
    stitcher.SetViewport(viewport);
    Require(stitcher.Append(first) == ScrollAppendStatus.Unchanged, "A static frame changed the output.");
    Require(stitcher.Append(Capture(viewport, firstShift)) == ScrollAppendStatus.Added, "First scroll did not match.");
    Require(stitcher.Append(Capture(viewport, lastShift)) == ScrollAppendStatus.Added, "Second scroll did not match.");

    var actual = stitcher.Render();
    Require(actual.Width == width, "Output width changed.");
    Require(actual.Height == height + lastShift, "Output height changed by the wrong number of rows.");
    for (int y = 0; y < actual.Height; y++)
        for (int x = 0; x < width; x++)
        {
            byte expected = y < viewport.Top ? (byte)48
                : y >= viewport.Bottom + lastShift ? (byte)210
                : x >= viewport.Left && x < viewport.Right ? page[((y - viewport.Top) * viewWidth + x - viewport.Left) * 4]
                : y < viewport.Bottom ? (byte)93 : (byte)255;
            Require(actual.Pixels[(y * width + x) * 4] == expected, $"Unexpected pixel at {x}, {y}.");
        }
    try
    {
        stitcher.SetViewport(new Rectangle(0, 0, width, height));
        throw new Exception("A viewport change was accepted after stitching began.");
    }
    catch (InvalidOperationException)
    {
    }
}

void TestRejectedFrames()
{
    var stitcher = new ScrollStitcher(Capture(body, 0));
    stitcher.SetViewport(body);
    Require(stitcher.Append(Capture(body, firstShift)) == ScrollAppendStatus.Added, "Scroll did not match.");
    Require(stitcher.Append(Capture(body, 0)) == ScrollAppendStatus.Reversed, "Reverse scroll was accepted.");
    var unrelated = Capture(body, firstShift);
    new Random(193).NextBytes(unrelated.Pixels);
    Require(stitcher.Append(unrelated) == ScrollAppendStatus.Mismatch, "An unrelated frame was accepted.");
    Require(stitcher.Append(Capture(body, lastShift)) == ScrollAppendStatus.Added, "A rejected frame changed the matching reference.");
}

void TestFloatingButton()
{
    var viewport = new Rectangle(0, 0, viewWidth, viewHeight);
    const int windowShift = 36;
    const int overlayTop = 117;
    const int overlayHeight = 10;
    var stitcher = new ScrollStitcher(View(0));
    Require(stitcher.Append(View(windowShift)) == ScrollAppendStatus.Added, "A small fixed button broke matching.");

    var result = stitcher.Render();
    Require(result.Height == viewHeight + windowShift, "Fixed button changed the measured displacement.");
    for (int y = overlayTop; y < overlayTop + overlayHeight; y++)
        for (int x = viewWidth - 19; x < viewWidth - 4; x++)
            Require(result.Pixels[(y * viewWidth + x) * 4] == page[(y * viewWidth + x) * 4],
                "The newer frame should recover content from underneath the first button.");

    ScrollFrame View(int offset)
    {
        var frame = Capture(viewport, offset).Crop(viewport);
        for (int y = overlayTop; y < overlayTop + overlayHeight; y++)
            for (int x = viewWidth - 19; x < viewWidth - 4; x++)
                frame.Pixels.AsSpan((y * viewWidth + x) * 4, 3).Fill(6);
        return frame;
    }
}

ScrollFrame Capture(Rectangle viewport, int offset)
{
    var frame = new ScrollFrame(width, height, new byte[width * height * 4]);
    for (int y = 0; y < height; y++)
        for (int x = 0; x < width; x++)
        {
            var pixel = frame.Pixels.AsSpan((y * width + x) * 4, 4);
            if (viewport.Contains(x, y))
                page.AsSpan(((offset + y - viewport.Top) * viewWidth + x - viewport.Left) * 4, 4).CopyTo(pixel);
            else
            {
                byte value = y < viewport.Top ? (byte)48 : y >= viewport.Bottom ? (byte)(109 + offset) : (byte)(93 + offset);
                pixel[..3].Fill(value);
                pixel[3] = 255;
            }
        }
    return frame;
}

static void Require(bool condition, string message)
{
    if (!condition)
        throw new Exception(message);
}

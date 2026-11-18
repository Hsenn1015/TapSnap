using ImageMagick;

internal static class GifFixture
{
    internal const int Width = 1280, Height = 720, Fps = 15, Count = 75;

    // Five seconds of a detailed static scene, a moving pointer, a scrolling panel
    // and a final hold. Both platforms consume these same opaque BGRA pixels.
    internal static IEnumerable<byte[]> Frames(string artwork)
    {
        using var image = new MagickImage(artwork);
        image.Resize(new MagickGeometry(Width, Height) { IgnoreAspectRatio = true });
        byte[] background = image.ToByteArray(MagickFormat.Bgra);
        var frame = new byte[background.Length];
        for (int i = 0; i < Count; i++)
        {
            background.CopyTo(frame, 0);
            int scroll = Math.Clamp(i - 30, 0, 20) * 5;
            if (scroll != 0)
                for (int y = 100; y < 460; y++)
                    Buffer.BlockCopy(background, ((y + scroll) * Width + 300) * 4,
                                     frame, (y * Width + 300) * 4, 560 * 4);
            int pointer = Math.Min(i, 58);
            for (int dy = 0; dy < 18; dy++)
            for (int dx = 0; dx <= dy / 2; dx++)
            {
                int p = ((210 + pointer + dy) * Width + 130 + pointer * 14 + dx) * 4;
                frame[p] = frame[p + 1] = frame[p + 2] = dx == 0 || dx == dy / 2 ? (byte)0 : (byte)255;
                frame[p + 3] = 255;
            }
            yield return frame;
        }
    }
}

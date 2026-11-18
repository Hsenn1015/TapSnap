using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using ImageMagick;

namespace TapSnap.Windows;

// Recording frames are opaque BGRA. Keep the previous canvas so unchanged pixels can
// be left in place by GIF disposal method 1, including between disjoint changes.
internal sealed class RecordingGifWriter(BinaryWriter output, int width, int height)
{
    private byte[]? previous;
    private long delayPosition;
    private int lastDelay;

    public void Append(byte[] pixels, ushort delay)
    {
        if (width is < 1 or > ushort.MaxValue || height is < 1 or > ushort.MaxValue ||
            pixels.Length != checked(width * height * 4) || delay == 0)
            throw new ArgumentException("GIF 帧尺寸或时长无效。");

        var area = new Rectangle(0, 0, width, height);
        byte[] patch = pixels;
        if (previous != null)
        {
            var current = MemoryMarshal.Cast<byte, uint>(pixels.AsSpan());
            var prior = MemoryMarshal.Cast<byte, uint>(previous.AsSpan());
            area = ChangedBounds(current, prior);
            if (area.IsEmpty)
            {
                if (ExtendDelay(delay)) return;
                // GIF stores at most 65535 centiseconds in one frame.
                area = new Rectangle(0, 0, 1, 1);
            }
            patch = new byte[area.Width * area.Height * 4];
            var target = MemoryMarshal.Cast<byte, uint>(patch.AsSpan());
            for (int y = 0; y < area.Height; y++)
            {
                int src = (y + area.Y) * width + area.X, dst = y * area.Width;
                for (int x = 0; x < area.Width; x++)
                    if (current[src + x] != prior[src + x]) target[dst + x] = current[src + x];
            }
        }

        using var image = new MagickImage();
        image.ReadPixels(patch, new PixelReadSettings((uint)area.Width, (uint)area.Height, StorageType.Char, "BGRA"));
        using var encoded = new MemoryStream();
        image.Write(encoded, MagickFormat.Gif);
        WriteImage(encoded.GetBuffer().AsSpan(0, (int)encoded.Length), area, delay);
        previous ??= new byte[pixels.Length];
        pixels.CopyTo(previous, 0);
    }

    private Rectangle ChangedBounds(ReadOnlySpan<uint> current, ReadOnlySpan<uint> prior)
    {
        int left = width, right = -1, top = height, bottom = -1;
        for (int y = 0; y < height; y++)
        {
            var row = current.Slice(y * width, width);
            var old = prior.Slice(y * width, width);
            if (row.SequenceEqual(old)) continue;
            top = Math.Min(top, y);
            bottom = y;
            int x = 0;
            while (x < left && row[x] == old[x]) x++;
            left = Math.Min(left, x);
            x = width - 1;
            while (x > right && row[x] == old[x]) x--;
            right = Math.Max(right, x);
        }
        return bottom < 0 ? Rectangle.Empty : Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
    }

    private bool ExtendDelay(ushort delay)
    {
        if (lastDelay + delay > ushort.MaxValue) return false;
        long end = output.BaseStream.Position;
        output.BaseStream.Position = delayPosition;
        lastDelay += delay;
        output.Write((ushort)lastDelay);
        output.BaseStream.Position = end;
        return true;
    }

    private void WriteImage(ReadOnlySpan<byte> gif, Rectangle area, ushort delay)
    {
        int globalSize = (gif[10] & 0x80) == 0 ? 0 : 3 << ((gif[10] & 7) + 1);
        bool first = previous == null;
        if (first)
        {
            output.Write("GIF89a"u8);
            output.Write(gif[6..(13 + globalSize)]);
            output.Write(new byte[] { 0x21, 0xff, 11 });
            output.Write("NETSCAPE2.0"u8);
            output.Write(new byte[] { 3, 1, 0, 0, 0 });
        }
        int p = 13 + globalSize;
        byte transparency = 0, transparentIndex = 0;
        while (gif[p] == 0x21)
        {
            if (gif[p + 1] == 0xf9)
            {
                transparency = (byte)(gif[p + 3] & 1);
                transparentIndex = gif[p + 6];
            }
            p += 2;
            while (gif[p] != 0) p += 1 + gif[p];
            p++;
        }
        if (gif[p] != 0x2c || gif[^1] != 0x3b) throw new InvalidDataException("GIF 帧缺少图像数据。");
        output.Write(new byte[] { 0x21, 0xf9, 4, (byte)(4 | transparency) });
        delayPosition = output.BaseStream.Position;
        lastDelay = delay;
        output.Write(delay);
        output.Write(transparentIndex);
        output.Write((byte)0);
        output.Write((byte)0x2c);
        output.Write((ushort)area.X);
        output.Write((ushort)area.Y);
        output.Write(gif.Slice(p + 5, 4));
        byte flags = gif[p + 9];
        if (!first && (flags & 0x80) == 0)
        {
            output.Write((byte)(flags | 0x80 | (gif[10] & 7)));
            output.Write(gif.Slice(13, globalSize));
        }
        else output.Write(flags);
        output.Write(gif[(p + 10)..^1]);
    }

    public void Finish()
    {
        if (previous == null) throw new InvalidDataException("没有可导出的 GIF 帧。");
        output.Write((byte)0x3b);
    }
}

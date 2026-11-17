using System;
using System.Drawing;

namespace TapSnap.Windows;

internal readonly record struct ScrollFrame(int Width, int Height, byte[] Pixels)
{
    public int Stride => checked(Width * 4);

    public ScrollFrame Crop(Rectangle rectangle)
    {
        if (rectangle == new Rectangle(0, 0, Width, Height))
            return this;

        var pixels = new byte[checked(rectangle.Width * rectangle.Height * 4)];
        var result = new ScrollFrame(rectangle.Width, rectangle.Height, pixels);
        for (int y = 0; y < rectangle.Height; y++)
            Pixels.AsSpan((rectangle.Y + y) * Stride + rectangle.X * 4, result.Stride)
                .CopyTo(pixels.AsSpan(y * result.Stride));
        return result;
    }
}

internal enum ScrollAppendStatus
{
    Unchanged,
    Added,
    Mismatch,
    Reversed,
    LimitReached,
}

internal sealed class ScrollStitcher
{
    private const int MaxPixels = 64_000_000;
    private const double MinCorrelation = 0.90;

    private readonly ScrollFrame first;
    private ScrollFrame previous;
    private ScrollFrame body;
    private ScrollFrame footer;
    private Rectangle viewport;

    public int AddedRows => body.Height - viewport.Height;
    public ScrollFrame FirstFrame => first;
    public int Width => first.Width;
    public int Height => first.Height + AddedRows;

    public ScrollStitcher(ScrollFrame firstFrame)
    {
        if (firstFrame.Width <= 16 || firstFrame.Height <= 32 ||
            (long)firstFrame.Width * firstFrame.Height > MaxPixels ||
            firstFrame.Pixels.Length != (long)firstFrame.Width * firstFrame.Height * 4)
            throw new ArgumentException("请重新选择大小合适的滚动区域。", nameof(firstFrame));

        first = firstFrame;
        footer = firstFrame;
        SetViewport(new Rectangle(0, 0, first.Width, first.Height));
    }

    public void SetViewport(Rectangle rectangle)
    {
        if (AddedRows > 0)
            throw new InvalidOperationException("拼接开始后无法更换滚动区域。");
        if (rectangle.Width <= 16 || rectangle.Height <= 32 ||
            !new Rectangle(0, 0, first.Width, first.Height).Contains(rectangle))
            throw new ArgumentException("滚动区域太小或超出了选区。", nameof(rectangle));
        viewport = rectangle;
        previous = first.Crop(rectangle);
        body = previous;
    }

    public ScrollAppendStatus Append(ScrollFrame nextFrame)
    {
        if (nextFrame.Width != first.Width || nextFrame.Height != first.Height ||
            nextFrame.Pixels.Length != first.Pixels.Length)
            return ScrollAppendStatus.Mismatch;

        var next = nextFrame.Crop(viewport);
        if (next.Pixels.AsSpan().SequenceEqual(previous.Pixels))
            return ScrollAppendStatus.Unchanged;

        var pair = new MatchImages(previous, next);
        var match = pair.FindShift();
        if (match.Confidence < MinCorrelation)
            return ScrollAppendStatus.Mismatch;
        if (match.Shift < 0)
            return ScrollAppendStatus.Reversed;
        if (match.Shift == 0)
        {
            previous = next;
            return ScrollAppendStatus.Unchanged;
        }
        if ((long)(Height + match.Shift) * Width > MaxPixels)
            return ScrollAppendStatus.LimitReached;

        int seam = pair.ChooseSeam(match);
        int retainedRows = body.Height + match.Shift - (next.Height - seam);
        var pixels = new byte[checked((body.Height + match.Shift) * body.Stride)];
        body.Pixels.AsSpan(0, retainedRows * body.Stride).CopyTo(pixels);
        next.Pixels.AsSpan(seam * next.Stride).CopyTo(pixels.AsSpan(retainedRows * body.Stride));
        body = new ScrollFrame(body.Width, body.Height + match.Shift, pixels);
        previous = next;
        footer = nextFrame;
        return ScrollAppendStatus.Added;
    }

    public ScrollFrame Render()
    {
        if (AddedRows == 0)
            return first;
        if (viewport == new Rectangle(0, 0, first.Width, first.Height))
            return body;

        var result = new ScrollFrame(Width, Height, new byte[checked(Width * Height * 4)]);
        result.Pixels.AsSpan().Fill(255);
        int firstBytes = viewport.Bottom * first.Stride;
        first.Pixels.AsSpan(0, firstBytes).CopyTo(result.Pixels);
        int footerBytes = (first.Height - viewport.Bottom) * first.Stride;
        footer.Pixels.AsSpan(viewport.Bottom * first.Stride, footerBytes).CopyTo(
            result.Pixels.AsSpan(result.Pixels.Length - footerBytes));
        for (int y = 0; y < body.Height; y++)
            body.Pixels.AsSpan(y * body.Stride, body.Stride).CopyTo(
                result.Pixels.AsSpan((y + viewport.Top) * first.Stride + viewport.Left * 4, body.Stride));
        return result;
    }

    public ScrollFrame Preview()
    {
        double scale = Math.Min(1, Math.Min(880.0 / Width, 4600.0 / Height));
        if (scale == 1)
            return Render();

        int width = Math.Max(1, (int)Math.Round(Width * scale));
        int height = Math.Max(1, (int)Math.Round(Height * scale));
        var pixels = new byte[checked(width * height * 4)];
        pixels.AsSpan().Fill(255);
        int footerStart = viewport.Bottom + AddedRows;
        for (int y = 0; y < height; y++)
        {
            int actualY = (int)((long)y * Height / height);
            for (int x = 0; x < width; x++)
            {
                int actualX = (int)((long)x * Width / width);
                int target = (y * width + x) * 4;
                if (actualY >= footerStart)
                    CopyPixel(footer, actualX, actualY - AddedRows, pixels, target);
                else if (actualY >= viewport.Top && actualX >= viewport.Left && actualX < viewport.Right)
                    CopyPixel(body, actualX - viewport.Left, actualY - viewport.Top, pixels, target);
                else if (actualY < viewport.Bottom)
                    CopyPixel(first, actualX, actualY, pixels, target);
            }
        }
        return new ScrollFrame(width, height, pixels);
    }

    private static void CopyPixel(ScrollFrame frame, int x, int y, byte[] destination, int index)
    {
        int source = y * frame.Stride + x * 4;
        frame.Pixels.AsSpan(source, 4).CopyTo(destination.AsSpan(index, 4));
    }

    private readonly record struct ShiftMatch(int Shift, double Confidence, int Top, int Bottom);

    private sealed class MatchImages
    {
        private readonly int width;
        private readonly int height;
        private readonly byte[] previous;
        private readonly byte[] next;

        public MatchImages(ScrollFrame a, ScrollFrame b)
        {
            width = Math.Min(480, a.Width);
            height = a.Height;
            previous = Grayscale(a);
            next = Grayscale(b);
        }

        public ShiftMatch FindShift()
        {
            if (previous.AsSpan().SequenceEqual(next))
                return new ShiftMatch(0, 1, 0, height);

            int top = 0;
            int bottom = height;
            // Keep same-position borders and headers out of the displacement estimate.
            while (top < bottom && SameRow(top)) top++;
            while (bottom > top && SameRow(bottom - 1)) bottom--;
            int visibleHeight = bottom - top;
            if (visibleHeight <= 32)
                return default;

            int minimumOverlap = Math.Max(24, Math.Min(200, visibleHeight / 4));
            int maxShift = visibleHeight - minimumOverlap;
            var scores = new double[2 * maxShift + 1];
            int bestShift = 0;
            double best = -2;
            for (int shift = -maxShift; shift <= maxShift; shift++)
            {
                int overlap = visibleHeight - Math.Abs(shift);
                double score = Correlation(top, shift, overlap, Math.Max(1, overlap / 80));
                scores[shift + maxShift] = score;
                if (score > best)
                {
                    best = score;
                    bestShift = shift;
                }
            }
            if (best < MinCorrelation)
                return default;

            for (int shift = -maxShift; shift <= maxShift; shift++)
                if (Math.Abs(shift - bestShift) > 2 && best - scores[shift + maxShift] < 0.02)
                    return default;

            double verified = Correlation(top, bestShift, visibleHeight - Math.Abs(bestShift), 1);
            return new ShiftMatch(bestShift, Math.Min(best, verified), top, bottom);
        }

        public int ChooseSeam(ShiftMatch match)
        {
            int rows = match.Bottom - match.Top - match.Shift;
            var oldOverlayCost = new int[rows];
            var newOverlayCost = new int[rows];
            for (int row = 0; row < rows; row++)
            {
                int newY = match.Top + row;
                int oldY = newY + match.Shift;
                if (newY == 0 || oldY >= height - 1)
                    continue;

                for (int x = 1; x < width - 1; x++)
                {
                    int oldIndex = oldY * width + x;
                    int newIndex = newY * width + x;
                    int oldValue = previous[oldIndex];
                    int newValue = next[newIndex];
                    int difference = Math.Abs(oldValue - newValue);
                    if (difference <= 2)
                        continue;

                    bool oldStable = Math.Abs(oldValue - next[oldIndex]) <= 1;
                    bool newStable = Math.Abs(newValue - previous[newIndex]) <= 1;
                    bool oldOverlay = oldStable && (!newStable || HasDetail(previous, oldIndex));
                    bool newOverlay = newStable && (!oldStable || HasDetail(next, newIndex));
                    if (!oldOverlay && !newOverlay)
                        continue;

                    // Allow two pixels of anti-aliased fringe along the seam.
                    for (int neighbor = Math.Max(0, row - 2); neighbor <= Math.Min(rows - 1, row + 2); neighbor++)
                    {
                        if (oldOverlay) oldOverlayCost[neighbor] += difference;
                        if (newOverlay) newOverlayCost[neighbor] += difference;
                    }
                }
            }

            int cost = 0;
            foreach (int value in newOverlayCost) cost += value;
            int bestCost = cost;
            int seam = 0;
            for (int boundary = 1; boundary <= rows; boundary++)
            {
                cost += oldOverlayCost[boundary - 1] - newOverlayCost[boundary - 1];
                if (cost < bestCost || (cost == bestCost && Math.Abs(boundary - rows / 2) < Math.Abs(seam - rows / 2)))
                {
                    bestCost = cost;
                    seam = boundary;
                }
            }
            return match.Top + seam;
        }

        private byte[] Grayscale(ScrollFrame frame)
        {
            var gray = new byte[checked(width * height)];
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                {
                    int index = (y * frame.Width + x * frame.Width / width) * 4;
                    gray[y * width + x] = (byte)((29 * frame.Pixels[index] +
                        150 * frame.Pixels[index + 1] + 77 * frame.Pixels[index + 2]) >> 8);
                }
            return gray;
        }

        private bool SameRow(int y)
        {
            int difference = 0;
            int start = y * width;
            for (int x = 0; x < width; x++)
                difference += Math.Abs(previous[start + x] - next[start + x]);
            return difference * 2 < width;
        }

        private bool HasDetail(byte[] values, int i)
        {
            return Math.Abs(values[i] - values[i - 1]) > 1 || Math.Abs(values[i] - values[i + 1]) > 1 ||
                   Math.Abs(values[i] - values[i - width]) > 1 || Math.Abs(values[i] - values[i + width]) > 1;
        }

        private double Correlation(int top, int shift, int rows, int rowStep)
        {
            int startA = top + Math.Max(0, shift);
            int startB = top + Math.Max(0, -shift);
            int inset = Math.Max(1, width / 32);
            int columnStep = Math.Max(1, width / 80);
            long sumA = 0, sumB = 0, squareA = 0, squareB = 0, cross = 0;
            int count = 0;
            for (int y = 0; y < rows; y += rowStep)
                for (int x = inset; x < width - inset; x += columnStep)
                {
                    int a = previous[(startA + y) * width + x];
                    int b = next[(startB + y) * width + x];
                    sumA += a;
                    sumB += b;
                    squareA += a * a;
                    squareB += b * b;
                    cross += a * b;
                    count++;
                }
            double varianceA = squareA - (double)sumA * sumA / count;
            double varianceB = squareB - (double)sumB * sumB / count;
            if (varianceA <= count || varianceB <= count)
                return -2;
            return (cross - (double)sumA * sumB / count) / Math.Sqrt(varianceA * varianceB);
        }
    }
}

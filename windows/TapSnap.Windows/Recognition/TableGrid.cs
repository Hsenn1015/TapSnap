using System;
using System.Collections.Generic;
using System.Linq;

namespace TapSnap.Windows;

internal sealed class TableGrid(int[] rows, int[] columns)
{
    public int RowCount => rows.Length - 1;
    public int ColumnCount => columns.Length - 1;

    public int Row(double y) => Cell(y, rows);
    public int Column(double x) => Cell(x, columns);

    private static int Cell(double position, IReadOnlyList<int> edges)
    {
        for (int cell = 0; cell + 1 < edges.Count; cell++)
            if (position >= edges[cell] && position < edges[cell + 1]) return cell;
        return -1;
    }

    public static TableGrid? Detect(ReadOnlySpan<byte> gray, int width, int height)
    {
        if (width <= 32 || height <= 32 || gray.Length != (long)width * height)
            return null;
        int[] histogram = new int[256];
        foreach (byte value in gray) histogram[value]++;
        int threshold = Otsu(histogram, gray.Length);
        bool inverted = histogram.Take(threshold + 1).Sum() > gray.Length / 2;
        int[] rows = Lines(gray, width, height, threshold, inverted, horizontal: true);
        int[] columns = Lines(gray, width, height, threshold, inverted, horizontal: false);
        return rows.Length >= 2 && columns.Length >= 2 ? new TableGrid(rows, columns) : null;
    }

    private static int[] Lines(ReadOnlySpan<byte> pixels, int width, int height, int threshold, bool inverted,
        bool horizontal)
    {
        int outer = horizontal ? height : width;
        int inner = horizontal ? width : height;
        int minRun = (int)(inner * .4);
        var lines = new List<int>();
        for (int position = 0; position < outer; position++)
        {
            if (lines.Count > 0 && position - lines[^1] <= 3) continue;
            int run = 0;
            for (int step = 0; step < inner; step++)
            {
                int index = horizontal ? position * width + step : step * width + position;
                bool ink = inverted ? pixels[index] > threshold : pixels[index] <= threshold;
                run = ink ? run + 1 : 0;
                if (run >= minRun)
                {
                    lines.Add(position);
                    break;
                }
            }
        }
        return lines.ToArray();
    }

    private static int Otsu(IReadOnlyList<int> histogram, int count)
    {
        double sum = 0;
        for (int gray = 0; gray < histogram.Count; gray++) sum += (double)gray * histogram[gray];
        double backgroundSum = 0;
        int backgroundCount = 0, threshold = 128;
        double best = -1;
        for (int gray = 0; gray < histogram.Count; gray++)
        {
            backgroundCount += histogram[gray];
            if (backgroundCount == 0) continue;
            int foregroundCount = count - backgroundCount;
            if (foregroundCount == 0) break;
            backgroundSum += (double)gray * histogram[gray];
            double delta = backgroundSum / backgroundCount - (sum - backgroundSum) / foregroundCount;
            double variance = (double)backgroundCount * foregroundCount * delta * delta;
            if (variance > best) { best = variance; threshold = gray; }
        }
        return threshold;
    }
}

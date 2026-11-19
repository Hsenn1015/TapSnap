using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace TapSnap.Windows;

internal sealed class OcrReviewRow(RecognizedLine[] lines)
{
    public RecognizedLine[] Lines { get; } = lines;
    public RectangleF Bounds { get; } = lines.Select(line => line.Bounds).Aggregate(RectangleF.Union);
    public string Text { get; } = OcrTextDocument.Join(lines);
}

internal sealed class OcrTextDocument
{
    private static readonly Regex Structured = new(
        @"^(?:\s{2,}|[$%#>]\s|\d{1,2}:\d{2}(?::\d{2})?$|[{}\[\]]$|[A-Za-z_]\w*\s*=(?!=)|(?:let|var|func|import|class|return|const|def)\s+\S+.*[()=;{}])");
    private static readonly Regex ListStart = new(
        @"^\s*(?:[•●▪‣◦·]|[-*+]\s+|(?:\d+|[A-Za-z])[.)](?=\s|$|[\u3400-\u9fff])|[\d一二三四五六七八九十]+、|[（(]\d+[）)])");

    private OcrTextDocument(RecognizedLine[][] rows)
    {
        OriginalLines = rows.SelectMany(row => row).ToArray();
        LineRows = OriginalLines.Select(line => new OcrReviewRow([line])).ToArray();
        Paragraphs = Read(rows).Select(lines => new OcrReviewRow(lines)).ToArray();
    }

    public RecognizedLine[] OriginalLines { get; }
    public OcrReviewRow[] LineRows { get; }
    public OcrReviewRow[] Paragraphs { get; }

    public string CopyText(bool byLine) => byLine
        ? string.Join(Environment.NewLine, OriginalLines.Select(line => line.Text))
        : string.Join(Environment.NewLine + Environment.NewLine, Paragraphs.Select(row => row.Text));

    public static OcrTextDocument From(IReadOnlyList<RecognizedLine> lines)
    {
        var rows = new List<List<RecognizedLine>>();
        foreach (var line in lines.Where(line => !string.IsNullOrWhiteSpace(line.Text)).OrderBy(line => MidY(line.Bounds)))
        {
            if (rows.Count > 0 && rows[^1][0] is { } anchor &&
                Math.Abs(MidY(anchor.Bounds) - MidY(line.Bounds)) <= Math.Min(anchor.Bounds.Height, line.Bounds.Height) * .45)
                rows[^1].Add(line);
            else
                rows.Add([line]);
        }
        return new OcrTextDocument(rows.Select(row => row.OrderBy(line => line.Bounds.Left).ToArray()).ToArray());
    }

    private static IEnumerable<RecognizedLine[]> Read(RecognizedLine[][] rows, int depth = 0)
    {
        double? gutter = depth < 3 ? ColumnGutter(rows) : null;
        if (gutter is not { } splitAt) return SingleFlow(rows);

        return Bands(rows, splitAt).SelectMany(band =>
        {
            var columns = Split(band, splitAt);
            return columns is { } pair
                ? Read(pair.Left, depth + 1).Concat(Read(pair.Right, depth + 1))
                : SingleFlow(band);
        });
    }

    private static double? ColumnGutter(RecognizedLine[][] rows)
    {
        if (rows.Length < 2) return null;
        double height = Quantile(rows.SelectMany(row => row).Select(line => (double)line.Bounds.Height), .5) ?? 1;
        var votes = new SortedDictionary<double, int>();
        for (int i = 0; i < rows.Length; i++)
        {
            var neighbors = (i + 1 < rows.Length ? rows[i].Concat(rows[i + 1]) : rows[i])
                .OrderBy(line => line.Bounds.Left).ToArray();
            double edge = neighbors[0].Bounds.Right;
            foreach (var line in neighbors.Skip(1))
            {
                if (line.Bounds.Left - edge >= height * 1.6)
                {
                    double start = edge + height * .3, end = line.Bounds.Left - height * .3;
                    votes[start] = votes.GetValueOrDefault(start) + 1;
                    votes[end] = votes.GetValueOrDefault(end) - 1;
                }
                edge = Math.Max(edge, line.Bounds.Right);
            }
        }
        var edges = votes.Keys.ToArray();
        var candidates = new List<(double Gutter, int Votes, double Width)>();
        int count = 0;
        for (int i = 0; i + 1 < edges.Length; i++)
        {
            count += votes[edges[i]];
            if (count >= 2) candidates.Add(((edges[i] + edges[i + 1]) / 2, count, edges[i + 1] - edges[i]));
        }
        foreach (var candidate in candidates.OrderByDescending(x => x.Votes).ThenByDescending(x => x.Width).Take(10))
            if (Bands(rows, candidate.Gutter).Any(band => Split(band, candidate.Gutter) is not null))
                return candidate.Gutter;
        return null;
    }

    private static IEnumerable<RecognizedLine[][]> Bands(RecognizedLine[][] rows, double gutter)
    {
        var band = new List<RecognizedLine[]>();
        bool crosses = false;
        foreach (var row in rows)
        {
            bool nextCrosses = row.Any(line => line.Bounds.Left < gutter && line.Bounds.Right > gutter);
            if (nextCrosses != crosses && band.Count > 0)
            {
                yield return band.ToArray();
                band.Clear();
            }
            crosses = nextCrosses;
            band.Add(row);
        }
        if (band.Count > 0) yield return band.ToArray();
    }

    private static (RecognizedLine[][] Left, RecognizedLine[][] Right)? Split(RecognizedLine[][] rows, double gutter)
    {
        if (rows.Any(row => row.Any(line => line.Bounds.Left < gutter && line.Bounds.Right > gutter))) return null;
        var left = rows.Select(row => row.Where(line => line.Bounds.Right <= gutter).ToArray()).Where(row => row.Length > 0).ToArray();
        var right = rows.Select(row => row.Where(line => line.Bounds.Left >= gutter).ToArray()).Where(row => row.Length > 0).ToArray();
        if (left.Length < 2 || right.Length < 2) return null;
        var paired = rows.Where(row => row.Any(line => line.Bounds.Right <= gutter) &&
                                       row.Any(line => line.Bounds.Left >= gutter)).ToArray();
        int compactRows = paired.Count(row => row.All(line => line.Bounds.Width <= line.Bounds.Height * 6 ||
                                                               line.Text.Count(char.IsNumber) * 2 > line.Text.Length));
        if (paired.Length >= 2 && compactRows * 2 >= paired.Length) return null;

        var a = left.SelectMany(row => row).Select(line => line.Bounds).Aggregate(RectangleF.Union);
        var b = right.SelectMany(row => row).Select(line => line.Bounds).Aggregate(RectangleF.Union);
        double height = Quantile(rows.SelectMany(row => row).Select(line => (double)line.Bounds.Height), .5) ?? 1;
        double overlap = Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top);
        return overlap > height && a.Width > height * 3 && b.Width > height * 3 ? (left, right) : null;
    }

    private static IEnumerable<RecognizedLine[]> SingleFlow(RecognizedLine[][] rows)
    {
        var single = rows.Where(row => row.Length == 1).Select(row => row[0].Bounds).ToArray();
        double height = Quantile(single.Select(line => (double)line.Height), .5) ?? 1;
        var steps = single.Zip(single.Skip(1))
            .Where(pair => Math.Abs(pair.First.Left - pair.Second.Left) < height * .8)
            .Select(pair => (Step: MidY(pair.Second) - MidY(pair.First), Height: Math.Max(pair.First.Height, pair.Second.Height)))
            .Where(pair => pair.Step >= pair.Height * .55 && pair.Step <= pair.Height * 2.1)
            .Select(pair => pair.Step).ToArray();
        double? pitch = steps.Length >= 2 ? Quantile(steps, .25) : null;
        double? columnRight = Quantile(single.Select(line => (double)line.Right), .8);
        var paragraph = new List<RecognizedLine>();
        foreach (var row in rows)
        {
            if (paragraph.Count > 0 && (row.Length > 1 || !CanContinue(paragraph, row[0], pitch, columnRight)))
            {
                yield return paragraph.ToArray();
                paragraph.Clear();
            }
            if (row.Length == 1) paragraph.Add(row[0]);
            else foreach (var line in row) yield return [line];
        }
        if (paragraph.Count > 0) yield return paragraph.ToArray();
    }

    private static bool CanContinue(List<RecognizedLine> paragraph, RecognizedLine next, double? pitch, double? columnRight)
    {
        var previous = paragraph[^1];
        if (IsStructured(previous.Text) || IsStructured(next.Text) || ListStart.IsMatch(next.Text)) return false;
        var a = previous.Bounds;
        var b = next.Bounds;
        double height = Math.Max(a.Height, b.Height);
        if (height <= 0 || Math.Min(a.Height, b.Height) < height * .73) return false;
        double step = MidY(b) - MidY(a);
        double limit = pitch.HasValue ? Math.Clamp(pitch.Value * 1.28, height * 1.42, height * 2.15) : height * 1.8;
        if (step < Math.Min(a.Height, b.Height) * .52 || step > limit) return false;
        double overlap = Math.Min(a.Right, b.Right) - Math.Max(a.Left, b.Left);
        if (Math.Min(a.Width, b.Width) <= 0 || overlap < Math.Min(a.Width, b.Width) * .45) return false;

        double delta = b.Left - a.Left;
        bool startsList = ListStart.IsMatch(paragraph[0].Text);
        bool aligned = Math.Abs(delta) <= height * .8;
        bool firstIndent = paragraph.Count == 1 && delta > -height * 2.6 && delta < 0;
        bool hangingIndent = startsList && paragraph.Count == 1 && delta > 0 && delta <= height * 3;
        if (!aligned && !firstIndent && !hangingIndent) return false;

        double width = Math.Max(columnRight ?? a.Right, Math.Max(a.Right, b.Right)) - Math.Min(a.Left, b.Left);
        bool shortPrevious = width > height * 4 && a.Width < width * .7;
        string text = previous.Text.TrimEnd('”', '’', '"', '\'', '）', ')', '】', '」', '』');
        if (shortPrevious && text.Length > 0 && "。！？.!?".Contains(text[^1])) return false;
        return !(shortPrevious && paragraph.Count == 1 && !startsList && previous.Text.Length <= 8 && b.Width > a.Width * 1.7);
    }

    private static bool IsStructured(string text) => Structured.IsMatch(text) || text.Contains('\t') || text.Contains(" | ");

    internal static double MidY(RectangleF rect) => rect.Top + rect.Height / 2d;

    internal static double? Quantile(IEnumerable<double> values, double fraction)
    {
        var sorted = values.Order().ToArray();
        return sorted.Length == 0 ? null : sorted[(int)Math.Round((sorted.Length - 1) * fraction, MidpointRounding.AwayFromZero)];
    }

    internal static string Join(IReadOnlyList<RecognizedLine> lines)
    {
        var text = new StringBuilder(lines[0].Text);
        for (int i = 1; i < lines.Count; i++)
            text.Append(Separator(lines[i - 1].Text, lines[i].Text)).Append(lines[i].Text);
        return text.ToString();
    }

    private static string Separator(string previous, string next)
    {
        if (previous.Length == 0 || next.Length == 0) return Environment.NewLine;
        char last = previous[^1], first = next[0];
        if (char.IsWhiteSpace(last) || char.IsWhiteSpace(first)) return "";
        if (last == '\u00ad' || (last == '-' && previous.Length > 1 && SpacedWord(previous[^2]) && SpacedWord(first)))
            return Environment.NewLine;
        if ("./?#&=@%".Contains(last) || "./?#&=@%".Contains(first))
        {
            var tail = previous.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
            if (tail is not null && (tail.Contains("://") || tail.StartsWith("www.", StringComparison.OrdinalIgnoreCase) || tail.Contains('@')))
                return Environment.NewLine;
        }
        if ("([{“‘«¿¡".Contains(last) || ",.;:!?%)]}”’»".Contains(first)) return "";
        int lastIndex = previous.Length - 1;
        if (lastIndex > 0 && char.IsSurrogatePair(previous, lastIndex - 1)) lastIndex--;
        return (Rune.TryGetRuneAt(previous, lastIndex, out var a) && Unspaced(a.Value)) ||
               (Rune.TryGetRuneAt(next, 0, out var b) && Unspaced(b.Value)) ? "" : " ";
    }

    private static bool SpacedWord(char value) => char.IsLetterOrDigit(value) && !Unspaced(value);

    private static bool Unspaced(int value) => value is >= 0x3000 and <= 0x30ff or >= 0x31f0 and <= 0x31ff
        or >= 0x3400 and <= 0x4dbf or >= 0x4e00 and <= 0x9fff or >= 0xf900 and <= 0xfaff
        or >= 0xff01 and <= 0xff0f or >= 0xff1a and <= 0xff20 or >= 0xff3b and <= 0xff40
        or >= 0xff5b and <= 0xff9f or >= 0x20000 and <= 0x323af;
}

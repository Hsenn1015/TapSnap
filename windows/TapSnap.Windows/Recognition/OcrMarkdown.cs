using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace TapSnap.Windows;

internal sealed record OcrTable(string?[][] Cells, HashSet<RecognizedLine> Lines, bool HasPartialLine)
{
    internal static OcrTable Read(TableGrid grid, IReadOnlyList<RecognizedLine> lines)
    {
        var cells = Enumerable.Range(0, grid.RowCount).Select(_ => new string?[grid.ColumnCount]).ToArray();
        var contained = new HashSet<RecognizedLine>();
        bool partial = false;
        foreach (var line in lines)
        {
            int inside = 0;
            foreach (var word in line.Words)
            {
                int row = grid.Row(OcrTextDocument.MidY(word.Bounds));
                int column = grid.Column(word.Bounds.X + word.Bounds.Width / 2d);
                if (row < 0 || column < 0) continue;
                cells[row][column] = cells[row][column] is { } previous ? previous + " " + word.Text : word.Text;
                inside++;
            }
            if (inside == 0) continue;
            if (inside == line.Words.Count) contained.Add(line);
            else partial = true;
        }
        return new OcrTable(cells, contained, partial);
    }
}

internal static class OcrMarkdown
{
    private static readonly Regex TableDelimiter = new(@"^\s*\|?\s*:?-+:?(?:\s*\|\s*:?-+:?)+\s*\|?\s*$");
    private static readonly Regex Syntax = new(
        @"^\s*(?:#{1,6}(?:\s|$)|\x60{3,}[^\x60]*$|~{3,}|>\s|(?:[-*_]\s*){3,}$)|!?\[[^\]]+\]\([^)]+\)|\*\*[^*]+\*\*|__[^_]+__|~~[^~]+~~|(?<!\w)\*[^*\s][^*]*\*(?!\w)|(?<!\w)_[^_\s][^_]*_(?!\w)|\x60[^\x60]+\x60");
    private static readonly Regex ListMarker = new(@"^(?:[-+*]\s+|[•●▪‣◦]\s*|(\d{1,9}[.)])(?:[ \t]+|(?=[\u3400-\u9fff])))");

    internal static string Source(OcrTextDocument document, Func<OcrTable?>? readTable = null)
    {
        var rows = CombineFragments(document.OriginalLines);
        if (rows.Any(row => TableDelimiter.IsMatch(row.Text))) return Literal(rows);

        bool literal = rows.Any(row => Syntax.IsMatch(row.Text));
        var table = readTable?.Invoke();
        if (table is not { HasPartialLine: false } || table.Cells.Length < 2 ||
            table.Cells[0].Length < 2 || table.Lines.Count == 0 ||
            table.Cells.Count(row => row.Any(cell => cell is not null)) < 2)
            return literal ? Literal(rows) : Formatted(document.Paragraphs);

        var output = new List<string>();
        var prose = new List<OcrReviewRow>();
        bool emitted = false;
        void FlushProse()
        {
            if (prose.Count == 0) return;
            output.Add(literal ? Literal(CombineFragments(prose.SelectMany(row => row.Lines).ToArray())) : Formatted(prose));
            prose.Clear();
        }
        var blocks = literal ? document.LineRows : document.Paragraphs;
        foreach (var block in blocks)
        {
            var remaining = new List<RecognizedLine>();
            foreach (var line in block.Lines)
            {
                if (!table.Lines.Contains(line)) remaining.Add(line);
                else
                {
                    if (remaining.Count > 0)
                    {
                        prose.Add(new OcrReviewRow(remaining.ToArray()));
                        remaining.Clear();
                    }
                    if (emitted) continue;
                    FlushProse();
                    output.Add(PipeTable(table.Cells));
                    emitted = true;
                }
            }
            if (remaining.Count > 0) prose.Add(new OcrReviewRow(remaining.ToArray()));
        }
        FlushProse();
        return string.Join("\n\n", output);
    }

    private static (string Text, RectangleF Bounds)[] CombineFragments(IReadOnlyList<RecognizedLine> lines)
    {
        var rows = new List<(string Text, RectangleF Bounds)>();
        foreach (var line in lines)
        {
            if (rows.Count > 0)
            {
                var last = rows[^1];
                double height = Math.Min(last.Bounds.Height, line.Bounds.Height);
                double gap = line.Bounds.Left - last.Bounds.Right;
                double characterWidth = CharacterWidth(last.Text, last.Bounds) ??
                                        CharacterWidth(line.Text, line.Bounds) ?? height * .55;
                if (height > 0 && Math.Abs(OcrTextDocument.MidY(last.Bounds) - OcrTextDocument.MidY(line.Bounds)) <= height * .4 &&
                    gap >= height * -.15 && gap <= characterWidth * 6)
                {
                    int spaces = Math.Max(0, (int)Math.Round(gap / characterWidth, MidpointRounding.AwayFromZero));
                    rows[^1] = (last.Text + new string(' ', spaces) + line.Text, RectangleF.Union(last.Bounds, line.Bounds));
                    continue;
                }
            }
            rows.Add((line.Text, line.Bounds));
        }
        return rows.ToArray();
    }

    private static double? CharacterWidth(string text, RectangleF bounds) =>
        text.Length >= 4 && bounds.Width > 0 && text.All(char.IsAscii) ? bounds.Width / text.Length : null;

    private static string Literal((string Text, RectangleF Bounds)[] rows)
    {
        double left = rows.Min(row => row.Bounds.Left);
        double height = OcrTextDocument.Quantile(rows.Select(row => (double)row.Bounds.Height).Where(value => value > 0), .5) ?? 1;
        double width = OcrTextDocument.Quantile(rows.Select(row => CharacterWidth(row.Text, row.Bounds)).OfType<double>(), .5) ?? height * .55;
        var gaps = rows.Zip(rows.Skip(1)).Select(pair => OcrTextDocument.MidY(pair.Second.Bounds) - OcrTextDocument.MidY(pair.First.Bounds)).ToArray();
        double pitch = OcrTextDocument.Quantile(gaps.Where(gap => gap >= height * .65 && gap <= height * 1.8), .5) ?? height * 1.35;
        var output = new List<string>();
        for (int i = 0; i < rows.Length; i++)
        {
            var (text, bounds) = rows[i];
            if (i > 0 && gaps[i - 1] >= pitch * 1.65)
                output.AddRange(Enumerable.Repeat("", Math.Min(12, (int)Math.Round(gaps[i - 1] / pitch) - 1)));
            double offset = (bounds.Left - left) / width;
            if (offset >= .85 && !char.IsWhiteSpace(text[0]))
                text = new string(' ', Math.Min(48, (int)Math.Round(offset))) + text;
            output.Add(text);
        }
        return string.Join('\n', output);
    }

    private static string Formatted(IReadOnlyList<OcrReviewRow> paragraphs)
    {
        var bodyLines = paragraphs.Where(row => row.Lines.Length > 1).SelectMany(row => row.Lines).ToArray();
        var reference = bodyLines.Length > 0 ? bodyLines : paragraphs.SelectMany(row => row.Lines).ToArray();
        double bodyHeight = OcrTextDocument.Quantile(reference.Select(line => (double)line.Bounds.Height), .5) ?? 0;
        var output = new StringBuilder();
        var indents = new List<(float X, int Spaces, int MarkerWidth)>();
        foreach (var block in paragraphs)
        {
            var marker = ListMarker.Match(block.Text);
            if (output.Length > 0) output.Append(marker.Success && indents.Count > 0 ? "\n" : "\n\n");
            if (marker.Success && marker.Length < block.Text.Length)
            {
                double tolerance = Math.Max(4, bodyHeight * .45);
                float x = block.Bounds.Left;
                while (indents.Count > 0 && x < indents[^1].X - tolerance) indents.RemoveAt(indents.Count - 1);
                int spaces = indents.Count == 0 ? 0 : indents[^1].Spaces;
                if (indents.Count > 0 && x > indents[^1].X + tolerance) spaces += indents[^1].MarkerWidth;
                else if (indents.Count > 0) indents.RemoveAt(indents.Count - 1);
                string bullet = marker.Groups[1].Success ? marker.Groups[1].Value + " " : "- ";
                indents.Add((x, spaces, bullet.Length));
                output.Append(' ', spaces).Append(bullet).Append(block.Text.AsSpan(marker.Length));
            }
            else
            {
                indents.Clear();
                if (bodyHeight > 0 && block.Lines.Length == 1 && block.Bounds.Height >= bodyHeight * 1.32 &&
                    block.Text.Length is >= 3 and <= 76 && !"。！？.!?".Contains(block.Text[^1]))
                    output.Append(block.Bounds.Height >= bodyHeight * 1.65 ? "# " : "## ");
                output.Append(block.Text);
            }
        }
        return output.ToString();
    }

    private static string PipeTable(string?[][] cells)
    {
        static string Line(IEnumerable<string> items) => "| " + string.Join(" | ", items) + " |";
        static string Escape(string? value) => value is null ? "" :
            Regex.Replace(value.Replace('\r', ' ').Replace('\n', ' '), @"[\\|\x60*_~\[\]<>]", @"\$&");
        return string.Join('\n', new[] { Line(cells[0].Select(Escape)), Line(Enumerable.Repeat("---", cells[0].Length)) }
            .Concat(cells.Skip(1).Select(row => Line(row.Select(Escape)))));
    }
}

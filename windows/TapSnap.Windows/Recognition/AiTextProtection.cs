using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace TapSnap.Windows;

internal static class AiTextProtection
{
    internal const char RedactionCharacter = '■';
    internal const int MaximumLineLength = 1600;
    private static readonly Regex LongNumber = new(@"(?:[0-9][ \t\u00a0\u2009.\-‐–]?){5,}[0-9Xx]",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, TimeSpan.FromMilliseconds(35));

    internal sealed record Line(int Id, RecognizedLine Source, string Text);

    internal static (IReadOnlyList<Line> Lines, IReadOnlyList<PrivacyTextMatch> Matches) Protect(
        IReadOnlyList<RecognizedLine> lines, RecognitionSettings settings, CancellationToken cancellationToken = default)
    {
        var transmission = new RecognitionSettings
        {
            InternalDomains = settings.InternalDomains,
            Modes = PrivacyRules.Definitions.ToDictionary(rule => rule.Kind, _ => PrivacyRuleMode.Review),
            CustomRules = settings.CustomRules.Select(rule => rule with { Mode = PrivacyRuleMode.Review }).ToList()
        };
        var masked = lines.Select(line => PrivacyRules.Normalize(line.Text).ToCharArray()).ToArray();
        var detected = PrivacyRules.Match(lines, transmission,
            (line, offset, length) => Mask(masked[line], offset, length), cancellationToken).ToList();
        var sendable = new List<Line>();
        for (int i = 0; i < lines.Count; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var line = lines[i];
            var text = PrivacyRules.Normalize(line.Text);
            if (text.Length > MaximumLineLength)
            {
                // Long OCR lines are omitted from text mode and covered for visual mode.
                detected.Add(new PrivacyTextMatch("过长文字", line.Bounds, false));
                continue;
            }
            foreach (Match match in LongNumber.Matches(text))
            {
                Mask(masked[i], match.Index, match.Length);
                var bounds = line.BoundsFor(match.Index, match.Length);
                if (!bounds.IsEmpty) detected.Add(new PrivacyTextMatch("长数字", bounds, false));
            }
            string outgoing = new(masked[i]);
            if (outgoing.Any(char.IsLetterOrDigit))
                sendable.Add(new Line(i, line, outgoing));
        }
        return (sendable, PrivacyRules.Deduplicate(detected));
    }

    private static void Mask(char[] text, int start, int length)
    {
        if (start >= 0 && length > 0 && start + length <= text.Length)
            text.AsSpan(start, length).Fill(RedactionCharacter);
    }

    internal static RectangleF VerifyValue(Line line, string value, PrivacyRuleKind? kind = null)
    {
        value = PrivacyRules.Normalize(value);
        if (value.Length is < 2 or > 200 || value != value.Trim() || !value.Any(char.IsLetterOrDigit) ||
            value.Contains(RedactionCharacter) || value.Any(char.IsControl))
            return RectangleF.Empty;
        int start = UniqueIndex(line.Text, value);
        if (start >= 0) return line.Source.BoundsFor(start, value.Length);
        if (kind is not (PrivacyRuleKind.Token or PrivacyRuleKind.Mobile or PrivacyRuleKind.Landline or
            PrivacyRuleKind.BankCard or PrivacyRuleKind.Identity or PrivacyRuleKind.VerificationCode or PrivacyRuleKind.Email))
            return RectangleF.Empty;
        return FormattedBounds(line, value);
    }

    private static int UniqueIndex(string source, string value)
    {
        int start = source.IndexOf(value, StringComparison.OrdinalIgnoreCase);
        if (start < 0 || source.IndexOf(value, start + 1, StringComparison.OrdinalIgnoreCase) >= 0) return -1;
        int end = start + value.Length;
        static bool Identifier(char character) => char.IsAsciiLetterOrDigit(character) || "_@%+-.".Contains(character);
        return (start > 0 && Identifier(source[start - 1]) && Identifier(value[0])) ||
            (end < source.Length && Identifier(source[end]) && Identifier(value[^1])) ? -1 : start;
    }

    private static RectangleF FormattedBounds(Line line, string value)
    {
        string needle = Compact(value).Text;
        if (needle.Length < 4) return RectangleF.Empty;
        var haystack = Compact(line.Text);
        var pattern = new StringBuilder();
        bool wasMask = false;
        foreach (char character in needle)
        {
            if (character != '*') pattern.Append(Regex.Escape(character.ToString()));
            else if (!wasMask) pattern.Append(@"\*+");
            wasMask = character == '*';
        }
        RectangleF found = RectangleF.Empty;
        foreach (Match match in Regex.Matches(haystack.Text, pattern.ToString(),
            RegexOptions.CultureInvariant | RegexOptions.NonBacktracking, TimeSpan.FromMilliseconds(35)))
        {
            int start = haystack.Indices[match.Index], end = haystack.Indices[match.Index + match.Length - 1] + 1;
            if (UniqueIndex(line.Text, line.Text[start..end]) != start) continue;
            if (!found.IsEmpty) return RectangleF.Empty;
            found = line.Source.BoundsFor(start, end - start);
        }
        return found;
    }

    private static (string Text, List<int> Indices) Compact(string source)
    {
        var text = new StringBuilder();
        var indices = new List<int>();
        for (int i = 0; i < source.Length; i++)
        {
            char character = source[i];
            if (char.IsWhiteSpace(character)) continue;
            text.Append(character switch
            {
                '•' or '●' or '·' or '⋅' or '…' => '*',
                '‐' or '‑' or '–' or '—' => '-',
                _ => char.ToLowerInvariant(character)
            });
            indices.Add(i);
        }
        return (text.ToString(), indices);
    }
}

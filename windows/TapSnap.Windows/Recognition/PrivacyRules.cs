using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Drawing;

namespace TapSnap.Windows;

internal enum PrivacyRuleMode { Automatic, Review, Off }
internal enum PrivacyRuleKind
{
    Mobile, Landline, Identity, BankCard, Email, Name, EmployeeId, Address,
    Credentials, VerificationCode, Token, Cookie, PrivateIp, InternalDomain, Barcode, Face
}

internal sealed record PrivacyTextMatch(string Label, RectangleF Bounds, bool ApplyAutomatically);

internal sealed record CustomPrivacyRule(string Name, string Pattern, PrivacyRuleMode Mode);
internal sealed record PrivacyRuleDefinition(PrivacyRuleKind Kind, string Label, PrivacyRuleMode DefaultMode);

internal sealed class RecognitionSettings
{
    public bool ScanAutomatically { get; set; }
    public string OcrLanguages { get; set; } = "";
    public bool OcrAutoCopy { get; set; } = true;
    public bool OcrCollapseNewlines { get; set; }
    public string InternalDomains { get; set; } = "";
    public Dictionary<PrivacyRuleKind, PrivacyRuleMode> Modes { get; set; } = new();
    public List<CustomPrivacyRule> CustomRules { get; set; } = new();
    public string AiEndpoint { get; set; } = "";
    public string AiModel { get; set; } = "";
    public string? TranslationEndpoint { get; set; }
    public string? TranslationModel { get; set; }
    public TranslationSettings Translation { get; set; } = new();
    public string FormulaPython { get; set; } = "";
    public PrivacyRuleMode Mode(PrivacyRuleKind kind) =>
        Modes.GetValueOrDefault(kind, PrivacyRules.Definitions.First(rule => rule.Kind == kind).DefaultMode);
}

internal sealed record RecognizedWord(string Text, RectangleF Bounds);
internal sealed record RecognizedLine(string Text, RectangleF Bounds, IReadOnlyList<RecognizedWord> Words)
{
    public static RecognizedLine? From(IEnumerable<RecognizedWord> input)
    {
        var words = input.Where(word => word.Text.Trim().Length > 0 && !word.Bounds.IsEmpty).ToList();
        if (words.Count == 0)
            return null;
        var text = new StringBuilder(words[0].Text);
        for (int index = 1; index < words.Count; index++)
        {
            if (NeedsSpace(words[index - 1], words[index])) text.Append(' ');
            text.Append(words[index].Text);
        }
        return new RecognizedLine(text.ToString(), words.Select(word => word.Bounds).Aggregate(RectangleF.Union), words);
    }

    public RectangleF BoundsFor(int index, int length)
    {
        RectangleF bounds = RectangleF.Empty;
        int wordStart = 0;
        for (int position = 0; position < Words.Count; position++)
        {
            var word = Words[position];
            if (position > 0 && NeedsSpace(Words[position - 1], word)) wordStart++;
            int wordEnd = wordStart + word.Text.Length;
            int start = Math.Max(wordStart, index);
            int end = Math.Min(wordEnd, index + length);
            if (start < end)
            {
                float unit = word.Bounds.Width / word.Text.Length;
                var part = new RectangleF(word.Bounds.X + (start - wordStart) * unit, word.Bounds.Y,
                                          (end - start) * unit, word.Bounds.Height);
                bounds = bounds.IsEmpty ? part : RectangleF.Union(bounds, part);
            }
            wordStart = wordEnd;
        }
        return bounds;
    }

    private static bool NeedsSpace(RecognizedWord previous, RecognizedWord next)
    {
        static bool IsHan(char character) => character is >= '\u3400' and <= '\u9fff' or >= '\uf900' and <= '\ufaff';
        return !IsHan(previous.Text[^1]) || !IsHan(next.Text[0]) ||
               next.Bounds.Left - previous.Bounds.Right > Math.Max(previous.Bounds.Height, next.Bounds.Height) * .75;
    }
}

internal static class PrivacyRules
{
    public static readonly PrivacyRuleDefinition[] Definitions =
    [
        new(PrivacyRuleKind.Mobile, "大陆手机号", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.Landline, "座机号码", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.Identity, "身份证号", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.BankCard, "银行卡号", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.Email, "邮箱", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.Name, "姓名", PrivacyRuleMode.Review),
        new(PrivacyRuleKind.EmployeeId, "工号", PrivacyRuleMode.Review),
        new(PrivacyRuleKind.Address, "详细地址", PrivacyRuleMode.Review),
        new(PrivacyRuleKind.Credentials, "账号和密码", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.VerificationCode, "验证码", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.Token, "Token、API Key 和密钥", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.Cookie, "Cookie", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.PrivateIp, "内网 IP 和端口", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.InternalDomain, "内部域名", PrivacyRuleMode.Automatic),
        new(PrivacyRuleKind.Barcode, "二维码和条形码", PrivacyRuleMode.Off),
        new(PrivacyRuleKind.Face, "人脸", PrivacyRuleMode.Off)
    ];

    private sealed record Field(PrivacyRuleKind Kind, string Labels, string Value);
    private static readonly Field[] Fields =
    [
        new(PrivacyRuleKind.Credentials, @"账号\s*/?\s*密码|账户\s*/?\s*密码|登录账号|登录名|账户名|用户名|账号|帐号|账户|口令|密码|user[ _-]?name|login[ _-]?id|account|pass(?:word|wd)|pwd", @"[^\s，,；;。|｜""']+"),
        new(PrivacyRuleKind.VerificationCode, @"短信验证码|动态验证码|验证码|动态口令|one[ _-]time[ _-]code|verification[ _-]code|otp", @"[0-9OIlS]{4,8}(?![A-Z0-9])"),
        new(PrivacyRuleKind.Token, @"访问令牌|刷新令牌|访问密钥|签名密钥|私钥|密钥|authorization|proxy-authorization|access[_ -]?token|refresh[_ -]?token|id[_ -]?token|auth[_ -]?token|token|x-api-key|api[_ -]?key|client[_ -]?secret|secret[_ -]?key|access[_ -]?key|secret", @"[^\s，,；;。|｜<>{}\[\]""']+"),
        new(PrivacyRuleKind.Cookie, @"set-cookie|cookie", @"[^\r\n|｜]+"),
        new(PrivacyRuleKind.Name, @"持卡人姓名|收件人姓名|联系人姓名|客户姓名|收货人|收件人|寄件人|联系人|申请人|姓名|full[ _-]?name|recipient|name", @"[A-Za-z][A-Za-z'’-]*(?:[ \t]+[A-Za-z][A-Za-z'’-]*){0,3}|[\p{IsCJKUnifiedIdeographs}·]{2,12}"),
        new(PrivacyRuleKind.EmployeeId, @"员工编号|员工号|工号|employee[_ -]?(?:id|number|no\.?)", @"[^\s，,；;。|｜<>{}\[\]""']+"),
        new(PrivacyRuleKind.Address, @"收货地址|收件地址|寄件地址|详细地址|家庭住址|联系地址|住址|地址|shipping[ _-]?address|mailing[ _-]?address|address", @"[^\r\n|｜]+"),
        new(PrivacyRuleKind.Mobile, @"手机号(?:码)?|手机|移动电话|mobile(?:[ _-]?number)?|cell(?:[ _-]?phone)?", @"(?:\+86[ \t-]*)?[0-9OIilSXx*•●][0-9OIilSXx*•● \t\-‐–]{6,20}[0-9OIilSXx*•●]"),
        new(PrivacyRuleKind.Landline, @"固定电话|座机(?:号码)?|办公电话|联系电话|联系方式|联系号码|电话(?:号码)?|telephone|phone(?:[ _-]?number)?", @"[0-9OIilSXx*•●][0-9OIilSXx*•● \t\-‐–]{5,18}[0-9OIilSXx*•●]"),
        new(PrivacyRuleKind.Identity, @"公民身份号码|公民身份号|身份证(?:号(?:码)?)?|证件号码|证件号|identity[ _-]?(?:number|no\.?)|id[ _-]?(?:number|no\.?)", @"[0-9OIilSXx*•●][0-9OIilSXx*•● \t\-‐–]{12,34}[0-9OIilSXx*•●]"),
        new(PrivacyRuleKind.BankCard, @"银行卡(?:号(?:码)?)?|信用卡(?:号(?:码)?)?|借记卡(?:号(?:码)?)?|卡号|card[ _-]?(?:number|no\.?)|pan", @"[0-9OIilSXx*•●][0-9OIilSXx*•● \t\-‐–]{9,35}[0-9OIilSXx*•●]")
    ];
    private static readonly TimeSpan RegexTimeout = TimeSpan.FromMilliseconds(35);
    private static Regex Pattern(string pattern) => new(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, RegexTimeout);
    private static readonly Regex Email = Pattern(@"[A-Z0-9._%+\-]+\s*@\s*[A-Z0-9\-]+(?:\s*\.\s*[A-Z0-9\-]+)*\s*\.\s*[A-Z]{2,}(?![A-Z0-9\-])");
    private static readonly Regex Numbers = Pattern(@"(?<![A-Z0-9_.])(?:\+86[ \t\-]*)?(?:[0-9][ \t\u00a0\u2009\-‐–]?){5,}[0-9X](?![A-Z0-9_]|\.[0-9])");
    private static readonly Regex Landline = Pattern(@"(?<![A-Z0-9_.])(?:\+86[ \t\-]*)?(?:\(0[1-9][0-9]{1,2}\)|0[1-9][0-9]{1,2})[ \t\-]*[2-9][0-9]{6,7}(?:[ \t]*(?:转|分机|ext\.?)[ \t]*[0-9]{1,6})?(?![A-Z0-9_]|\.[0-9])");
    private static readonly Regex Ip = Pattern(@"(?<![A-Z0-9_.])(?:[0-9]{1,3}\s*\.\s*){3}[0-9]{1,3}(?:\s*:\s*[0-9]{1,5})?(?![A-Z0-9_.])");
    private static readonly Regex Ipv6 = Pattern(@"(?<![0-9A-F:])(?:\[(?:[0-9A-F]{0,4}:){2,}[0-9A-F:.]*\](?::[0-9]{1,5})?|(?:[0-9A-F]{0,4}:){2,}[0-9A-F:.]*)(?![0-9A-F:])");
    private static readonly Regex Host = Pattern(@"(?<![A-Z0-9_\-])(?:[A-Z0-9](?:[A-Z0-9\-]*[A-Z0-9])?\.)+[A-Z][A-Z0-9\-]*(?::[0-9]{1,5})?(?![A-Z0-9_\-])");
    private static readonly Regex Token = Pattern(@"(?<![A-Z0-9_-])(?:eyJ[A-Z0-9_-]{5,}\.[A-Z0-9_-]{6,}\.[A-Z0-9_-]+|(?:sk-|gh[pousr]_|github_pat_|xox[baprs]-)[A-Z0-9_-]{2,32}[ \t]*[*•●·⋅…]{3,}[ \t]*[A-Z0-9]{3,16}|gh[pousr]_[A-Z0-9]{20,}|github_pat_[A-Z0-9_]{20,}|sk-[A-Z0-9_-]{20,}|xox[baprs]-[A-Z0-9-]{10,})(?![A-Z0-9_-])");
    private static readonly Regex UnlabelledToken = Pattern(@"(?<![A-Z0-9_])[A-Z0-9_-]{24,128}(?![A-Z0-9_-])");
    private static readonly Regex ContinuationToken = Pattern(@"^[A-Z0-9_+./=\-]{10,}$");
    private static readonly Regex ContinuationLabel = Pattern(@"^(?:[A-Z][A-Z0-9_-]{0,22}|[\p{IsCJKUnifiedIdeographs}]{2,8})\s*[:=]");
    private static readonly Regex Bearer = Pattern(@"\b(?:Bearer|Basic)[ \t]+(?<value>[A-Z0-9_.+/=\-]{8,})(?![A-Z0-9_])");
    private static readonly Regex CredentialUri = Pattern(@"\b(?:https?|postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://(?<value>[^/\s@]+:[^/\s@]+)@");
    private static readonly Regex QuerySecret = Pattern(@"[?&](?<key>access_token|refresh_token|id_token|auth_token|token|api[_-]?key|client[_-]?secret|password|passwd|pwd|signature|code|otp)=(?<value>[^&#\s]+)");
    private static readonly Regex KeyBlock = Pattern(@"-----\s*(BEGIN|END)\s+(?:[A-Z0-9]+[ \t]+)*PRIVATE[ \t]+KEY\s*-----");
    private static readonly Regex Order = Pattern(@"订单(?:号|编号)|流水(?:号|编号)|运单号|快递单号|单据号|跟踪号|order[ _-]?(?:id|number|no\.?)|tracking[ _-]?(?:id|number)");
    private static readonly Regex AnyHeader = Pattern(@"(?<![A-Z0-9_?&./-])(?:"
                    + string.Join("|", Fields.Select(field => field.Labels)) + "|" + Order + @")[""']?\s*[:=]\s*");
    private static readonly Dictionary<PrivacyRuleKind, Regex> Headers = Fields.ToDictionary(field => field.Kind,
        field => Pattern(@"^(?:" + field.Labels + @")\s*[:=]?\s*$"));
    private static readonly Dictionary<PrivacyRuleKind, Regex> FieldLabels = Fields.ToDictionary(field => field.Kind,
        field => Pattern(@"(?<![A-Z0-9_?&./-])(?:" + field.Labels + @")[""']?\s*[:=]\s*"));
    private static readonly Dictionary<PrivacyRuleKind, Regex> FieldValues = Fields.ToDictionary(field => field.Kind,
        field => Pattern(@"^(?:" + field.Value + ")"));

    public static IReadOnlyList<PrivacyTextMatch> Match(IReadOnlyList<RecognizedLine> lines, RecognitionSettings settings,
        Action<int, int, int>? matchedRange = null, System.Threading.CancellationToken cancellationToken = default)
    {
        var matches = new List<PrivacyTextMatch>();
        var internalDomains = settings.InternalDomains.ToLowerInvariant().Split([' ', '\n', '\r', '\t', ',', '，', ';', '；'],
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(domain => domain.Trim('.')).Where(domain => domain.Length > 0).ToArray();
        var custom = settings.CustomRules.Where(rule => rule.Mode != PrivacyRuleMode.Off)
            .Select(rule => (Rule: rule, Regex: new Regex(rule.Pattern, RegexOptions.CultureInvariant, RegexTimeout))).ToArray();
        var headers = lines.Select(line =>
        {
            string title = Normalize(line.Text).Trim();
            return (Line: line, Kind: Headers.FirstOrDefault(entry => entry.Value.IsMatch(title)).Key,
                    IsHeader: Headers.Values.Any(pattern => pattern.IsMatch(title)),
                    IsOrder: Order.Match(title) is { Success: true, Index: 0 } match && title[match.Length..].Trim(' ', ':', '=').Length == 0);
        }).Where(header => header.IsHeader || header.IsOrder).ToArray();

        bool withinKey = false;
        (RectangleF Bounds, PrivacyRuleKind Kind, bool Strong)? wrap = null;
        for (int lineIndex = 0; lineIndex < lines.Count; lineIndex++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var line = lines[lineIndex];
            string content = Normalize(line.Text);
            var header = headers.Where(header => !ReferenceEquals(line, header.Line) && Adjacent(header.Line.Bounds, line.Bounds))
                .OrderBy(header => Math.Abs(line.Bounds.Top - header.Line.Bounds.Top) + Math.Max(0, line.Bounds.Left - header.Line.Bounds.Right))
                .FirstOrDefault();
            var allLabels = AnyHeader.Matches(content);
            void Add(PrivacyRuleKind kind, int index, int length, bool strong = true)
            {
                var mode = settings.Mode(kind);
                if (mode != PrivacyRuleMode.Off && length > 0)
                {
                    matchedRange?.Invoke(lineIndex, index, length);
                    AddCandidate(Definitions.First(definition => definition.Kind == kind).Label, line.BoundsFor(index, length),
                                 mode == PrivacyRuleMode.Automatic && strong);
                }
            }
            void AddCandidate(string label, RectangleF bounds, bool automatic)
            {
                if (!bounds.IsEmpty && bounds.Width > 0 && bounds.Height > 0)
                    matches.Add(new PrivacyTextMatch(label, bounds, automatic));
            }
            var previous = wrap;
            wrap = null;
            if (previous is { } continuation && allLabels.Count == 0 &&
                AdjacentLine(continuation.Bounds, line.Bounds) && AcceptsContinuation(content.Trim(), continuation.Kind))
            {
                Add(continuation.Kind, 0, content.Length, continuation.Strong);
                wrap = (line.Bounds, continuation.Kind, continuation.Strong);
            }
            foreach (Match match in Email.Matches(content))
                Add(PrivacyRuleKind.Email, match.Index, match.Length);
            foreach (Match match in Landline.Matches(content))
                Add(PrivacyRuleKind.Landline, match.Index, match.Length, !header.IsOrder && !Order.IsMatch(content[..match.Index]));
            foreach (Match match in Token.Matches(content))
                Add(PrivacyRuleKind.Token, match.Index, match.Length);
            if (allLabels.Count == 0 && !content.Contains("://", StringComparison.Ordinal))
                foreach (Match match in UnlabelledToken.Matches(content))
                    if (match.Value.Any(char.IsAsciiDigit) && match.Value.Any(char.IsAsciiLetter))
                        Add(PrivacyRuleKind.Token, match.Index, match.Length, false);
            foreach (Match match in Bearer.Matches(content))
                Add(PrivacyRuleKind.Token, match.Groups["value"].Index, match.Groups["value"].Length);
            foreach (Match match in CredentialUri.Matches(content))
                Add(PrivacyRuleKind.Credentials, match.Groups["value"].Index, match.Groups["value"].Length);
            foreach (Match match in QuerySecret.Matches(content))
            {
                if (!content[..match.Index].Contains("://", StringComparison.Ordinal))
                    continue;
                var kind = match.Groups["key"].Value.ToLowerInvariant() switch
                {
                    "password" or "passwd" or "pwd" => PrivacyRuleKind.Credentials,
                    "otp" or "code" => PrivacyRuleKind.VerificationCode,
                    _ => PrivacyRuleKind.Token
                };
                Add(kind, match.Groups["value"].Index, match.Groups["value"].Length);
            }

            foreach (Regex pattern in new[] { Ip, Ipv6 })
                foreach (Match match in pattern.Matches(content))
                    if (IsPrivateIp(match.Value))
                        Add(PrivacyRuleKind.PrivateIp, match.Index, match.Length);
            if (internalDomains.Length > 0)
                foreach (Match match in Host.Matches(content))
                {
                    string hostname = match.Value.Split(':')[0].ToLowerInvariant();
                    if (internalDomains.Any(domain => hostname == domain || hostname.EndsWith("." + domain, StringComparison.Ordinal)))
                        Add(PrivacyRuleKind.InternalDomain, match.Index, match.Length);
                }

            var keyBoundary = KeyBlock.Match(content);
            if (withinKey || keyBoundary.Success)
                Add(PrivacyRuleKind.Token, 0, content.Length);
            if (keyBoundary.Success)
                withinKey = keyBoundary.Groups[1].Value.Equals("BEGIN", StringComparison.OrdinalIgnoreCase);

            foreach (Match match in Numbers.Matches(content))
            {
                string digits = Compact(match.Value);
                bool order = header.IsOrder || Order.IsMatch(content[..match.Index]);
                if (IsIdentity(digits))
                    Add(PrivacyRuleKind.Identity, match.Index, match.Length, !order);
                else if (IsMobile(digits))
                    Add(PrivacyRuleKind.Mobile, match.Index, match.Length, !order);
                else if (PassesLuhn(digits))
                    Add(PrivacyRuleKind.BankCard, match.Index, match.Length, !order && header.IsHeader && header.Kind == PrivacyRuleKind.BankCard);
            }

            foreach (var field in Fields)
            {
                void AddFieldValue(int start, int end)
                {
                    if (start >= end) return;
                    while (start < end && char.IsWhiteSpace(content[start])) start++;
                    if (start == end) return;

                    if (field.Kind is PrivacyRuleKind.Credentials or PrivacyRuleKind.Token && content[start] is '"' or '\'')
                    {
                        char quote = content[start++];
                        int close = start;
                        while (close < end && (content[close] != quote || (close > start && content[close - 1] == '\\')))
                            close++;
                        Add(field.Kind, start, close - start);
                        return;
                    }

                    var matched = FieldValues[field.Kind].Match(content[start..end]);
                    if (!matched.Success) return;
                    string value = matched.Value.TrimEnd();
                    if (field.Kind == PrivacyRuleKind.Token &&
                        (value.Equals("bearer", StringComparison.OrdinalIgnoreCase) || value.Equals("basic", StringComparison.OrdinalIgnoreCase)))
                        return;
                    if (field.Kind is PrivacyRuleKind.Mobile or PrivacyRuleKind.Landline or PrivacyRuleKind.Identity or PrivacyRuleKind.BankCard)
                    {
                        string digits = Compact(value);
                        bool properLength = field.Kind switch
                        {
                            PrivacyRuleKind.Mobile => digits.Length is >= 10 and <= 12,
                            PrivacyRuleKind.Landline => digits.Length is >= 7 and <= 12,
                            PrivacyRuleKind.Identity => digits.Length == 18,
                            _ => digits.Length is >= 13 and <= 19
                        };
                        if (!properLength || digits.Count(char.IsAsciiDigit) < 2) return;
                        bool masked = digits.Any(character => character is '*' or '•' or '●' || character == 'X' && field.Kind != PrivacyRuleKind.Identity);
                        bool strong = masked || (field.Kind switch
                        {
                            PrivacyRuleKind.Mobile => IsMobile(digits),
                            PrivacyRuleKind.Identity => IsIdentity(digits),
                            PrivacyRuleKind.BankCard => PassesLuhn(digits),
                            _ => digits.All(char.IsAsciiDigit)
                        });
                        Add(field.Kind, start, value.Length, strong);
                    }
                    else
                    {
                        Add(field.Kind, start, value.Length);
                        if (field.Kind is PrivacyRuleKind.Token or PrivacyRuleKind.Cookie or PrivacyRuleKind.Address &&
                            content.AsSpan(start + value.Length).Trim().IsEmpty && settings.Mode(field.Kind) != PrivacyRuleMode.Off)
                            wrap = (line.Bounds, field.Kind, true);
                    }
                }

                foreach (Match label in FieldLabels[field.Kind].Matches(content))
                {
                    if (field.Kind == PrivacyRuleKind.Address &&
                        Regex.IsMatch(content[..(label.Index + label.Length)], @"(?:服务器|接口|网络|访问|监听|IP)\s*地址\s*[:=]\s*$", RegexOptions.IgnoreCase, RegexTimeout))
                        continue;
                    int start = label.Index + label.Length;
                    int end = allLabels.Cast<Match>().FirstOrDefault(candidate => candidate.Index >= start)?.Index ?? content.Length;
                    AddFieldValue(start, end);
                }

                if (header.IsHeader && header.Kind == field.Kind && allLabels.Count == 0 && !Headers[field.Kind].IsMatch(content.Trim()))
                    AddFieldValue(0, content.Length);
            }

            foreach (var (rule, expression) in custom)
                foreach (Match match in expression.Matches(line.Text))
                    if (match.Length > 0)
                    {
                        matchedRange?.Invoke(lineIndex, match.Index, match.Length);
                        AddCandidate(rule.Name, line.BoundsFor(match.Index, match.Length), rule.Mode == PrivacyRuleMode.Automatic);
                    }
        }
        return Deduplicate(matches);
    }

    public static IReadOnlyList<PrivacyTextMatch> Deduplicate(IEnumerable<PrivacyTextMatch> candidates)
    {
        var accepted = new List<PrivacyTextMatch>();
        foreach (var candidate in candidates.OrderByDescending(candidate => candidate.ApplyAutomatically)
                                            .ThenByDescending(candidate => candidate.Bounds.Width * candidate.Bounds.Height))
        {
            if (!accepted.Any(existing =>
            {
                var overlap = RectangleF.Intersect(existing.Bounds, candidate.Bounds);
                return !overlap.IsEmpty && overlap.Width * overlap.Height >= candidate.Bounds.Width * candidate.Bounds.Height * .9;
            }))
                accepted.Add(candidate);
        }
        return accepted.OrderBy(candidate => candidate.Bounds.Top).ThenBy(candidate => candidate.Bounds.Left).ToArray();
    }

    private static bool Adjacent(RectangleF header, RectangleF cell)
    {
        double height = Math.Max(1, Math.Max(header.Height, cell.Height));
        double below = cell.Top - header.Top;
        bool column = below > height * .6 && below < 360 &&
                      Math.Abs(cell.Left - header.Left) <= Math.Max(18, header.Width * .24);
        bool row = Math.Abs(cell.Top + cell.Height / 2 - header.Top - header.Height / 2) <= height * .4 &&
                   cell.Left >= header.Right - 2 && cell.Left - header.Right <= Math.Max(40, height * 5);
        return column || row;
    }

    private static bool AdjacentLine(RectangleF previous, RectangleF line)
    {
        double height = Math.Max(1, Math.Max(previous.Height, line.Height));
        double distance = line.Top - previous.Top;
        return distance >= height * .55 && distance <= height * 2.3 && Math.Abs(line.Left - previous.Left) <= Math.Max(18, height);
    }

    private static bool AcceptsContinuation(string text, PrivacyRuleKind kind) => kind switch
    {
        PrivacyRuleKind.Token => !ContinuationLabel.IsMatch(text) && ContinuationToken.IsMatch(text),
        PrivacyRuleKind.Cookie => text.Contains('=') && !text.Contains(':'),
        PrivacyRuleKind.Address => text.Length > 0 && text[0] is not ('，' or ',' or '；' or ';' or '。' or '|' or '｜') &&
            !ContinuationLabel.IsMatch(text) && text.Any(char.IsDigit) && text.Any(character => "栋室楼路街号区巷单元门牌".Contains(character)),
        _ => false
    };

    internal static string Normalize(string text) => new(text.Select(character => character switch
    {
        '\u3000' => ' ',
        >= '\uff01' and <= '\uff5e' => (char)(character - 0xfee0),
        _ => character
    }).ToArray());

    private static string Compact(string value)
    {
        string trimmed = new(value.Where(character => !char.IsWhiteSpace(character) && character is not ('-' or '‐' or '–')).ToArray());
        return trimmed.StartsWith("+86", StringComparison.Ordinal) ? trimmed[3..].ToUpperInvariant() : trimmed.ToUpperInvariant();
    }

    private static bool IsMobile(string digits) => digits.Length == 11 && digits[0] == '1' &&
        digits[1] is >= '3' and <= '9' && digits.All(char.IsAsciiDigit);

    private static bool IsIdentity(string digits)
    {
        if (digits.Length != 18 || digits[0] == '0' || !digits[..17].All(char.IsAsciiDigit) ||
            !DateOnly.TryParseExact(digits[6..14], "yyyyMMdd", CultureInfo.InvariantCulture,
                                    DateTimeStyles.None, out var birth) ||
            birth.Year < 1800 || birth.Year > DateTime.Today.Year)
            return false;
        int[] weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
        int sum = weights.Select((weight, index) => weight * (digits[index] - '0')).Sum();
        return digits[17] == "10X98765432"[sum % 11];
    }

    private static bool PassesLuhn(string digits)
    {
        if (digits.Length is < 13 or > 19 || !digits.All(char.IsAsciiDigit) || digits.Distinct().Count() < 2)
            return false;
        int sum = 0;
        for (int index = digits.Length - 1; index >= 0; index--)
        {
            int digit = digits[index] - '0';
            if ((digits.Length - 1 - index) % 2 == 1) digit *= 2;
            sum += digit > 9 ? digit - 9 : digit;
        }
        return sum % 10 == 0;
    }

    private static bool IsPrivateIp(string raw)
    {
        string value = new(raw.Where(character => !char.IsWhiteSpace(character)).ToArray());
        if (value.StartsWith('['))
        {
            int end = value.IndexOf(']');
            if (end < 0 || (end + 1 < value.Length && !ValidPort(value[(end + 2)..]))) return false;
            value = value[1..end];
        }
        else if (value.Count(character => character == ':') == 1)
        {
            int end = value.IndexOf(':');
            if (!ValidPort(value[(end + 1)..])) return false;
            value = value[..end];
        }

        if (!IPAddress.TryParse(value, out var ip)) return false;
        byte[] octets = ip.GetAddressBytes();
        if (ip.AddressFamily == AddressFamily.InterNetworkV6)
            return ip.IsIPv6LinkLocal || ip.Equals(IPAddress.IPv6Loopback) || (octets[0] & 0xfe) == 0xfc;
        return octets[0] is 10 or 127 || (octets[0] == 192 && octets[1] == 168) ||
               (octets[0] == 172 && octets[1] is >= 16 and <= 31) ||
               (octets[0] == 169 && octets[1] == 254);
    }

    private static bool ValidPort(string value) => int.TryParse(value, out int port) && port is >= 1 and <= 65535;
}

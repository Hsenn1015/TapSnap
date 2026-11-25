using System.Drawing;
using TapSnap.Windows;

static RecognizedLine Line(string text, int x = 20, int y = 10) =>
    RecognizedLine.From([new RecognizedWord(text, new RectangleF(x, y, text.Length * 8, 16))])!;

static void Require(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException(name);
    Console.WriteLine($"通过 {name}");
}

static RecognizedLine OcrLine(string text, int x, int y, int width, int height = 16) =>
    new(text, new RectangleF(x, y, width, height), [new RecognizedWord(text, new RectangleF(x, y, width, height))]);

var paragraphs = OcrTextDocument.From([
    OcrLine("识别结果可以按段整理", 10, 10, 184),
    OcrLine("也保留原图行。", 10, 30, 96),
    OcrLine("Another paragraph starts here", 10, 63, 187),
    OcrLine("and is joined with a space.", 10, 83, 173)
]);
Require(paragraphs.Paragraphs.Length == 2 && paragraphs.LineRows.Length == 4 &&
    paragraphs.Paragraphs[0].Text == "识别结果可以按段整理也保留原图行。" &&
    paragraphs.Paragraphs[0].Bounds == new RectangleF(10, 10, 184, 36) &&
    paragraphs.Paragraphs[1].Text == "Another paragraph starts here and is joined with a space." &&
    paragraphs.CopyText(true).Split(Environment.NewLine).Length == 4, "OCR 可按版面合并中英文段落并保留原图行和定位框");

var columns = OcrTextDocument.From([
    OcrLine("Across two columns", 10, 0, 415, 24),
    OcrLine("Right column sentence", 230, 41, 142),
    OcrLine("Left column sentence", 10, 40, 148),
    OcrLine("continued on the left.", 10, 60, 143),
    OcrLine("continued on the right.", 230, 61, 154)
]);
Require(columns.Paragraphs.Select(row => row.Text).SequenceEqual(new[] {
    "Across two columns", "Left column sentence continued on the left.", "Right column sentence continued on the right."
}) && columns.LineRows[1].Text.StartsWith("Left"), "OCR 段落先读完左栏，原图行沿横向位置排序");

var ruled = OcrTextDocument.From([
    OcrLine("# 数据摘要", 8, 0, 120, 20), OcrLine("名称", 8, 40, 60),
    OcrLine("数量", 118, 40, 60), OcrLine("样例", 8, 72, 60), OcrLine("3", 118, 72, 20)
]);
var ruledGrid = new TableGrid([30, 64, 100], [0, 100, 200]);
Require(OcrMarkdown.Source(ruled, () => OcrTable.Read(ruledGrid, ruled.OriginalLines)) ==
    "# 数据摘要\n\n| 名称 | 数量 |\n| --- | --- |\n| 样例 | 3 |", "Markdown 同时保留可见标题与表格网格");
var literal = OcrTextDocument.From([OcrLine("| 名称 | 值 |", 10, 10, 130),
    OcrLine("| --- | --- |", 10, 30, 130), OcrLine("| A | B |", 10, 50, 130)]);
Require(OcrMarkdown.Source(literal, () => throw new InvalidOperationException()) ==
    "| 名称 | 值 |\n| --- | --- |\n| A | B |", "截图已有 Markdown 表格时保留原语法");

var settings = new RecognitionSettings();
var positioned = PrivacyRules.Match([Line("邮箱: demo@example.com")], settings).Single();
Require(positioned.Bounds == new RectangleF(52, 10, 128, 16) && positioned.ApplyAutomatically, "只定位邮箱值的原图坐标");

var line = RecognizedLine.From([
    new RecognizedWord("138", new RectangleF(40, 30, 24, 16)),
    new RecognizedWord("0000", new RectangleF(69, 30, 32, 16)),
    new RecognizedWord("0000", new RectangleF(110, 31, 32, 16))])!;
var phone = PrivacyRules.Match([line], settings).Single();
Require(phone.Label == "大陆手机号" && phone.Bounds == new RectangleF(40, 30, 102, 17), "合并跨 OCR 词的手机号定位框");

var identities = PrivacyRules.Match([Line("身份证号: 11010519491231002X"), Line("身份证号: 110105194912310021", y: 40)], settings);
Require(identities.Count == 2 && identities[0].ApplyAutomatically && !identities[1].ApplyAutomatically, "身份证校验位决定自动打码或复核");
var invalidBirthday = PrivacyRules.Match([Line("身份证号: 110105194902310021")], settings).Single();
Require(!invalidBirthday.ApplyAutomatically, "拒绝不存在的出生日期");

var cards = PrivacyRules.Match([Line("银行卡号"), Line("4111 1111 1111 1111", y: 35),
    Line("订单号: 4111 1111 1111 1111", y: 460)], settings);
Require(cards.Count == 2 && cards[0].ApplyAutomatically && !cards[1].ApplyAutomatically, "结合列标题校验银行卡号，并保留订单号复核");

settings.Modes[PrivacyRuleKind.Email] = PrivacyRuleMode.Off;
settings.Modes[PrivacyRuleKind.Mobile] = PrivacyRuleMode.Review;
settings.InternalDomains = "corp.example, team.example";
settings.CustomRules.Add(new CustomPrivacyRule("订单引用", @"REF-[0-9]{5}", PrivacyRuleMode.Automatic));
var modified = PrivacyRules.Match([Line("demo@example.com", y: 5), Line("138 0000 0000", y: 30),
    Line("REF-00001", y: 80), Line("dev.corp.example", y: 140), Line("10.34.56.78:8080", y: 160),
    Line("203.0.113.1:80", y: 180)], settings);
Require(modified.Count == 4 && !modified[0].ApplyAutomatically && modified[1].Label == "订单引用" &&
    modified[1].ApplyAutomatically && modified[2].Label == "内部域名" && modified[3].Label == "内网 IP 和端口",
    "支持关闭、仅提示和自动遮盖，以及自定义规则与域名");

var unicode = PrivacyRules.Match([Line("手机号：１３８００００００００")], new RecognitionSettings()).Single();
Require(unicode.Bounds.X == 52 && unicode.ApplyAutomatically, "全角文字归一化保留字符位置");

var splitLabel = RecognizedLine.From([
    new RecognizedWord("身份", new RectangleF(10, 80, 30, 16)),
    new RecognizedWord("证号", new RectangleF(42, 80, 32, 16)),
    new RecognizedWord("：", new RectangleF(75, 80, 8, 16)),
    new RecognizedWord("110105194912310021", new RectangleF(90, 80, 144, 16))])!;
var splitIdentity = PrivacyRules.Match([splitLabel], new RecognitionSettings()).Single();
Require(splitIdentity.Bounds == new RectangleF(90, 80, 144, 16) && !splitIdentity.ApplyAutomatically,
    "识别拆词的中文标签并只定位低可信值");

var credentials = PrivacyRules.Match([Line("password: \"demo with spaces\""), Line("https://example.test/?password=mock-value", y: 40)],
    new RecognitionSettings());
Require(credentials.Count == 2 && credentials[0].Bounds.X == 108 && credentials[0].Bounds.Width == 128 &&
    credentials[1].Label == "账号和密码", "带引号的值和 URL 参数只定位密码");

var wrapped = PrivacyRules.Match([Line("api_key: sample-private-fragment"), Line("sample-continued-fragment0", y: 32),
    Line("another-unlabelled-value123", x: 260, y: 49)], new RecognitionSettings());
Require(wrapped.Count == 3 && wrapped[0].ApplyAutomatically && wrapped[1].ApplyAutomatically &&
    wrapped[1].Bounds.Y == 32 && !wrapped[2].ApplyAutomatically, "标记换行密钥，分离其他列的低可信候选");

var x = new RecognitionSettings();
x.CustomRules.Add(new CustomPrivacyRule("超时规则", "(a+)+$", PrivacyRuleMode.Automatic));
try
{
    PrivacyRules.Match([Line(new string('a', 5000) + "!")], x);
    throw new InvalidOperationException("有界正则执行：预期超时");
}
catch (System.Text.RegularExpressions.RegexMatchTimeoutException)
{
    Console.WriteLine("通过 在有界时间内中止自定义正则");
}

const string sampleTsv = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n" +
    "4\t1\t1\t1\t1\t0\t5\t20\t150\t28\t-1\t\n" +
    "5\t1\t1\t1\t1\t1\t5\t20\t30\t20\t97.3\t姓名\n" +
    "5\t1\t1\t1\t1\t2\t40\t28\t65\t20\t98.2\tTest\n" +
    "5\t1\t2\t1\t1\t1\t5\t80\t60\t20\t98.2\tNext\n";
var outputLines = TesseractCli.Parse(sampleTsv, 200, 400);
Require(outputLines.Length == 2 && outputLines[0].Count == 2 && outputLines[0][0].Text == "姓名" &&
    outputLines[0][1].Bounds == new RectangleF(240, 428, 65, 20) && outputLines[1][0].Text == "Next",
    "命令行 OCR 按文本块分行并保留原图坐标");

var outboundSettings = new RecognitionSettings();
outboundSettings.Modes[PrivacyRuleKind.Email] = PrivacyRuleMode.Off;
outboundSettings.CustomRules.Add(new CustomPrivacyRule("示例序列", @"REF-[A-Z]{4}", PrivacyRuleMode.Off));
var outbound = AiTextProtection.Protect([
    Line("邮箱: demo@example.test / REF-DEMO / １２３.４５６７"),
    Line("Owner Iris Chen; note sample", y: 90),
    Line("Iris / Iris", y: 120),
    Line(new string('q', 1601), y: 160)
], outboundSettings);
var redacted = outbound.Lines[0];
Require(!redacted.Text.Contains("demo@example.test") && !redacted.Text.Contains("REF-DEMO") &&
        !redacted.Text.Contains("123.4567") && outbound.Matches.Count == 4 && outbound.Lines.Count == 3 &&
        outboundSettings.Mode(PrivacyRuleKind.Email) == PrivacyRuleMode.Off,
    "远程传输独立过滤已关闭的内置、自定义规则与长数字，屏蔽超长行");
Require(AiTextProtection.VerifyValue(outbound.Lines[1], "Iris Chen") == new RectangleF(68, 90, 72, 16) &&
    AiTextProtection.VerifyValue(outbound.Lines[1], "Iri").IsEmpty &&
    AiTextProtection.VerifyValue(outbound.Lines[2], "Iris").IsEmpty &&
    AiTextProtection.VerifyValue(redacted, "demo@example.test").IsEmpty,
    "AI 只接受可唯一定位的原文值，拒绝歧义、不完整或已遮盖的结果");

var formattedSource = Line("示例 ABC•●• 123");
var formatted = new AiTextProtection.Line(0, formattedSource, formattedSource.Text);
Require(AiTextProtection.VerifyValue(formatted, "ABC***123", PrivacyRuleKind.Token) == new RectangleF(44, 10, 80, 16) &&
    AiTextProtection.VerifyValue(formatted, "ABC***123", PrivacyRuleKind.Name).IsEmpty,
    "仅为可格式化的规则校验等价的 OCR 空格与遮罩字符");

static byte[] GridPixels(byte background, byte ink)
{
    const int width = 120, height = 90;
    var pixels = Enumerable.Repeat(background, width * height).ToArray();
    foreach (int y in new[] { 5, 45, 84 })
        for (int x = 8; x <= 112; x++) pixels[y * width + x] = ink;
    foreach (int x in new[] { 8, 60, 112 })
        for (int y = 5; y <= 84; y++) pixels[y * width + x] = ink;
    return pixels;
}
Require(new[] { TableGrid.Detect(GridPixels(255, 0), 120, 90), TableGrid.Detect(GridPixels(0, 255), 120, 90) }
    .All(grid => grid is { RowCount: 2, ColumnCount: 2 } && grid.Column(59) == 0 && grid.Column(60) == 1 &&
        grid.Row(45) == 1 && grid.Row(84) == -1) &&
    TableGrid.Detect(GridPixels(255, 255), 120, 90) is null,
    "表格识别按网格定位深浅两种主题的单元格，拒绝没有线框的图片");

Require(TranslationCatalog.DetectLanguageCode("你好世界") == "zh-Hans" &&
    TranslationCatalog.DetectLanguageCode("Hello world") == "en" &&
    TranslationCatalog.DetectLanguageCode("こんにちは世界") == "ja" &&
    TranslationCatalog.DetectLanguageCode("안녕하세요") == "ko",
    "翻译语种检测准确识别中英日韩");

Require(TranslationCatalog.ResolveTargetLanguage("auto", "你好世界") == "en" &&
    TranslationCatalog.ResolveTargetLanguage("auto", "Hello world") == "zh-Hans" &&
    TranslationCatalog.ResolveTargetLanguage("ja", "Hello world") == "ja",
    "自动目标语言在中英之间智能互译，显式目标语言保持不变");

Require(TranslationProtocol.BaiduSignature("2015063000000001", "apple", "1435660288", "12345678") ==
    "f89f9594663708c1605f3d736d01d2d4",
    "百度翻译 MD5 签名与官方测试向量一致");

Require(TranslationProtocol.YoudaoTruncateInput("short") == "short" &&
    TranslationProtocol.YoudaoTruncateInput("1234567890ABCDEFGHIJ12345") == "123456789025FGHIJ12345" &&
    TranslationProtocol.YoudaoSignature("app", "hello", "salt", "1700000000", "secret").Length == 64,
    "有道翻译 v3 截断规则与 SHA-256 签名正确");

Require(TranslationProtocol.DeepLEndpoint(new TranslationApiProfile(), "abc:fx").Host == "api-free.deepl.com" &&
    TranslationProtocol.DeepLEndpoint(new TranslationApiProfile(), "abc-pro").Host == "api.deepl.com" &&
    TranslationProtocol.TencentAuthorization("id", "key", System.Text.Encoding.UTF8.GetBytes("{}"), 1700000000)
        .StartsWith("TC3-HMAC-SHA256 Credential=id/2023-11-14/tmt/tc3_request, SignedHeaders=content-type;host, Signature="),
    "DeepL Free/Pro 端点与腾讯云 TC3-HMAC-SHA256 鉴权头格式正确");

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace TapSnap.Windows;

internal enum TranslationProviderKind { Api, Local, Online }

internal enum TranslationApiProvider { Google, Baidu, DeepL, Azure, Tencent, Youdao }

internal enum OnlineModelPreset { DeepSeek, Qwen, Custom }

internal enum QuickTranslateStyle { CleanCard, LiquidGlass, Editorial, InlineBilingual, DynamicBubble }

internal sealed class TranslationApiProfile
{
    public string AppId { get; set; } = "";
    public string Region { get; set; } = "";
    public string CustomBaseUrl { get; set; } = "";

    public TranslationApiProfile Clone() => new()
    {
        AppId = AppId,
        Region = Region,
        CustomBaseUrl = CustomBaseUrl
    };
}

internal sealed class TranslationModelProfile
{
    public string Endpoint { get; set; } = "";
    public string Model { get; set; } = "";

    public TranslationModelProfile Clone() => new()
    {
        Endpoint = Endpoint,
        Model = Model
    };
}

internal sealed class TranslationSettings
{
    public TranslationProviderKind Provider { get; set; } = TranslationProviderKind.Api;
    public TranslationApiProvider ApiProvider { get; set; } = TranslationApiProvider.Google;
    public OnlineModelPreset OnlinePreset { get; set; } = OnlineModelPreset.DeepSeek;
    public string TargetLanguage { get; set; } = "zh-Hans";
    public bool AutoTranslateOnOpen { get; set; } = true;
    public QuickTranslateStyle QuickTranslateStyle { get; set; } = QuickTranslateStyle.CleanCard;
    public double QuickTranslateFontSize { get; set; } = 14;
    public Dictionary<string, TranslationApiProfile> ApiProfiles { get; set; } = new();
    public Dictionary<string, TranslationModelProfile> ModelProfiles { get; set; } = new();

    public TranslationApiProfile GetApiProfile(TranslationApiProvider provider)
    {
        string key = provider.ToString();
        if (ApiProfiles.TryGetValue(key, out var profile))
            return profile;
        return new TranslationApiProfile
        {
            Region = provider == TranslationApiProvider.Tencent ? "ap-beijing" : ""
        };
    }

    public void SetApiProfile(TranslationApiProvider provider, TranslationApiProfile profile) =>
        ApiProfiles[provider.ToString()] = profile.Clone();

    public TranslationModelProfile GetModelProfile(bool isLocal, OnlineModelPreset preset,
        (string Endpoint, string Model)? legacyLocal = null)
    {
        string key = isLocal ? "Local" : preset.ToString();
        if (ModelProfiles.TryGetValue(key, out var profile))
            return profile;
        if (isLocal)
        {
            if (legacyLocal is { } legacy)
                return new TranslationModelProfile { Endpoint = legacy.Endpoint, Model = legacy.Model };
            return new TranslationModelProfile { Endpoint = "http://127.0.0.1:11434/v1", Model = "" };
        }
        return preset switch
        {
            OnlineModelPreset.DeepSeek => new TranslationModelProfile { Endpoint = "https://api.deepseek.com/v1", Model = "deepseek-chat" },
            OnlineModelPreset.Qwen => new TranslationModelProfile { Endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1", Model = "qwen-plus" },
            _ => new TranslationModelProfile()
        };
    }

    public void SetModelProfile(bool isLocal, OnlineModelPreset preset, TranslationModelProfile profile) =>
        ModelProfiles[isLocal ? "Local" : preset.ToString()] = profile.Clone();

    public string ActiveDisplayName() => Provider switch
    {
        TranslationProviderKind.Api => TranslationCatalog.ApiTitle(ApiProvider),
        TranslationProviderKind.Local => "本机模型",
        TranslationProviderKind.Online => OnlinePreset switch
        {
            OnlineModelPreset.DeepSeek => "DeepSeek",
            OnlineModelPreset.Qwen => "通义千问",
            _ => "在线大模型"
        },
        _ => "Google 翻译"
    };

    public TranslationSettings Clone()
    {
        var copy = new TranslationSettings
        {
            Provider = Provider,
            ApiProvider = ApiProvider,
            OnlinePreset = OnlinePreset,
            TargetLanguage = TargetLanguage,
            AutoTranslateOnOpen = AutoTranslateOnOpen,
            QuickTranslateStyle = QuickTranslateStyle,
            QuickTranslateFontSize = QuickTranslateFontSize
        };
        foreach (var pair in ApiProfiles) copy.ApiProfiles[pair.Key] = pair.Value.Clone();
        foreach (var pair in ModelProfiles) copy.ModelProfiles[pair.Key] = pair.Value.Clone();
        return copy;
    }
}

internal sealed record TranslationLanguageOption(string Code, string DisplayName, string PromptName);

internal static class TranslationCatalog
{
    public static readonly TranslationLanguageOption[] TargetLanguages =
    [
        new("auto", "自动选择", "Auto"),
        new("zh-Hans", "简体中文", "Simplified Chinese"),
        new("zh-Hant", "繁體中文", "Traditional Chinese"),
        new("en", "英语", "English"),
        new("ja", "日语", "Japanese"),
        new("ko", "韩语", "Korean"),
        new("fr", "法语", "French"),
        new("de", "德语", "German"),
        new("es", "西班牙语", "Spanish")
    ];

    public static readonly TranslationLanguageOption[] SourceLanguages =
    [
        new("auto", "自动检测", "auto"),
        new("zh-Hans", "简体中文", "Simplified Chinese"),
        new("zh-Hant", "繁體中文", "Traditional Chinese"),
        new("en", "英语", "English"),
        new("ja", "日语", "Japanese"),
        new("ko", "韩语", "Korean"),
        new("fr", "法语", "French"),
        new("de", "德语", "German"),
        new("es", "西班牙语", "Spanish")
    ];

    public static string LanguageDisplayName(string code) =>
        TargetLanguages.FirstOrDefault(item => item.Code.Equals(code, StringComparison.OrdinalIgnoreCase))?.DisplayName
        ?? SourceLanguages.FirstOrDefault(item => item.Code.Equals(code, StringComparison.OrdinalIgnoreCase))?.DisplayName
        ?? code;

    public static string LanguagePromptName(string code) =>
        TargetLanguages.FirstOrDefault(item => item.Code.Equals(code, StringComparison.OrdinalIgnoreCase))?.PromptName
        ?? code;

    public static string ApiTitle(TranslationApiProvider provider) => provider switch
    {
        TranslationApiProvider.Google => "Google 翻译",
        TranslationApiProvider.Baidu => "百度翻译",
        TranslationApiProvider.DeepL => "DeepL",
        TranslationApiProvider.Azure => "微软翻译",
        TranslationApiProvider.Tencent => "腾讯翻译",
        TranslationApiProvider.Youdao => "有道翻译",
        _ => "Google 翻译"
    };

    public static bool RequiresAppId(TranslationApiProvider provider) =>
        provider is TranslationApiProvider.Baidu or TranslationApiProvider.Tencent or TranslationApiProvider.Youdao;

    public static bool RequiresSecret(TranslationApiProvider provider) =>
        provider != TranslationApiProvider.Google;

    public static bool SupportsRegion(TranslationApiProvider provider) =>
        provider is TranslationApiProvider.Azure or TranslationApiProvider.Tencent;

    public static bool SupportsCustomEndpoint(TranslationApiProvider provider) =>
        provider is TranslationApiProvider.Google or TranslationApiProvider.DeepL or TranslationApiProvider.Azure;

    public static string AppIdLabel(TranslationApiProvider provider) => provider switch
    {
        TranslationApiProvider.Baidu => "App ID",
        TranslationApiProvider.Tencent => "SecretId",
        TranslationApiProvider.Youdao => "应用 ID",
        _ => ""
    };

    public static string SecretLabel(TranslationApiProvider provider) => provider switch
    {
        TranslationApiProvider.Google => "API Key",
        TranslationApiProvider.Baidu => "密钥",
        TranslationApiProvider.DeepL => "Auth Key",
        TranslationApiProvider.Azure => "API Key",
        TranslationApiProvider.Tencent => "SecretKey",
        TranslationApiProvider.Youdao => "应用密钥",
        _ => "密钥"
    };

    public static string QuickStyleName(QuickTranslateStyle style) => style switch
    {
        QuickTranslateStyle.CleanCard => "极简分块卡片",
        QuickTranslateStyle.LiquidGlass => "液态玻璃语义胶囊",
        QuickTranslateStyle.Editorial => "聚光取词取景器",
        QuickTranslateStyle.InlineBilingual => "原地双语高亮卡",
        QuickTranslateStyle.DynamicBubble => "灵动岛气泡卡",
        _ => "极简分块卡片"
    };

    public static string QuickStyleSummary(QuickTranslateStyle style) => style switch
    {
        QuickTranslateStyle.CleanCard => "原生分块卡片：原文块 + 语言互换条 + 译文块，支持朗读与改字",
        QuickTranslateStyle.LiquidGlass => "冰蓝靛紫液态质感 + 「译」胶囊徽标浮卡",
        QuickTranslateStyle.Editorial => "轻暗幕四角取景框 + 3px 渐变色条首行直出译文",
        QuickTranslateStyle.InlineBilingual => "琥珀高亮原选区 + 三态切换（仅译文 / 双语对照 / 覆盖原文）",
        QuickTranslateStyle.DynamicBubble => "薄荷绿灵动岛加载胶囊展开气泡 + 外侧竖排动作豆",
        _ => ""
    };

    public static string DetectLanguageCode(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "en";
        int han = 0, kana = 0, hangul = 0, latin = 0;
        foreach (char c in text)
        {
            if (c is (>= '\u3040' and <= '\u30ff') or (>= '\u31f0' and <= '\u31ff')) kana++;
            else if (c is (>= '\uac00' and <= '\ud7af') or (>= '\u1100' and <= '\u11ff')) hangul++;
            else if (c is (>= '\u4e00' and <= '\u9fff') or (>= '\u3400' and <= '\u4dbf')) han++;
            else if (c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z')) latin++;
        }
        if (kana >= 2) return "ja";
        if (hangul >= 2) return "ko";
        if (han > 0 && han * 3 >= Math.Max(1, latin)) return "zh-Hans";
        return "en";
    }

    public static string ResolveTargetLanguage(string configuredTarget, string text, string sourceCode = "auto")
    {
        if (!configuredTarget.Equals("auto", StringComparison.OrdinalIgnoreCase))
            return configuredTarget;
        string detected = sourceCode.Equals("auto", StringComparison.OrdinalIgnoreCase)
            ? DetectLanguageCode(text)
            : sourceCode;
        return detected.StartsWith("zh", StringComparison.OrdinalIgnoreCase) ? "en" : "zh-Hans";
    }
}

internal static class TranslationProtocol
{
    public static Uri? ValidateCustomEndpoint(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        if (!Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri)) return null;
        if (uri.UserInfo.Length > 0 || uri.Fragment.Length > 0) return null;
        if (uri.Scheme == Uri.UriSchemeHttps) return uri;
        if (uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback) return uri;
        return null;
    }

    public static string GoogleLang(string code) => code switch
    {
        "auto" => "auto",
        "zh-Hans" => "zh-CN",
        "zh-Hant" => "zh-TW",
        _ => code
    };

    public static string BaiduLang(string code) => code switch
    {
        "auto" => "auto",
        "zh-Hans" => "zh",
        "zh-Hant" => "cht",
        "en" => "en",
        "ja" => "jp",
        "ko" => "kor",
        "fr" => "fra",
        "de" => "de",
        "es" => "spa",
        _ => code
    };

    public static string BaiduSignature(string appId, string query, string salt, string secret)
    {
        byte[] hash = MD5.HashData(Encoding.UTF8.GetBytes($"{appId}{query}{salt}{secret}"));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    public static string DeepLLang(string code, bool isTarget) => code switch
    {
        "zh-Hans" => isTarget ? "ZH-HANS" : "ZH",
        "zh-Hant" => isTarget ? "ZH-HANT" : "ZH",
        "en" => isTarget ? "EN-US" : "EN",
        "ja" => "JA",
        "ko" => "KO",
        "fr" => "FR",
        "de" => "DE",
        "es" => "ES",
        _ => code.ToUpperInvariant()
    };

    public static Uri DeepLEndpoint(TranslationApiProfile profile, string apiKey)
    {
        if (ValidateCustomEndpoint(profile.CustomBaseUrl) is { } custom) return custom;
        return new Uri(apiKey.EndsWith(":fx", StringComparison.Ordinal)
            ? "https://api-free.deepl.com/v2/translate"
            : "https://api.deepl.com/v2/translate");
    }

    public static string TencentLang(string code) => code switch
    {
        "auto" => "auto",
        "zh-Hans" => "zh",
        "zh-Hant" => "zh-TW",
        _ => code
    };

    public static string TencentAuthorization(string secretId, string secretKey, byte[] payloadData, long timestamp,
        string host = "tmt.tencentcloudapi.com", string service = "tmt")
    {
        string date = DateTimeOffset.FromUnixTimeSeconds(timestamp).UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        const string contentType = "application/json; charset=utf-8";
        string canonicalHeaders = $"content-type:{contentType}\nhost:{host}\n";
        const string signedHeaders = "content-type;host";
        string hashedPayload = Sha256Hex(payloadData);
        string canonicalRequest = $"POST\n/\n\n{canonicalHeaders}\n{signedHeaders}\n{hashedPayload}";

        const string algorithm = "TC3-HMAC-SHA256";
        string credentialScope = $"{date}/{service}/tc3_request";
        string stringToSign = $"{algorithm}\n{timestamp}\n{credentialScope}\n{Sha256Hex(Encoding.UTF8.GetBytes(canonicalRequest))}";

        byte[] secretDate = HmacSha256(Encoding.UTF8.GetBytes("TC3" + secretKey), Encoding.UTF8.GetBytes(date));
        byte[] secretService = HmacSha256(secretDate, Encoding.UTF8.GetBytes(service));
        byte[] secretSigning = HmacSha256(secretService, Encoding.UTF8.GetBytes("tc3_request"));
        string signature = Convert.ToHexString(HmacSha256(secretSigning, Encoding.UTF8.GetBytes(stringToSign))).ToLowerInvariant();
        return $"{algorithm} Credential={secretId}/{credentialScope}, SignedHeaders={signedHeaders}, Signature={signature}";
    }

    public static string YoudaoLang(string code) => code switch
    {
        "auto" => "auto",
        "zh-Hans" => "zh-CHS",
        "zh-Hant" => "zh-CHT",
        _ => code
    };

    public static string YoudaoTruncateInput(string query) =>
        query.Length <= 20 ? query : $"{query[..10]}{query.Length}{query[^10..]}";

    public static string YoudaoSignature(string appKey, string query, string salt, string curtime, string appSecret) =>
        Sha256Hex(Encoding.UTF8.GetBytes($"{appKey}{YoudaoTruncateInput(query)}{salt}{curtime}{appSecret}"));

    public static string Sha256Hex(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    public static byte[] HmacSha256(byte[] key, byte[] message)
    {
        using var hmac = new HMACSHA256(key);
        return hmac.ComputeHash(message);
    }
}

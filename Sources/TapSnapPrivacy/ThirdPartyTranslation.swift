import CryptoKit
import Foundation

public enum TranslationAPIProvider: String, CaseIterable, Codable, Hashable, Sendable {
    case google
    case baidu
    case deepl
    case azure
    case tencent
    case youdao

    public var title: String {
        switch self {
        case .google: return "Google 翻译"
        case .baidu: return "百度翻译"
        case .deepl: return "DeepL"
        case .azure: return "微软翻译 (Azure)"
        case .tencent: return "腾讯翻译君"
        case .youdao: return "有道翻译"
        }
    }

    public var shortTitle: String {
        switch self {
        case .google: return "Google 翻译"
        case .baidu: return "百度翻译"
        case .deepl: return "DeepL"
        case .azure: return "微软翻译"
        case .tencent: return "腾讯翻译"
        case .youdao: return "有道翻译"
        }
    }

    public var requiresAppID: Bool {
        switch self {
        case .baidu, .tencent, .youdao: return true
        case .google, .deepl, .azure: return false
        }
    }

    public var requiresSecret: Bool {
        self != .google
    }

    public var supportsRegion: Bool {
        self == .azure || self == .tencent
    }

    public var supportsCustomEndpoint: Bool {
        self == .google || self == .deepl || self == .azure
    }

    public var appIDLabel: String {
        switch self {
        case .baidu: return "App ID"
        case .tencent: return "SecretId"
        case .youdao: return "应用 ID"
        default: return ""
        }
    }

    public var secretLabel: String {
        switch self {
        case .google: return "API Key（可选）"
        case .baidu: return "密钥"
        case .deepl: return "Auth Key"
        case .azure: return "API Key"
        case .tencent: return "SecretKey"
        case .youdao: return "应用密钥"
        }
    }

    public var defaultRegion: String {
        switch self {
        case .tencent: return "ap-beijing"
        default: return ""
        }
    }

    public var regionPlaceholder: String {
        switch self {
        case .azure: return "可选，如 eastasia"
        case .tencent: return "ap-beijing"
        default: return ""
        }
    }

    public var endpointPlaceholder: String {
        switch self {
        case .google: return "可选，支持自定义反代地址"
        case .deepl: return "留空自动区分 Free / Pro"
        case .azure: return "留空使用官方全球端点"
        default: return ""
        }
    }

    public var hint: String {
        switch self {
        case .google:
            return "留空 API Key 时使用 Google 快捷免密通道；填入官方 Cloud Translation API Key 更稳定且支持单次批量翻译。"
        case .baidu:
            return "国内直连速度快，支持多段合并请求。在百度翻译开放平台获取 App ID 和密钥，密钥仅保存在本机。"
        case .deepl:
            return "译文质量高，原生支持批量翻译。以 :fx 结尾的 Key 自动使用 Free 端点，其余使用 Pro 端点。"
        case .azure:
            return "微软 Azure Translator，原生批量翻译。使用区域性资源时请填写区域（如 eastasia），全局资源可留空。"
        case .tencent:
            return "腾讯云机器翻译 TMT，国内直连稳定，支持原生批量翻译接口。请填入访问管理的 SecretId 与 SecretKey。"
        case .youdao:
            return "有道智云文本翻译（v3），国内直连稳定。请在控制台创建文本翻译应用后填入应用 ID 与应用密钥。"
        }
    }
}

public struct TranslationAPIConfiguration: Codable, Hashable, Sendable {
    public var provider: TranslationAPIProvider
    public var appID: String
    public var region: String
    public var customBaseURL: String

    public init(
        provider: TranslationAPIProvider,
        appID: String = "",
        region: String = "",
        customBaseURL: String = ""
    ) {
        self.provider = provider
        self.appID = appID
        self.region = region.isEmpty ? provider.defaultRegion : region
        self.customBaseURL = customBaseURL
    }

    public var trimmedAppID: String {
        appID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedRegion: String {
        let value = region.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.defaultRegion : value
    }

    public var trimmedCustomBaseURL: String {
        customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var validatedCustomEndpoint: URL? {
        guard !trimmedCustomBaseURL.isEmpty else { return nil }
        guard let url = URL(string: trimmedCustomBaseURL),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            return nil
        }
        let scheme = parts.scheme?.lowercased()
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
        guard scheme == "https" || (loopbackHosts.contains(host) && scheme == "http") else {
            return nil
        }
        return url
    }

    /// 凭据文件定位标识（只用于本地密钥文件隔离，不泄露真实密钥）。
    public var credentialScope: String {
        let hostTag = trimmedCustomBaseURL.isEmpty ? "default" : trimmedCustomBaseURL
        return "translation-api:\(provider.rawValue):\(hostTag)"
    }

    public var isFormValid: Bool {
        if provider.requiresAppID && trimmedAppID.isEmpty { return false }
        if !trimmedCustomBaseURL.isEmpty && validatedCustomEndpoint == nil { return false }
        return true
    }
}

public enum TranslationAPIError: Error, LocalizedError, Equatable {
    case configuration(String)
    case missingCredential(String)
    case authorization(String)
    case rateLimited(String)
    case network(String)
    case timeout
    case serviceError(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .configuration(let msg),
             .missingCredential(let msg),
             .authorization(let msg),
             .rateLimited(let msg),
             .network(let msg),
             .serviceError(let msg),
             .invalidResponse(let msg):
            return msg
        case .timeout:
            return "翻译服务响应超时，请稍后重试或切换其他引擎。"
        }
    }
}

public enum ThirdPartyTranslation {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    /// 在用户拖选截图期间提前建立 DNS + TCP/TLS 连接池，消除首次翻译握手冷启动延迟。
    public static func prewarm(configuration: TranslationAPIConfiguration) {
        let targetURL: URL?
        if let custom = configuration.validatedCustomEndpoint {
            targetURL = custom
        } else {
            switch configuration.provider {
            case .google:
                targetURL = URL(string: "https://translate.googleapis.com/generate_204")
            case .deepl:
                targetURL = URL(string: "https://api-free.deepl.com")
            case .azure:
                targetURL = URL(string: "https://api.cognitive.microsofttranslator.com")
            case .baidu:
                targetURL = URL(string: "https://fanyi-api.baidu.com")
            case .tencent:
                targetURL = URL(string: "https://tmt.tencentcloudapi.com")
            case .youdao:
                targetURL = URL(string: "https://openapi.youdao.com")
            }
        }
        guard let url = targetURL else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.httpMethod = "HEAD"
        req.assumesHTTP3Capable = false
        session.dataTask(with: req) { _, _, _ in }.resume()
    }

    public static func defaultTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            // 禁用 HTTP/3 QUIC 探测，避免代理环境下 UDP 443 被丢弃导致的 2~5 秒首次静默卡顿。
            var tuned = request
            tuned.assumesHTTP3Capable = false
            let (data, response) = try await session.data(for: tuned)
            guard let http = response as? HTTPURLResponse else {
                throw TranslationAPIError.invalidResponse("翻译服务返回了非 HTTP 响应。")
            }
            return (data, http)
        } catch let error as TranslationAPIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw TranslationAPIError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationAPIError.network("无法连接翻译服务，请检查网络或代理设置。")
        }
    }

    public static func translate(
        _ text: String,
        source: String,
        target: String,
        configuration: TranslationAPIConfiguration,
        secret: String?,
        transport: @escaping Transport = { try await defaultTransport($0) }
    ) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationAPIError.configuration("待翻译文字为空。") }
        let results = try await translateBatch(
            [trimmed],
            source: source,
            target: target,
            configuration: configuration,
            secret: secret,
            transport: transport
        )
        guard let first = results.first, !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationAPIError.invalidResponse("翻译服务返回了空译文。")
        }
        return first
    }

    /// 批量翻译：支持原生批量的引擎（Google v2 / DeepL / Azure / 腾讯 / 百度单行合批）将合并为单次请求。
    public static func translateBatch(
        _ texts: [String],
        source: String,
        target: String,
        configuration: TranslationAPIConfiguration,
        secret: String?,
        transport: @escaping Transport = { try await defaultTransport($0) }
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard !texts.isEmpty else { return [] }
        guard configuration.isFormValid else {
            throw TranslationAPIError.configuration("请检查 \(configuration.provider.title) 配置项是否填写完整。")
        }

        let cleanedSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSecret = (cleanedSecret?.isEmpty == false) ? cleanedSecret : nil
        if configuration.provider.requiresSecret && resolvedSecret == nil {
            throw TranslationAPIError.missingCredential("请在翻译服务设置中填写 \(configuration.provider.title) 的 \(configuration.provider.secretLabel)。")
        }

        switch configuration.provider {
        case .google:
            if let key = resolvedSecret {
                return try await translateGoogleOfficial(
                    texts, source: source, target: target,
                    configuration: configuration, apiKey: key, transport: transport
                )
            } else {
                return try await translateGoogleFree(
                    texts, source: source, target: target,
                    configuration: configuration, transport: transport
                )
            }
        case .baidu:
            return try await translateBaidu(
                texts, source: source, target: target,
                configuration: configuration, secret: resolvedSecret!, transport: transport
            )
        case .deepl:
            return try await translateDeepL(
                texts, source: source, target: target,
                configuration: configuration, apiKey: resolvedSecret!, transport: transport
            )
        case .azure:
            return try await translateAzure(
                texts, source: source, target: target,
                configuration: configuration, apiKey: resolvedSecret!, transport: transport
            )
        case .tencent:
            return try await translateTencent(
                texts, source: source, target: target,
                configuration: configuration, secretKey: resolvedSecret!, transport: transport
            )
        case .youdao:
            return try await translateYoudao(
                texts, source: source, target: target,
                configuration: configuration, appSecret: resolvedSecret!, transport: transport
            )
        }
    }

    // MARK: - 1. Google 翻译（免 Key 快捷通道 + 官方 v2 API）

    private static func googleLang(_ code: String) -> String {
        switch code {
        case "auto": return "auto"
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        default: return code
        }
    }

    private static func translateGoogleFree(
        _ texts: [String],
        source: String,
        target: String,
        configuration: TranslationAPIConfiguration,
        transport: @escaping Transport
    ) async throws -> [String] {
        let baseURL = configuration.validatedCustomEndpoint
            ?? URL(string: "https://translate.googleapis.com/translate_a/single")!
        let sl = googleLang(source)
        let tl = googleLang(target)

        // 当每段本身不含换行且总长不大时，尝试单次请求加速；否则安全逐段请求。
        let canMerge = texts.count > 1
            && texts.allSatisfy { !$0.contains("\n") }
            && texts.reduce(0) { $0 + $1.count } < 2500
        if canMerge {
            let joined = texts.joined(separator: "\n")
            let output = try await requestGoogleFreeSingle(joined, sl: sl, tl: tl, baseURL: baseURL, transport: transport)
            let parts = output.components(separatedBy: "\n")
            if parts.count == texts.count {
                return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }

        var results = Array(repeating: "", count: texts.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, item) in texts.enumerated() {
                group.addTask {
                    let translated = try await requestGoogleFreeSingle(item, sl: sl, tl: tl, baseURL: baseURL, transport: transport)
                    return (index, translated)
                }
            }
            for try await (index, translated) in group {
                results[index] = translated
            }
        }
        return results
    }

    private static func requestGoogleFreeSingle(
        _ text: String,
        sl: String,
        tl: String,
        baseURL: URL,
        transport: @escaping Transport
    ) async throws -> String {
        try Task.checkCancellation()
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TranslationAPIError.configuration("Google 翻译地址无效。")
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: sl),
            URLQueryItem(name: "tl", value: tl),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components.url else {
            throw TranslationAPIError.configuration("无法构造 Google 翻译请求地址。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("TapSnap/1.0", forHTTPHeaderField: "User-Agent")

        let (data, http) = try await transport(request)
        try Task.checkCancellation()
        try validateHTTPStatus(http, providerName: "Google 翻译")

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any] else {
            throw TranslationAPIError.invalidResponse("无法解析 Google 翻译返回的数据。")
        }
        let combined = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
        let cleaned = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw TranslationAPIError.invalidResponse("Google 翻译返回了空译文。")
        }
        return cleaned
    }

    private static func translateGoogleOfficial(
        _ texts: [String],
        source: String,
        target: String,
        configuration: TranslationAPIConfiguration,
        apiKey: String,
        transport: @escaping Transport
    ) async throws -> [String] {
        let url = configuration.validatedCustomEndpoint
            ?? URL(string: "https://translation.googleapis.com/language/translate/v2")!
        var payload: [String: Any] = [
            "q": texts,
            "target": googleLang(target),
            "format": "text",
        ]
        if source != "auto" {
            payload["source"] = googleLang(source)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, http) = try await transport(request)
        try Task.checkCancellation()
        try validateHTTPStatus(http, providerName: "Google 翻译")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = json["data"] as? [String: Any],
              let list = dataNode["translations"] as? [[String: Any]],
              list.count == texts.count else {
            throw TranslationAPIError.invalidResponse("无法解析 Google Cloud Translation 返回结果。")
        }
        return list.map { ($0["translatedText"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - 2. 百度翻译开放平台（MD5 签名 + 单次合并批量）

    static func baiduLang(_ code: String) -> String {
        switch code {
        case "auto": return "auto"
        case "zh-Hans": return "zh"
        case "zh-Hant": return "cht"
        case "en": return "en"
        case "ja": return "jp"
        case "ko": return "kor"
        case "fr": return "fra"
        case "de": return "de"
        case "es": return "spa"
        default: return code
        }
    }

    static func baiduSignature(appID: String, query: String, salt: String, secret: String) -> String {
        let digest = Insecure.MD5.hash(data: Data("\(appID)\(query)\(salt)\(secret)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func translateBaidu(
        _ texts: [String],
        source: String,
        target: String,
        configuration: TranslationAPIConfiguration,
        secret: String,
        transport: @escaping Transport
    ) async throws -> [String] {
        let canMerge = texts.count > 1
            && texts.allSatisfy { !$0.contains("\n") }
            && texts.reduce(0) { $0 + $1.utf8.count } < 5000
        if canMerge {
            let merged = try await requestBaidu(
                texts.joined(separator: "\n"),
                source: source, target: target,
                appID: configuration.trimmedAppID, secret: secret, transport: transport
            )
            if merged.count == texts.count {
                return merged
            }
        }

        // 顺序执行以契合百度免费版低 QPS 限流，避免触发 54003
        var results: [String] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            let lines = try await requestBaidu(
                text, source: source, target: target,
                appID: configuration.trimmedAppID, secret: secret, transport: transport
            )
            results.append(lines.joined(separator: "\n"))
        }
        return results
    }

    private static func requestBaidu(
        _ query: String,
        source: String,
        target: String,
        appID: String,
        secret: String,
        transport: @escaping Transport
    ) async throws -> [String] {
        try Task.checkCancellation()
        let salt = String(Int.random(in: 100_000...999_999_999))
        let sign = baiduSignature(appID: appID, query: query, salt: salt, secret: secret)
        let url = URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedBody([
            ("q", query),
            ("from", baiduLang(source)),
            ("to", baiduLang(target)),
            ("appid", appID),
            ("salt", salt),
            ("sign", sign),
        ])

        let (data, http) = try await transport(request)
        try Task.checkCancellation()
        try validateHTTPStatus(http, providerName: "百度翻译")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationAPIError.invalidResponse("无法解析百度翻译响应。")
        }
        if let code = json["error_code"] as? String, code != "52000" {
            throw mapBaiduError(code: code, message: json["error_msg"] as? String)
        }
        guard let list = json["trans_result"] as? [[String: Any]], !list.isEmpty else {
            throw TranslationAPIError.invalidResponse("百度翻译未返回有效译文。")
        }
        return list.map { ($0["dst"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func mapBaiduError(code: String, message: String?) -> TranslationAPIError {
        switch code {
        case "54001": return .authorization("百度翻译签名错误，请核对 App ID 与密钥。")
        case "54003": return .rateLimited("百度翻译请求频率过高，请稍后重试。")
        case "54004": return .serviceError("百度翻译账户余额不足或本月免费额度已用完。")
        case "58000": return .authorization("百度翻译客户端 IP 不在白名单中。")
        case "58001": return .serviceError("百度翻译不支持此目标语言。")
        case "52001": return .timeout
        default: return .serviceError("百度翻译错误 (\(code))：\(message ?? "请检查配置")")
        }
    }

    // MARK: - 3. DeepL（原生批量 + 自动识别 Free/Pro）

    static func deepLLang(_ code: String, isTarget: Bool) -> String {
        switch code {
        case "zh-Hans": return isTarget ? "ZH-HANS" : "ZH"
        case "zh-Hant": return isTarget ? "ZH-HANT" : "ZH"
        case "en": return isTarget ? "EN-US" : "EN"
        case "ja": return "JA"
        case "ko": return "KO"
        case "fr": return "FR"
        case "de": return "DE"
        case "es": return "ES"
        default: return code.uppercased()
        }
    }

    static func deepLEndpoint(configuration: TranslationAPIConfiguration, apiKey: String) -> URL {
        if let custom = configuration.validatedCustomEndpoint {
            return custom
        }
        let isFree = apiKey.hasSuffix(":fx")
        return URL(string: isFree ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate")!
    }

    private static func translateDeepL(
        _ texts: [String],
        source: String,
        target: String,
        configuration: TranslationAPIConfiguration,
        apiKey: String,
        transport: @escaping Transport
    ) async throws -> [String] {
        let url = deepLEndpoint(configuration: configuration, apiKey: apiKey)
        var payload: [String: Any] = [
            "text": texts,
            "target_lang": deepLLang(target, isTarget: true),
        ]
        if source != "auto" {
            payload["source_lang"] = deepLLang(source, isTarget: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, http) = try await transport(request)
        try Task.checkCancellation()
        if http.statusCode == 456 {
            throw TranslationAPIError.serviceError("DeepL 翻译额度已用尽。")
        }
        try validateHTTPStatus(http, providerName: "DeepL")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["translations"] as? [[String: Any]],
              list.count == texts.count else {
            throw TranslationAPIError.invalidResponse("无法解析 DeepL 返回结果。")
        }
        return list.map { ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - 4. 微软翻译 Azure Translator（原生批量）

    private static func translateAzure(
        _ texts: [String],
        source: String,
        target: String,
        configuration: TranslationAPIConfiguration,
        apiKey: String,
        transport: @escaping Transport
    ) async throws -> [String] {
        let baseURL = configuration.validatedCustomEndpoint
            ?? URL(string: "https://api.cognitive.microsofttranslator.com/translate")!
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TranslationAPIError.configuration("微软翻译地址无效。")
        }
        var queryItems = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "to", value: target),
        ]
        if source != "auto" {
            queryItems.append(URLQueryItem(name: "from", value: source))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw TranslationAPIError.configuration("无法构造微软翻译请求地址。")
        }

        let body = texts.map { ["Text": $0] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        let region = configuration.trimmedRegion
        if !region.isEmpty {
            request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await transport(request)
        try Task.checkCancellation()
        try validateHTTPStatus(http, providerName: "微软翻译")

        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              list.count == texts.count else {
            throw TranslationAPIError.invalidResponse("无法解析微软翻译返回结果。")
        }
        return list.map { item in
            let first = (item["translations"] as? [[String: Any]])?.first
            return (first?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - 5. 腾讯翻译君 TMT（TC3-HMAC-SHA256 + 原生批量 TextTranslateBatch）

    static func tencentLang(_ code: String) -> String {
        switch code {
        case "auto": return "auto"
        case "zh-Hans": return "zh"
        case "zh-Hant": return "zh-TW"
        default: return code
        }
    }

    static func tencentAuthorization(
        secretId: String,
        secretKey: String,
        payloadData: Data,
        timestamp: Int,
        host: String = "tmt.tencentcloudapi.com",
        service: String = "tmt"
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        let contentType = "application/json; charset=utf-8"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"
        let signedHeaders = "content-type;host"
        let hashedPayload = sha256Hex(payloadData)
        let canonicalRequest = "POST\n/\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(hashedPayload)"

        let algorithm = "TC3-HMAC-SHA256"
        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = "\(algorithm)\n\(timestamp)\n\(credentialScope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"

        let secretDate = hmacSHA256(key: Data("TC3\(secretKey)".utf8), message: Data(date.utf8))
        let secretService = hmacSHA256(key: secretDate, message: Data(service.utf8))
        let secretSigning = hmacSHA256(key: secretService, message: Data("tc3_request".utf8))
        let signature = hmacSHA256(key: secretSigning, message: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        return "\(algorithm) Credential=\(secretId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private static func translateTencent(
        _ texts: [String],
        source: String,
        target: String,
        configuration: TranslationAPIConfiguration,
        secretKey: String,
        transport: @escaping Transport
    ) async throws -> [String] {
        let host = "tmt.tencentcloudapi.com"
        let url = URL(string: "https://\(host)")!
        let isBatch = texts.count > 1
        let action = isBatch ? "TextTranslateBatch" : "TextTranslate"

        let payload: [String: Any] = isBatch
            ? [
                "Source": tencentLang(source),
                "Target": tencentLang(target),
                "ProjectId": 0,
                "SourceTextList": texts,
            ]
            : [
                "SourceText": texts[0],
                "Source": tencentLang(source),
                "Target": tencentLang(target),
                "ProjectId": 0,
            ]

        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let timestamp = Int(Date().timeIntervalSince1970)
        let authorization = tencentAuthorization(
            secretId: configuration.trimmedAppID,
            secretKey: secretKey,
            payloadData: payloadData,
            timestamp: timestamp,
            host: host
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue("2018-03-21", forHTTPHeaderField: "X-TC-Version")
        request.setValue(configuration.trimmedRegion, forHTTPHeaderField: "X-TC-Region")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = payloadData

        let (data, http) = try await transport(request)
        try Task.checkCancellation()
        try validateHTTPStatus(http, providerName: "腾讯翻译君")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["Response"] as? [String: Any] else {
            throw TranslationAPIError.invalidResponse("无法解析腾讯翻译君返回结果。")
        }
        if let err = response["Error"] as? [String: Any] {
            let code = err["Code"] as? String ?? ""
            let msg = err["Message"] as? String ?? "请求被拒绝"
            if code.hasPrefix("AuthFailure") {
                throw TranslationAPIError.authorization("腾讯翻译君鉴权失败：\(msg)")
            }
            if code.contains("RequestLimitExceeded") {
                throw TranslationAPIError.rateLimited("腾讯翻译君请求超频，请稍后重试。")
            }
            throw TranslationAPIError.serviceError("腾讯翻译君错误：\(msg)")
        }
        if isBatch {
            guard let list = response["TargetTextList"] as? [String], list.count == texts.count else {
                throw TranslationAPIError.invalidResponse("腾讯翻译君批量返回数量不匹配。")
            }
            return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            guard let targetText = response["TargetText"] as? String else {
                throw TranslationAPIError.invalidResponse("腾讯翻译君未返回有效译文。")
            }
            return [targetText.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
    }

    // MARK: - 6. 有道智云翻译（v3 SHA-256 签名）

    static func youdaoLang(_ code: String) -> String {
        switch code {
        case "auto": return "auto"
        case "zh-Hans": return "zh-CHS"
        case "zh-Hant": return "zh-CHT"
        default: return code
        }
    }

    static func youdaoTruncateInput(_ query: String) -> String {
        let chars = Array(query)
        guard chars.count > 20 else { return query }
        return "\(String(chars.prefix(10)))\(chars.count)\(String(chars.suffix(10)))"
    }

    static func youdaoSignature(appKey: String, query: String, salt: String, curtime: String, appSecret: String) -> String {
        let input = youdaoTruncateInput(query)
        return sha256Hex(Data("\(appKey)\(input)\(salt)\(curtime)\(appSecret)".utf8))
    }

    private static func translateYoudao(
        _ texts: [String],
        source: String,
        target: String,
        configuration: TranslationAPIConfiguration,
        appSecret: String,
        transport: @escaping Transport
    ) async throws -> [String] {
        var results = Array(repeating: "", count: texts.count)
        let appKey = configuration.trimmedAppID
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, item) in texts.enumerated() {
                group.addTask {
                    let translated = try await requestYoudaoSingle(
                        item, source: source, target: target,
                        appKey: appKey, appSecret: appSecret, transport: transport
                    )
                    return (index, translated)
                }
            }
            for try await (index, translated) in group {
                results[index] = translated
            }
        }
        return results
    }

    private static func requestYoudaoSingle(
        _ query: String,
        source: String,
        target: String,
        appKey: String,
        appSecret: String,
        transport: @escaping Transport
    ) async throws -> String {
        try Task.checkCancellation()
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let sign = youdaoSignature(appKey: appKey, query: query, salt: salt, curtime: curtime, appSecret: appSecret)
        let url = URL(string: "https://openapi.youdao.com/api")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedBody([
            ("q", query),
            ("from", youdaoLang(source)),
            ("to", youdaoLang(target)),
            ("appKey", appKey),
            ("salt", salt),
            ("sign", sign),
            ("signType", "v3"),
            ("curtime", curtime),
        ])

        let (data, http) = try await transport(request)
        try Task.checkCancellation()
        try validateHTTPStatus(http, providerName: "有道翻译")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationAPIError.invalidResponse("无法解析有道翻译响应。")
        }
        let code = json["errorCode"] as? String ?? ""
        guard code == "0" else {
            throw mapYoudaoError(code: code)
        }
        guard let list = json["translation"] as? [String], !list.isEmpty else {
            throw TranslationAPIError.invalidResponse("有道翻译返回了空译文。")
        }
        return list.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mapYoudaoError(code: String) -> TranslationAPIError {
        switch code {
        case "108", "202": return .authorization("有道翻译鉴权失败，请检查应用 ID 与应用密钥。")
        case "401": return .serviceError("有道翻译账户欠费或额度不足。")
        case "411": return .rateLimited("有道翻译访问频率受限，请稍后重试。")
        case "102": return .serviceError("有道翻译不支持当前语言类型。")
        default: return .serviceError("有道翻译错误（错误码 \(code)）。")
        }
    }

    // MARK: - 通用工具

    private static func validateHTTPStatus(_ response: HTTPURLResponse, providerName: String) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw TranslationAPIError.authorization("\(providerName) 鉴权失败，请核对 API Key 或权限配置。")
        case 429:
            throw TranslationAPIError.rateLimited("\(providerName) 请求频率超限，请稍后重试。")
        case 408, 504:
            throw TranslationAPIError.timeout
        default:
            throw TranslationAPIError.serviceError("\(providerName) 返回 HTTP \(response.statusCode)。")
        }
    }

    private static func formEncodedBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, message: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(code)
    }
}

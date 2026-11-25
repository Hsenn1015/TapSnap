import Foundation
import TapSnapConfig
import TapSnapPrivacy

private actor QuickTranslationMemoryCache {
    static let shared = QuickTranslationMemoryCache()
    private var storage: [String: String] = [:]
    private var order: [String] = []
    private let limit = 128

    func get(_ key: String) -> String? { storage[key] }

    func set(_ value: String, for key: String) {
        if storage[key] == nil {
            order.append(key)
            if order.count > limit, let oldest = order.first {
                order.removeFirst()
                storage.removeValue(forKey: oldest)
            }
        }
        storage[key] = value
    }
}

enum TranslationModelClient {
    /// 提前预热当前配置翻译服务的 DNS 与 TLS 连接（在用户框选截图期间并发执行）。
    static func prewarm(config: ConfigStore) {
        let settings = config.settings.translation
        if settings.provider == .api, let api = settings.apiConfiguration {
            ThirdPartyTranslation.prewarm(configuration: api)
        } else if (settings.provider == .local || settings.provider == .online),
                  let model = settings.modelConfiguration {
            TextModelTranslation.prewarm(model: model)
        }
    }

    private static func cacheKey(text: String, source: String, target: String, config: ConfigStore) -> String {
        let t = config.settings.translation
        let engineTag: String
        switch t.provider {
        case .api:
            engineTag = "api:\(t.apiProvider.rawValue):\(t.apiConfiguration?.trimmedCustomBaseURL ?? "")"
        case .local:
            engineTag = "local:\(t.modelConfiguration?.baseURL ?? ""):\(t.modelConfiguration?.model ?? "")"
        case .online:
            engineTag = "online:\(t.onlineProvider.rawValue):\(t.modelConfiguration?.model ?? "")"
        default:
            engineTag = "other"
        }
        return "\(engineTag)|\(source)|\(target)|\(text)"
    }

    static func translate(_ text: String, source: String, target: String, config: ConfigStore) async throws -> String {
        let keyTag = cacheKey(text: text, source: source, target: target, config: config)
        if let cached = await QuickTranslationMemoryCache.shared.get(keyTag) {
            return cached
        }
        do {
            let output: String
            if config.settings.translation.provider == .api {
                guard let api = config.settings.translation.apiConfiguration else {
                    throw TranslationAPIError.configuration("请先在翻译服务设置中配置翻译 API。")
                }
                let secret = try config.translationKeys.read(for: api)
                output = try await ThirdPartyTranslation.translate(
                    text,
                    source: source,
                    target: target,
                    configuration: api,
                    secret: secret
                )
            } else {
                guard let model = config.settings.translation.modelConfiguration else { throw PrivacyAIError.configuration }
                let key = try config.translationKeys.read(for: model)
                output = try await TextModelTranslation.translate(text, source: source, target: target, model: model, key: key)
            }
            await QuickTranslationMemoryCache.shared.set(output, for: keyTag)
            return output
        } catch let error as PrivacyAIError {
            throw ServiceError(error)
        }
    }

    /// 优先使用 SSE 流式输出（在线/本机大模型首个词秒出）；API 引擎与命中缓存时立即单次吐出完整译文。
    static func translateStream(_ text: String, source: String, target: String, config: ConfigStore) -> AsyncThrowingStream<String, Error> {
        let keyTag = cacheKey(text: text, source: source, target: target, config: config)
        let provider = config.settings.translation.provider
        let apiConfig = config.settings.translation.apiConfiguration
        let modelConfig = config.settings.translation.modelConfiguration
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let cached = await QuickTranslationMemoryCache.shared.get(keyTag) {
                    continuation.yield(cached)
                    continuation.finish()
                    return
                }
                do {
                    if provider == .api {
                        guard let api = apiConfig else {
                            throw TranslationAPIError.configuration("请先在翻译服务设置中配置翻译 API。")
                        }
                        let secret = try config.translationKeys.read(for: api)
                        let result = try await ThirdPartyTranslation.translate(
                            text,
                            source: source,
                            target: target,
                            configuration: api,
                            secret: secret
                        )
                        await QuickTranslationMemoryCache.shared.set(result, for: keyTag)
                        continuation.yield(result)
                        continuation.finish()
                        return
                    }

                    guard let model = modelConfig else { throw PrivacyAIError.configuration }
                    let key = try config.translationKeys.read(for: model)
                    var accumulated = ""
                    let stream = TextModelTranslation.translateStream(
                        text,
                        source: source,
                        target: target,
                        model: model,
                        key: key
                    )
                    for try await delta in stream {
                        try Task.checkCancellation()
                        accumulated.append(delta)
                        continuation.yield(accumulated)
                    }
                    let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !finalText.isEmpty else { throw PrivacyAIError.response }
                    await QuickTranslationMemoryCache.shared.set(finalText, for: keyTag)
                    continuation.yield(finalText)
                    continuation.finish()
                } catch let error as PrivacyAIError {
                    continuation.finish(throwing: ServiceError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func translateBatch(_ texts: [String], source: String, target: String, config: ConfigStore) async throws -> [String] {
        do {
            guard config.settings.translation.provider == .api,
                  let api = config.settings.translation.apiConfiguration else {
                throw TranslationAPIError.configuration("当前服务不支持单次批量翻译。")
            }
            let secret = try config.translationKeys.read(for: api)
            return try await ThirdPartyTranslation.translateBatch(
                texts,
                source: source,
                target: target,
                configuration: api,
                secret: secret
            )
        } catch let error as PrivacyAIError {
            throw ServiceError(error)
        }
    }

    struct ServiceError: LocalizedError {
        let reason: PrivacyAIError

        init(_ reason: PrivacyAIError) { self.reason = reason }

        var errorDescription: String? {
            switch reason {
            case .missingKey: return "请在翻译服务设置中填写 API Key。"
            case .timeout: return "翻译服务响应超时，请重试或切换服务。"
            case .response: return "没有收到可用译文，请检查模型名称和服务状态。"
            default: return reason.message
            }
        }
    }
}

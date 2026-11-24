import Foundation
import TapSnapConfig
import TapSnapPrivacy

enum TranslationModelClient {
    static func translate(_ text: String, source: String, target: String, config: ConfigStore) async throws -> String {
        do {
            if config.settings.translation.provider == .api {
                guard let api = config.settings.translation.apiConfiguration else {
                    throw TranslationAPIError.configuration("请先在翻译服务设置中配置翻译 API。")
                }
                let secret = try config.translationKeys.read(for: api)
                return try await ThirdPartyTranslation.translate(
                    text,
                    source: source,
                    target: target,
                    configuration: api,
                    secret: secret
                )
            }
            guard let model = config.settings.translation.modelConfiguration else { throw PrivacyAIError.configuration }
            let key = try config.translationKeys.read(for: model)
            return try await TextModelTranslation.translate(text, source: source, target: target, model: model, key: key)
        } catch let error as PrivacyAIError {
            throw ServiceError(error)
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

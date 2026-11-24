import Foundation
import TapSnapConfig
@testable import TapSnapPrivacy
import XCTest

final class ScreenshotTranslationServiceTests: XCTestCase {
    func testOldSettingsAwaitServiceChoiceAndKeepIndependentModelProfilesAndCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try JSONEncoder().encode(Settings.withDefaultShortcuts()).write(to: file)
        let store = ConfigStore(fileURL: file)
        XCTAssertNil(store.settings.translation.provider)
        XCTAssertEqual(store.settings.translation.targetLanguage, "zh-Hans")

        var local = PrivacyAIConfiguration(provider: .local)
        local.model = "demo-local-model"
        let cloud = PrivacyAIConfiguration(provider: .qwen)
        try store.translationKeys.save("mock-translation-key", for: cloud)
        store.update {
            $0.translation.saveModel(local)
            $0.translation.provider = .online
            $0.translation.onlineProvider = .qwen
            $0.translation.targetLanguage = "ja"
        }
        let reopened = ConfigStore(fileURL: file)
        XCTAssertEqual(reopened.settings.translation.modelConfiguration, cloud)
        XCTAssertEqual(reopened.settings.translation.targetLanguage, "ja")
        XCTAssertEqual(try reopened.translationKeys.read(for: cloud), "mock-translation-key")
        XCTAssertNil(try reopened.privacyAIKeys.read(for: cloud))
        var otherEndpoint = cloud
        otherEndpoint.baseURL = "https://model.example.invalid/v1"
        XCTAssertNil(try reopened.translationKeys.read(for: otherEndpoint))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("mock-translation-key"))
        reopened.update { $0.translation.provider = .local }
        XCTAssertEqual(reopened.settings.translation.modelConfiguration, local)
    }

    func testCompatibleModelReceivesOnlySelectionAndReturnsPlainText() async throws {
        let cloud = PrivacyAIConfiguration(provider: .deepSeek)
        let output = try await TextModelTranslation.translate("session has expired", source: "auto", target: "zh-Hans",
                                                             model: cloud, key: "mock-key") { request in
            XCTAssertEqual(request.url, cloud.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock-key")
            let data = try XCTUnwrap(request.httpBody)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages.last, ["role": "user", "content": "session has expired"])
            XCTAssertTrue(messages.first?["content"]?.contains("zh-Hans") == true)
            XCTAssertNil(body["response_format"])
            return Data(#"{"choices":[{"message":{"content":"会话已过期"}}]}"#.utf8)
        }
        XCTAssertEqual(output, "会话已过期")
    }

    func testLocalAndOnlineDestinationsAreSeparatedBeforeSending() async throws {
        var local = PrivacyAIConfiguration(provider: .local)
        local.model = "demo"
        local.baseURL = "https://outside.example.invalid"
        var online = PrivacyAIConfiguration(provider: .custom)
        online.model = "demo"
        online.baseURL = "http://127.0.0.1:11434/v1"
        var hostedAlias = PrivacyAIConfiguration(provider: .local)
        hostedAlias.model = "demo:cloud"
        for model in [local, online, hostedAlias] {
            do {
                _ = try await TextModelTranslation.translate("Hello", source: "en", target: "zh-Hans",
                                                            model: model, key: nil) { _ in
                    XCTFail("Unexpected request for a mismatched service mode")
                    return Data()
                }
                XCTFail("Unexpected success")
            } catch PrivacyAIError.configuration {}
        }
    }

    func testEmptyModelResponseCannotBecomeATranslatedResult() async throws {
        var local = PrivacyAIConfiguration(provider: .local)
        local.model = "demo"
        do {
            _ = try await TextModelTranslation.translate("Hello", source: "en", target: "zh-Hans",
                                                        model: local, key: nil) { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return Data(#"{"choices":[{"message":{"content":" "}}]}"#.utf8)
            }
            XCTFail("Empty model output must be reported")
        } catch PrivacyAIError.response {}
    }

    func testIncompleteModelOutputIsNeverDisplayedAsAFinishedTranslation() async throws {
        var model = PrivacyAIConfiguration(provider: .custom)
        model.baseURL = "https://example.invalid/v1"
        model.model = "demo"
        do {
            _ = try await TextModelTranslation.translate("My session expired", source: "en", target: "zh-Hans",
                                                        model: model, key: nil) { _ in
                Data(#"{"choices":[{"message":{"content":"我的会"},"finish_reason":"length"}]}"#.utf8)
            }
            XCTFail("Partial translation must be reported")
        } catch PrivacyAIError.response {}
    }

    func testResultArrivingAfterCancellationIsDiscarded() async throws {
        let task = Task {
            try await TextModelTranslation.translate("old selection", source: "auto", target: "zh-Hans",
                                                     model: PrivacyAIConfiguration(provider: .qwen), key: "fixture") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Data(#"{"choices":[{"message":{"content":"上次选区"}}]}"#.utf8)
            }
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled request returned stale text")
        } catch is CancellationError {}
    }

    // MARK: - Third-party Translation API Tests

    private func okHTTP(_ url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testGoogleFreeAndOfficialBatchTranslation() async throws {
        let googleConfig = TranslationAPIConfiguration(provider: .google)

        // 1) 免 Key 快捷通道（多段合并一次请求）
        let freeResults = try await ThirdPartyTranslation.translateBatch(
            ["Hello", "World"],
            source: "en",
            target: "zh-Hans",
            configuration: googleConfig,
            secret: nil
        ) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "translate.googleapis.com")
            XCTAssertTrue(url.absoluteString.contains("tl=zh-CN"))
            let json = #"[[["你好\n","Hello\n",null,null,10],["世界","World",null,null,10]],null,"en"]"#
            return (Data(json.utf8), self.okHTTP(url))
        }
        XCTAssertEqual(freeResults, ["你好", "世界"])

        // 2) 官方 Cloud Translation v2 API（数组批量 + Header Key）
        let officialResults = try await ThirdPartyTranslation.translateBatch(
            ["Hello", "World"],
            source: "auto",
            target: "ja",
            configuration: googleConfig,
            secret: "google-secret-key"
        ) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Api-Key"), "google-secret-key")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["q"] as? [String], ["Hello", "World"])
            XCTAssertEqual(body["target"] as? String, "ja")
            XCTAssertNil(body["source"])
            let json = #"{"data":{"translations":[{"translatedText":"こんにちは"},{"translatedText":"世界"}]}}"#
            return (Data(json.utf8), self.okHTTP(try XCTUnwrap(request.url)))
        }
        XCTAssertEqual(officialResults, ["こんにちは", "世界"])
    }

    func testBaiduSignatureAndBatchTranslation() async throws {
        // 百度官方文档示例签名验证
        let expected = ThirdPartyTranslation.baiduSignature(
            appID: "2015063000000001",
            query: "apple",
            salt: "1435660288",
            secret: "12345678"
        )
        XCTAssertEqual(expected, "f89f9594663708c1605f3d736d01d2d4")

        let baidu = TranslationAPIConfiguration(provider: .baidu, appID: "app-123")
        let results = try await ThirdPartyTranslation.translateBatch(
            ["Hello", "Goodbye"],
            source: "en",
            target: "zh-Hans",
            configuration: baidu,
            secret: "secret-456"
        ) { request in
            XCTAssertEqual(request.url?.host, "fanyi-api.baidu.com")
            let bodyText = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(bodyText.contains("appid=app-123"))
            XCTAssertTrue(bodyText.contains("to=zh"))
            let json = #"{"trans_result":[{"src":"Hello","dst":"你好"},{"src":"Goodbye","dst":"再见"}]}"#
            return (Data(json.utf8), self.okHTTP(try XCTUnwrap(request.url)))
        }
        XCTAssertEqual(results, ["你好", "再见"])
    }

    func testDeepLEndpointSelectionAndBatchTranslation() async throws {
        let deepl = TranslationAPIConfiguration(provider: .deepl)
        XCTAssertEqual(
            ThirdPartyTranslation.deepLEndpoint(configuration: deepl, apiKey: "abc:fx").host,
            "api-free.deepl.com"
        )
        XCTAssertEqual(
            ThirdPartyTranslation.deepLEndpoint(configuration: deepl, apiKey: "abc-pro").host,
            "api.deepl.com"
        )

        let results = try await ThirdPartyTranslation.translateBatch(
            ["Build complete", "All tests passed"],
            source: "en",
            target: "zh-Hans",
            configuration: deepl,
            secret: "my-key:fx"
        ) { request in
            XCTAssertEqual(request.url?.host, "api-free.deepl.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key my-key:fx")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["target_lang"] as? String, "ZH-HANS")
            let json = #"{"translations":[{"text":"构建完成"},{"text":"所有测试通过"}]}"#
            return (Data(json.utf8), self.okHTTP(try XCTUnwrap(request.url)))
        }
        XCTAssertEqual(results, ["构建完成", "所有测试通过"])
    }

    func testAzureAndTencentAndYoudaoTranslation() async throws {
        // Azure Translator
        let azure = TranslationAPIConfiguration(provider: .azure, region: "eastasia")
        let azureOut = try await ThirdPartyTranslation.translateBatch(
            ["Open", "Close"],
            source: "en",
            target: "zh-Hans",
            configuration: azure,
            secret: "azure-key"
        ) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "azure-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region"), "eastasia")
            let json = #"[{"translations":[{"text":"打开"}]},{"translations":[{"text":"关闭"}]}]"#
            return (Data(json.utf8), self.okHTTP(try XCTUnwrap(request.url)))
        }
        XCTAssertEqual(azureOut, ["打开", "关闭"])

        // Tencent TMT Batch
        let tencent = TranslationAPIConfiguration(provider: .tencent, appID: "AKID-test", region: "ap-shanghai")
        let tencentOut = try await ThirdPartyTranslation.translateBatch(
            ["Save", "Cancel"],
            source: "en",
            target: "zh-Hans",
            configuration: tencent,
            secret: "secret-key-test"
        ) { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "TextTranslateBatch")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Region"), "ap-shanghai")
            let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertTrue(auth.hasPrefix("TC3-HMAC-SHA256 Credential=AKID-test/"))
            let json = #"{"Response":{"TargetTextList":["保存","取消"]}}"#
            return (Data(json.utf8), self.okHTTP(try XCTUnwrap(request.url)))
        }
        XCTAssertEqual(tencentOut, ["保存", "取消"])

        // Youdao v3 truncation + translation
        let longText = "1234567890abcdefghij1234567890"
        XCTAssertEqual(ThirdPartyTranslation.youdaoTruncateInput(longText), "1234567890301234567890")
        let youdao = TranslationAPIConfiguration(provider: .youdao, appID: "yd-app")
        let youdaoOut = try await ThirdPartyTranslation.translate(
            "Settings",
            source: "en",
            target: "zh-Hans",
            configuration: youdao,
            secret: "yd-secret"
        ) { request in
            let bodyText = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(bodyText.contains("signType=v3"))
            XCTAssertTrue(bodyText.contains("to=zh-CHS"))
            let json = #"{"errorCode":"0","translation":["设置"]}"#
            return (Data(json.utf8), self.okHTTP(try XCTUnwrap(request.url)))
        }
        XCTAssertEqual(youdaoOut, "设置")
    }

    func testThirdPartyAPIConfigAndKeysStayIsolatedFromSettingsJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = ConfigStore(fileURL: file)

        let baidu = TranslationAPIConfiguration(provider: .baidu, appID: "baidu-app-id")
        try store.translationKeys.save("super-secret-baidu-key", for: baidu)
        store.update {
            $0.translation.provider = .api
            $0.translation.apiProvider = .baidu
            $0.translation.saveAPI(baidu)
        }

        let reopened = ConfigStore(fileURL: file)
        XCTAssertEqual(reopened.settings.translation.provider, .api)
        XCTAssertEqual(reopened.settings.translation.apiProvider, .baidu)
        XCTAssertEqual(reopened.settings.translation.apiConfiguration?.trimmedAppID, "baidu-app-id")
        XCTAssertEqual(try reopened.translationKeys.read(for: baidu), "super-secret-baidu-key")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("super-secret-baidu-key"))
    }
}

import Foundation
import XCTest
@testable import TapSnapPrivacy

final class PrivacyAITests: XCTestCase {
    func testProviderEndpointsAndCredentialsStayScoped() throws {
        let deepSeek = PrivacyAIConfiguration(provider: .deepSeek)
        XCTAssertEqual(deepSeek.endpoint?.absoluteString, "https://api.deepseek.com/chat/completions")
        let qwen = PrivacyAIConfiguration(provider: .qwen)
        XCTAssertEqual(qwen.endpoint?.absoluteString, "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        var local = PrivacyAIConfiguration(provider: .local)
        XCTAssertFalse(local.isConfigured)
        local.model = "sample-model"
        XCTAssertEqual(local.endpoint?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        local.baseURL = "https://service.example.invalid/v1"
        XCTAssertNil(local.endpoint)
        var custom = PrivacyAIConfiguration(provider: .custom)
        custom.model = "sample-model"
        for url in ["http://service.example.invalid/v1", "https://user:secret@service.example.invalid/v1",
                    "https://service.example.invalid/v1?key=DEMO"] {
            custom.baseURL = url
            XCTAssertNil(custom.endpoint)
        }
        custom.baseURL = "https://service.example.invalid/v1/chat/completions"
        XCTAssertEqual(custom.endpoint?.absoluteString, custom.baseURL)
    }

    func testRequestUsesOnlySanitizedTextAndResponseMustMatchOriginalRange() throws {
        var settings = PrivacySettings()
        settings[.email] = .off
        settings[.token] = .off
        settings[.credentials] = .off
        let content = [
            "👤 由示例人士负责",
            "Email: sample@example.invalid",
            #"Password: "synthetic passphrase""#,
            "Synthetic callback 13900000000",
            "Cookie: a=DEMO; b=SAMPLE"
        ]
        let rows = content.enumerated().map { index, text in
            PrivacyTextLine(text: text, rect: CGRect(x: 8, y: 30 * index, width: 240, height: 16), confidence: 1)
        }
        let matches = try TextRules(settings: settings).matches(in: rows)
        let lines = try PrivacyAI.minimizedLines(rows, matches: matches, settings: settings)
        let config = PrivacyAIConfiguration(provider: .deepSeek)
        let request = try PrivacyAI.request(config, key: "test-key", lines: lines, rules: [.name])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let data = try XCTUnwrap(request.httpBody)
        let requestBody = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(requestBody["messages"] as? [[String: String]])
        let text = try XCTUnwrap(messages.last?["content"])
        XCTAssertTrue(text.contains("示例人士"))
        for value in ["sample@example.invalid", "synthetic passphrase", "13900000000", "a=DEMO", "b=SAMPLE", "test-key"] {
            XCTAssertFalse(text.contains(value))
        }

        let selections = [
            PrivacyAI.Selection(id: 0, type: "name", text: "示例人士"),
            PrivacyAI.Selection(id: 0, type: "name", text: "imagined"),
            PrivacyAI.Selection(id: 0, type: "email", text: "示例人士"),
            PrivacyAI.Selection(id: 1, type: "name", text: "■"),
            PrivacyAI.Selection(id: 99, type: "name", text: "示例人士")
        ]
        let verified = PrivacyAI.verifiedMatches(selections, in: lines, settings: settings)
        XCTAssertEqual(verified.count, 1)
        let match = try XCTUnwrap(verified.first)
        XCTAssertEqual((content[0] as NSString).substring(with: match.range), "示例人士")
        XCTAssertFalse(match.covered, "The rule is configured to suggest, so AI cannot auto-apply")
    }

    func testChatCompletionsDecodesStructuredResultAndRejectsPlainText() throws {
        let content = #"{"matches":[{"id":0,"type":"name","text":"Sample Person"}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let result = try PrivacyAI.decode(data)
        XCTAssertEqual(result.first?.id, 0)
        XCTAssertEqual(result.first?.type, "name")
        XCTAssertEqual(result.first?.text, "Sample Person")
        let invalid = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "plain text"]]]])
        XCTAssertThrowsError(try PrivacyAI.decode(invalid))
    }

    func testValueMatchingToleratesCaseAndWidthWithoutAcceptingPartialTokens() {
        let line = "Assigned to Ｓａｍｐｌｅ Person"
        let range = PrivacyAI.uniqueValue("sample person", in: line)
        XCTAssertEqual(range.map { String(line[$0]) }, "Ｓａｍｐｌｅ Person")
        XCTAssertNil(PrivacyAI.uniqueValue("Sample Pers", in: line))
        XCTAssertNil(PrivacyAI.uniqueValue("Sample", in: "Sample A / Sample B"))
        XCTAssertNil(PrivacyAI.uniqueValue("example.invalid", in: "user@example.invalid"))
    }

    func testFormattedValuesMapBackToTheEntireOCRSpan() {
        let text = "Key  sk-demo1  ••••  WXYZ   Created"
        let match = PrivacyAI.formattedValue("sk-demo1*****WXYZ", in: text, rule: .token)
        XCTAssertEqual(match.map { String(text[$0]) }, "sk-demo1  ••••  WXYZ")
        XCTAssertNil(PrivacyAI.formattedValue("sk-demo1****WX", in: text, rule: .token))
        XCTAssertNil(PrivacyAI.formattedValue("sk-demo1***WXYZ", in: "\(text) / sk-demo1***WXYZ", rule: .token))
    }
}

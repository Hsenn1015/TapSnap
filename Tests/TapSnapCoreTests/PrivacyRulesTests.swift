import Foundation
import XCTest
@testable import TapSnapPrivacy

final class PrivacyRulesTests: XCTestCase {
    // Synthetic numbers and reserved example hostnames only.
    private let syntheticID = "990001200002290016"
    private let testPAN = "4111 1111 1111 1111"
    private let mobile = "139 0000 0000"

    private func matches(_ text: String, settings: PrivacySettings = PrivacySettings(),
                         confidence: Float = 0.99) throws -> [(String, String, Bool)] {
        let line = PrivacyTextLine(text: text, rect: CGRect(x: 10, y: 10, width: 360, height: 18), confidence: confidence)
        return try TextRules(settings: settings).matches(in: [line]).map {
            ($0.label, (text as NSString).substring(with: $0.range), $0.covered)
        }
    }

    func testNumbersUseChecksumAndContextWithoutMaskingOrdinaryText() throws {
        XCTAssertTrue(TextRules.isIdentity(syntheticID))
        XCTAssertFalse(TextRules.isIdentity("990001200102290015"))
        let text = "手机：＋８６ １３９－００００－００００  身份证：\(syntheticID)  卡号：\(testPAN)"
        let found = try matches(text)
        XCTAssertEqual(found.map(\.0), [PrivacyRule.mobile.title, PrivacyRule.identity.title, PrivacyRule.bankCard.title])
        XCTAssertTrue(found.allSatisfy(\.2))
        XCTAssertEqual(found.first?.1, "＋８６ １３９－００００－００００")
        let ambiguous = try matches("订单号：\(testPAN)  单价：99.00  日期：2026-11-13")
        XCTAssertEqual(ambiguous.map(\.0), [PrivacyRule.bankCard.title])
        XCTAssertEqual(ambiguous.first?.2, false)
        XCTAssertEqual(try matches("身份证号：990001200002290015").first?.2, false)
        XCTAssertEqual(try matches("手机：139 O000 0000").first?.2, false)
        XCTAssertEqual(try matches("电话：(010) 80000000 转 128").first?.1, "(010) 80000000 转 128")
        XCTAssertTrue(try matches("文件版本 2026.11.13，订单编号 ORDER-DEMO-01").isEmpty)
    }

    func testFieldValuesAndURLParametersAreIndependentlyConfigured() throws {
        var settings = PrivacySettings()
        settings.internalDomains = ".corp.example, internal.example"
        let text = #"账号密码：sample/sample-placeholder 密码="quoted sample value" 验证码：123456 Authorization: Bearer SYNTHETIC_TOKEN Cookie: sample=DEMO; session=DEMO"#
        let found = try matches(text, settings: settings)
        XCTAssertEqual(found.map(\.1), ["sample/sample-placeholder", "quoted sample value", "123456", "SYNTHETIC_TOKEN", "sample=DEMO; session=DEMO"])
        XCTAssertTrue(found.allSatisfy(\.2))
        let link = "https://api.corp.example:8443/path?view=example&token=PLACEHOLDER&code=123456"
        XCTAssertEqual(try matches(link, settings: settings).map(\.1), ["api.corp.example:8443", "PLACEHOLDER", "123456"])
        XCTAssertTrue(try matches("https://notcorp.example/path?view=example", settings: settings).isEmpty)
        XCTAssertEqual(try matches("http://10.10.20.30:8080  [fd00::1234]:8443  8.8.8.8  2001:db8::1").map(\.1),
                       ["10.10.20.30:8080", "[fd00::1234]:8443"])
        settings[.token] = .off
        XCTAssertEqual(try matches("postgresql://sample:DEMO@host.invalid/db", settings: settings).first?.1, "sample:DEMO")
        XCTAssertFalse(try matches(link, settings: settings).contains { $0.0 == PrivacyRule.token.title })
        XCTAssertEqual(try matches("邮箱：sample@example.invalid").first?.2, true)
        XCTAssertEqual(try matches("工号：EMP-0001  姓名：示例姓名").map(\.2), [false, false])
    }

    func testHeaderAssociationAndWrappedValuesUseImagePositions() throws {
        let lines = [
            line("订单号", x: 10, y: 10), line("银行卡号", x: 240, y: 10),
            line(testPAN, x: 10, y: 42), line(testPAN, x: 240, y: 42),
            line("Token: SYNTHETIC_FRAGMENT", x: 15, y: 160),
            line("CONTINUATION_FRAGMENT", x: 16, y: 182),
            line("地址：示例区虚拟路", x: 15, y: 220), line("100 号 2 楼", x: 16, y: 242),
            line("银行卡号：4111 1111", x: 18, y: 320), line("1111 1111", x: 18, y: 342)
        ]
        let found = try TextRules(settings: PrivacySettings()).matches(in: lines)
        XCTAssertEqual(found.first(where: { $0.line == 2 })?.covered, false)
        XCTAssertEqual(found.first(where: { $0.line == 3 })?.covered, true)
        XCTAssertTrue(found.contains { $0.line == 5 && $0.label == PrivacyRule.token.title && $0.covered })
        XCTAssertTrue(found.contains { $0.line == 7 && $0.label == PrivacyRule.address.title && !$0.covered })
        XCTAssertTrue(found.contains { $0.line == 8 && $0.label == PrivacyRule.bankCard.title && $0.covered })
        XCTAssertTrue(found.contains { $0.line == 9 && $0.label == PrivacyRule.bankCard.title && $0.covered })
    }

    func testSpacedNetworkAddressAndPartiallyMaskedNumbers() throws {
        let found = try matches("服务地址 10 . 0 . 0 . 5 : 8080，手机：139****0000，卡号：4111 •••• •••• 1111")
        XCTAssertEqual(found.map(\.0), [PrivacyRule.privateIP.title, PrivacyRule.mobile.title, PrivacyRule.bankCard.title])
        XCTAssertEqual(found.map(\.1), ["10 . 0 . 0 . 5 : 8080", "139****0000", "4111 •••• •••• 1111"])
        XCTAssertTrue(found.allSatisfy(\.2))
    }

    func testMaskedProviderKeysAreDetectedWithoutMatchingHelpTextOrOtherColumns() throws {
        let first = "sk-demo1*****ABCD"
        let second = "sk-demo2 ••• WXYZ"
        let lines = [
            line("API keys are visible once. Revoke any API key immediately if exposed.", x: 10, y: 10),
            line("Tracking ID", x: 190, y: 60), line("Key", x: 365, y: 60),
            line("2026-02-03", x: 565, y: 60),
            line("DEMO-TRACKING-01", x: 190, y: 95), line(first, x: 365, y: 95),
            line("Managed by the app", x: 365, y: 130), line(second + " 2026-02-05", x: 365, y: 165)
        ]
        let tokens = try TextRules(settings: PrivacySettings()).matches(in: lines).filter { $0.label == PrivacyRule.token.title }
        XCTAssertEqual(tokens.map { (lines[$0.line].text as NSString).substring(with: $0.range) }, [first, second])
        XCTAssertTrue(tokens.allSatisfy(\.covered))
    }

    func testCustomRuleModesAndInvalidRuleAreRespected() throws {
        var settings = PrivacySettings()
        settings[.mobile] = .off
        settings[.email] = .review
        var rule = CustomPrivacyRule()
        rule.name = "内部工单"
        rule.pattern = #"INT-\d{4}"#
        rule.mode = .automatic
        settings.customRules = [rule]
        let found = try matches("INT-0123  \(mobile)  sample@example.invalid", settings: settings)
        XCTAssertEqual(found.map(\.1), ["INT-0123", "sample@example.invalid"])
        XCTAssertEqual(found.map(\.2), [true, false])
        XCTAssertEqual(try matches("INT-0123", settings: settings, confidence: 0.2).first?.2, false)
        rule.pattern = "["
        settings.customRules = [rule]
        XCTAssertThrowsError(try matches("INT-0123", settings: settings))
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat) -> PrivacyTextLine {
        PrivacyTextLine(text: text, rect: CGRect(x: x, y: y, width: 100, height: 18), confidence: 0.99)
    }
}

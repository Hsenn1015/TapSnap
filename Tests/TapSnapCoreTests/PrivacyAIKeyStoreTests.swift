import Foundation
import TapSnapConfig
import TapSnapPrivacy
import XCTest

final class PrivacyAIKeyStoreTests: XCTestCase {
    func testSavedKeysArePrivateAndScopedToProviderAndEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let config = ConfigStore(fileURL: settings)
        let selected = PrivacyAIConfiguration(provider: .deepSeek)
        var otherEndpoint = selected
        otherEndpoint.baseURL = "https://sample.example.invalid/v1"
        var otherProvider = PrivacyAIConfiguration(provider: .custom)
        otherProvider.baseURL = selected.baseURL
        otherProvider.model = selected.model

        XCTAssertNil(try config.privacyAIKeys.read(for: selected))
        try config.privacyAIKeys.remove(for: selected)
        try config.privacyAIKeys.save("  fake-first-key \n", for: selected)
        try config.privacyAIKeys.save("fake-second-key", for: otherEndpoint)
        try config.privacyAIKeys.save("fake-updated-key", for: selected)
        config.update { $0.privacy.ai = selected }

        let reopened = ConfigStore(fileURL: settings)
        XCTAssertEqual(try reopened.privacyAIKeys.read(for: selected), "fake-updated-key")
        XCTAssertEqual(try reopened.privacyAIKeys.read(for: otherEndpoint), "fake-second-key")
        XCTAssertNil(try reopened.privacyAIKeys.read(for: otherProvider))
        XCTAssertFalse(try String(contentsOf: settings, encoding: .utf8).contains("fake-"))

        let files = directory.appendingPathComponent("privacy-ai-keys", isDirectory: true)
        XCTAssertEqual(try mode(of: files), 0o700)
        let entries = try FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 2)
        for entry in entries { XCTAssertEqual(try mode(of: entry), 0o600) }

        XCTAssertThrowsError(try reopened.privacyAIKeys.save("invalid key", for: selected))
        XCTAssertEqual(try reopened.privacyAIKeys.read(for: selected), "fake-updated-key")
        try reopened.privacyAIKeys.remove(for: selected)
        XCTAssertNil(try reopened.privacyAIKeys.read(for: selected))
        XCTAssertEqual(try reopened.privacyAIKeys.read(for: otherEndpoint), "fake-second-key")
    }

    func testMissingCloudKeyFailsBeforeSendingRequest() async throws {
        let provider = PrivacyAIConfiguration(provider: .deepSeek)
        do {
            try await PrivacyAI.testConnection(provider)
            XCTFail("A cloud provider must have a saved or supplied API key")
        } catch let error as PrivacyAIError {
            XCTAssertEqual(error, .missingKey)
        }
    }

    private func mode(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}

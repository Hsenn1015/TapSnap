import CryptoKit
import Darwin
import Foundation
import TapSnapPrivacy

/// A separate file per provider and endpoint keeps keys out of the general settings file.
public struct PrivacyAIKeyStore {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    public func read(for configuration: PrivacyAIConfiguration) throws -> String? {
        try readSecret(at: try file(for: configuration))
    }

    public func save(_ value: String, for configuration: PrivacyAIConfiguration) throws {
        try saveSecret(value, to: try file(for: configuration))
    }

    public func remove(for configuration: PrivacyAIConfiguration) throws {
        try removeSecret(at: try file(for: configuration))
    }

    public func read(for api: TranslationAPIConfiguration) throws -> String? {
        try readSecret(at: file(forScope: api.credentialScope))
    }

    public func save(_ value: String, for api: TranslationAPIConfiguration) throws {
        try saveSecret(value, to: file(forScope: api.credentialScope))
    }

    public func remove(for api: TranslationAPIConfiguration) throws {
        try removeSecret(at: file(forScope: api.credentialScope))
    }

    private func readSecret(at url: URL) throws -> String? {
        do {
            return try PrivacyAI.validatedKey(String(contentsOf: url, encoding: .utf8))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        catch { throw PrivacyAIError.keyStorage }
    }

    private func saveSecret(_ value: String, to url: URL) throws {
        let key = try PrivacyAI.validatedKey(value)
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let temporary = directory.appendingPathComponent(UUID().uuidString)
            // Set the permissions before any key bytes are written, then replace atomically.
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw PrivacyAIError.keyStorage }
            defer { try? manager.removeItem(at: temporary) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: Data(key.utf8))
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw PrivacyAIError.keyStorage }
        } catch {
            throw PrivacyAIError.keyStorage
        }
    }

    private func removeSecret(at url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
        catch { throw PrivacyAIError.keyStorage }
    }

    private func file(for configuration: PrivacyAIConfiguration) throws -> URL {
        guard let endpoint = configuration.endpoint else { throw PrivacyAIError.configuration }
        return file(forScope: "\(configuration.provider.rawValue):\(endpoint.absoluteString)")
    }

    private func file(forScope scope: String) -> URL {
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }
}

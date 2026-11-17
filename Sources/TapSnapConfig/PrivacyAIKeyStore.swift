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
        let url = try file(for: configuration)
        do {
            return try PrivacyAI.validatedKey(String(contentsOf: url, encoding: .utf8))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        catch { throw PrivacyAIError.keyStorage }
    }

    public func save(_ value: String, for configuration: PrivacyAIConfiguration) throws {
        let key = try PrivacyAI.validatedKey(value)
        let url = try file(for: configuration)
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

    public func remove(for configuration: PrivacyAIConfiguration) throws {
        let url = try file(for: configuration)
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
        catch { throw PrivacyAIError.keyStorage }
    }

    private func file(for configuration: PrivacyAIConfiguration) throws -> URL {
        guard let endpoint = configuration.endpoint else { throw PrivacyAIError.configuration }
        let scope = "\(configuration.provider.rawValue):\(endpoint.absoluteString)"
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }
}

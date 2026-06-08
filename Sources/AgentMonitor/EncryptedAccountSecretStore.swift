import CryptoKit
import Foundation
import Security

struct EncryptedAccountSecretStore: Sendable {
    private let fileURL: URL
    private let keyProvider: @Sendable () throws -> SymmetricKey

    init(
        fileURL: URL = EncryptedAccountSecretStore.defaultFileURL(),
        keyProvider: (@Sendable () throws -> SymmetricKey)? = nil
    ) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider ?? { try EncryptedAccountSecretStore.loadOrCreateKeychainKey() }
    }

    func readAPIKey(for kind: AccountKind) -> String {
        (try? readSecrets()[kind.id]) ?? ""
    }

    func writeAPIKey(_ apiKey: String, for kind: AccountKind) {
        do {
            var secrets = try readSecrets()
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                secrets.removeValue(forKey: kind.id)
            } else {
                secrets[kind.id] = trimmed
            }
            try writeSecrets(secrets)
        } catch {
            NSLog("AgentMonitor failed to persist encrypted API key for \(kind.id): \(error.localizedDescription)")
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AgentMonitor", isDirectory: true)
            .appendingPathComponent("account-secrets.json", isDirectory: false)
    }

    private func readSecrets() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(EncryptedSecretsEnvelope.self, from: data)
        guard envelope.version == 1, let combined = Data(base64Encoded: envelope.sealedBox) else { return [:] }
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let decrypted = try AES.GCM.open(sealedBox, using: keyProvider())
        return try JSONDecoder().decode([String: String].self, from: decrypted)
    }

    private func writeSecrets(_ secrets: [String: String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plaintext = try JSONEncoder().encode(secrets)
        let sealedBox = try AES.GCM.seal(plaintext, using: keyProvider())
        guard let combined = sealedBox.combined else {
            throw EncryptedAccountSecretStoreError.missingCombinedSealedBox
        }
        let envelope = EncryptedSecretsEnvelope(version: 1, sealedBox: combined.base64EncodedString())
        let encoded = try JSONEncoder().encode(envelope)
        try encoded.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func loadOrCreateKeychainKey() throws -> SymmetricKey {
        if let existing = try readKeychainKey() {
            return SymmetricKey(data: existing)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw EncryptedAccountSecretStoreError.randomGenerationFailed(status)
        }
        let data = Data(bytes)
        try writeKeychainKey(data)
        return SymmetricKey(data: data)
    }

    private static func readKeychainKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AgentMonitor.AccountSecrets",
            kSecAttrAccount as String: "encryption-key-v1",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw EncryptedAccountSecretStoreError.keychainReadFailed(status)
        }
        return item as? Data
    }

    private static func writeKeychainKey(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AgentMonitor.AccountSecrets",
            kSecAttrAccount as String: "encryption-key-v1",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw EncryptedAccountSecretStoreError.keychainWriteFailed(status)
        }
    }
}

private struct EncryptedSecretsEnvelope: Codable {
    var version: Int
    var sealedBox: String
}

enum EncryptedAccountSecretStoreError: Error, LocalizedError {
    case missingCombinedSealedBox
    case randomGenerationFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingCombinedSealedBox:
            "AES-GCM did not produce a combined sealed box"
        case .randomGenerationFailed(let status):
            "Failed to generate encryption key bytes: OSStatus \(status)"
        case .keychainReadFailed(let status):
            "Failed to read encryption key from Keychain: OSStatus \(status)"
        case .keychainWriteFailed(let status):
            "Failed to write encryption key to Keychain: OSStatus \(status)"
        }
    }
}

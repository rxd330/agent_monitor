import CryptoKit
import XCTest
@testable import AgentMonitor

@MainActor
final class AccountUsageStoreTests: XCTestCase {
    func testManualBudgetSnapshotPersistsAndComputesRemaining() {
        let (defaults, suiteName) = makeDefaults()
        let (secretStore, secretsURL) = makeSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: secretsURL.deletingLastPathComponent())
        }

        let store = AccountUsageStore(defaults: defaults, secretStore: secretStore)
        store.update(.openAI, settings: AccountSettings(
            isEnabled: true,
            apiKey: "sk-test",
            monthlyBudget: 100,
            manualUsedAmount: 37.5,
            tokenLimit: 0,
            manualUsedTokens: 0
        ))

        XCTAssertEqual(store.snapshots[.openAI]?.remainingBudget, 62.5)
        XCTAssertEqual(store.summaryLines(), ["OpenAI API: $62.50 remaining"])
        XCTAssertEqual(store.snapshots[.openAI]?.detailText, "Used $37.50 of $100.00")
        XCTAssertNil(defaults.string(forKey: "account.openai.apiKey"))

        let reloaded = AccountUsageStore(defaults: defaults, secretStore: secretStore)
        XCTAssertEqual(reloaded.settings[.openAI]?.monthlyBudget, 100)
        XCTAssertEqual(reloaded.settings[.openAI]?.manualUsedAmount, 37.5)
        XCTAssertEqual(reloaded.settings[.openAI]?.apiKey, "sk-test")
    }

    func testCodexTokenSnapshotComputesRemaining() {
        let (defaults, suiteName) = makeDefaults()
        let (secretStore, secretsURL) = makeSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: secretsURL.deletingLastPathComponent())
        }

        let store = AccountUsageStore(defaults: defaults, secretStore: secretStore)
        store.update(.codex, settings: AccountSettings(
            isEnabled: true,
            apiKey: "",
            monthlyBudget: 0,
            manualUsedAmount: 0,
            tokenLimit: 1_000_000,
            manualUsedTokens: 250_000
        ))

        XCTAssertEqual(store.snapshots[.codex]?.remainingTokens, 750_000)
        XCTAssertEqual(store.summaryLines(), ["Codex: 750,000 tokens remaining"])
        XCTAssertEqual(store.snapshots[.codex]?.detailText, "Used 250,000 of 1,000,000 tokens")
    }

    func testEncryptedSecretStorePersistsAPIKeyWithoutPlaintextFileContents() throws {
        let (secretStore, secretsURL) = makeSecretStore()
        defer { try? FileManager.default.removeItem(at: secretsURL.deletingLastPathComponent()) }

        secretStore.writeAPIKey("sk-secret-value", for: .openAI)

        XCTAssertEqual(secretStore.readAPIKey(for: .openAI), "sk-secret-value")
        let fileContents = try String(contentsOf: secretsURL, encoding: .utf8)
        XCTAssertFalse(fileContents.contains("sk-secret-value"))
        XCTAssertTrue(fileContents.contains("sealedBox"))
    }

    func testMigratesLegacyUserDefaultsAPIKeyIntoEncryptedSecretStore() {
        let (defaults, suiteName) = makeDefaults()
        let (secretStore, secretsURL) = makeSecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: secretsURL.deletingLastPathComponent())
        }
        defaults.set("legacy-token", forKey: "account.deepseek.apiKey")

        let store = AccountUsageStore(defaults: defaults, secretStore: secretStore)

        XCTAssertEqual(store.settings[.deepSeek]?.apiKey, "legacy-token")
        XCTAssertNil(defaults.string(forKey: "account.deepseek.apiKey"))
        XCTAssertEqual(secretStore.readAPIKey(for: .deepSeek), "legacy-token")
    }

    func testAutomaticRefreshIntervalIsOneMinute() {
        XCTAssertEqual(AccountUsageStore.automaticRefreshInterval, 60)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AgentMonitorTests.AccountUsageStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makeSecretStore() -> (EncryptedAccountSecretStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentMonitorTests.AccountSecrets.\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("account-secrets.json")
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        return (EncryptedAccountSecretStore(fileURL: url, keyProvider: { key }), url)
    }
}

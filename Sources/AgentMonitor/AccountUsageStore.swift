import Combine
import Foundation

@MainActor
final class AccountUsageStore: ObservableObject {
    @Published private(set) var settings: [AccountKind: AccountSettings] = [:]
    @Published private(set) var snapshots: [AccountKind: AccountSnapshot] = [:]

    static let automaticRefreshInterval: TimeInterval = 60

    private let defaults: UserDefaults
    private let secretStore: EncryptedAccountSecretStore
    private var refreshTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, secretStore: EncryptedAccountSecretStore = EncryptedAccountSecretStore()) {
        self.defaults = defaults
        self.secretStore = secretStore
        load()
    }

    deinit {
        refreshTask?.cancel()
        automaticRefreshTask?.cancel()
    }

    func load() {
        var loadedSettings: [AccountKind: AccountSettings] = [:]
        var loadedSnapshots: [AccountKind: AccountSnapshot] = [:]

        for kind in AccountKind.allCases {
            let current = readSettings(for: kind)
            loadedSettings[kind] = current
            loadedSnapshots[kind] = makeSnapshot(kind: kind, settings: current, status: current.isEnabled ? "Not refreshed" : "Not configured")
        }

        settings = loadedSettings
        snapshots = loadedSnapshots
    }

    func update(_ kind: AccountKind, settings newSettings: AccountSettings) {
        writeSettings(newSettings, for: kind)
        settings[kind] = newSettings
        snapshots[kind] = makeSnapshot(kind: kind, settings: newSettings, status: newSettings.isEnabled ? "Saved" : "Not configured")
    }

    func refreshAll() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            for kind in AccountKind.allCases {
                await self.refresh(kind)
            }
        }
    }

    func startAutomaticRefresh(interval: TimeInterval = AccountUsageStore.automaticRefreshInterval) {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refreshAll()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
    }

    func refresh(_ kind: AccountKind) async {
        guard let accountSettings = settings[kind], accountSettings.isEnabled else {
            snapshots[kind] = makeSnapshot(kind: kind, settings: settings[kind] ?? .empty, status: "Not configured")
            return
        }

        snapshots[kind] = makeSnapshot(kind: kind, settings: accountSettings, status: "Refreshing…")

        switch kind {
        case .deepSeek:
            snapshots[kind] = await refreshDeepSeek(settings: accountSettings)
        case .openAI:
            snapshots[kind] = makeOpenAISnapshot(settings: accountSettings)
        case .codex:
            snapshots[kind] = makeCodexSnapshot(settings: accountSettings)
        }
    }

    func summaryLines() -> [String] {
        AccountKind.allCases.compactMap { kind in
            guard settings[kind]?.isEnabled == true, let snapshot = snapshots[kind] else { return nil }
            return snapshot.menuTitle
        }
    }

    private func readSettings(for kind: AccountKind) -> AccountSettings {
        let prefix = kind.userDefaultsPrefix
        var apiKey = secretStore.readAPIKey(for: kind)

        // One-time migration from the previous UserDefaults storage location.
        if apiKey.isEmpty, let legacyAPIKey = defaults.string(forKey: "\(prefix).apiKey"), !legacyAPIKey.isEmpty {
            secretStore.writeAPIKey(legacyAPIKey, for: kind)
            defaults.removeObject(forKey: "\(prefix).apiKey")
            apiKey = legacyAPIKey
        }

        return AccountSettings(
            isEnabled: defaults.bool(forKey: "\(prefix).enabled"),
            apiKey: apiKey,
            monthlyBudget: defaults.double(forKey: "\(prefix).monthlyBudget"),
            manualUsedAmount: defaults.double(forKey: "\(prefix).manualUsedAmount"),
            tokenLimit: defaults.integer(forKey: "\(prefix).tokenLimit"),
            manualUsedTokens: defaults.integer(forKey: "\(prefix).manualUsedTokens")
        )
    }

    private func writeSettings(_ value: AccountSettings, for kind: AccountKind) {
        let prefix = kind.userDefaultsPrefix
        defaults.set(value.isEnabled, forKey: "\(prefix).enabled")
        secretStore.writeAPIKey(value.apiKey, for: kind)
        defaults.removeObject(forKey: "\(prefix).apiKey")
        defaults.set(value.monthlyBudget, forKey: "\(prefix).monthlyBudget")
        defaults.set(value.manualUsedAmount, forKey: "\(prefix).manualUsedAmount")
        defaults.set(value.tokenLimit, forKey: "\(prefix).tokenLimit")
        defaults.set(value.manualUsedTokens, forKey: "\(prefix).manualUsedTokens")
    }

    private func makeSnapshot(kind: AccountKind, settings: AccountSettings, status: String) -> AccountSnapshot {
        switch kind {
        case .codex:
            let used = max(0, settings.manualUsedTokens)
            let limit = max(0, settings.tokenLimit)
            let remaining = limit > 0 ? max(0, limit - used) : nil
            return AccountSnapshot(
                kind: kind,
                remainingBudget: nil,
                usedBudget: nil,
                totalBudget: nil,
                remainingTokens: remaining,
                usedTokens: used > 0 ? used : nil,
                tokenLimit: limit > 0 ? limit : nil,
                statusText: status,
                lastUpdated: nil
            )
        case .openAI, .deepSeek:
            let total = settings.monthlyBudget > 0 ? settings.monthlyBudget : nil
            let used = settings.manualUsedAmount > 0 ? settings.manualUsedAmount : nil
            let remaining = total.map { max(0, $0 - settings.manualUsedAmount) }
            return AccountSnapshot(
                kind: kind,
                remainingBudget: remaining,
                usedBudget: used,
                totalBudget: total,
                remainingTokens: nil,
                usedTokens: nil,
                tokenLimit: nil,
                statusText: status,
                lastUpdated: nil
            )
        }
    }

    private func makeOpenAISnapshot(settings: AccountSettings) -> AccountSnapshot {
        var snapshot = makeSnapshot(kind: .openAI, settings: settings, status: "Manual budget tracking")
        snapshot.lastUpdated = Date()
        return snapshot
    }

    private func makeCodexSnapshot(settings: AccountSettings) -> AccountSnapshot {
        var snapshot = makeSnapshot(kind: .codex, settings: settings, status: "Manual token tracking")
        snapshot.lastUpdated = Date()
        return snapshot
    }

    private func refreshDeepSeek(settings: AccountSettings) async -> AccountSnapshot {
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return makeSnapshot(kind: .deepSeek, settings: settings, status: "Missing API key")
        }

        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            return makeSnapshot(kind: .deepSeek, settings: settings, status: "Invalid balance URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return makeSnapshot(kind: .deepSeek, settings: settings, status: "HTTP \(code)")
            }
            let balance = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
            let totalBalance = balance.balanceInfos.compactMap { Double($0.totalBalance) }.reduce(0, +)
            var snapshot = makeSnapshot(kind: .deepSeek, settings: settings, status: balance.isAvailable ? "Live balance" : "Account unavailable")
            snapshot.remainingBudget = totalBalance
            snapshot.totalBudget = settings.monthlyBudget > 0 ? settings.monthlyBudget : totalBalance
            snapshot.usedBudget = snapshot.totalBudget.map { max(0, $0 - totalBalance) }
            snapshot.lastUpdated = Date()
            return snapshot
        } catch {
            return makeSnapshot(kind: .deepSeek, settings: settings, status: error.localizedDescription)
        }
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    var isAvailable: Bool
    var balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct DeepSeekBalanceInfo: Decodable {
    var totalBalance: String

    enum CodingKeys: String, CodingKey {
        case totalBalance = "total_balance"
    }
}

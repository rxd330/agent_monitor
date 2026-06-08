import Foundation

enum AccountKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAI
    case codex
    case deepSeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: "OpenAI API"
        case .codex: "Codex Tokens"
        case .deepSeek: "DeepSeek API"
        }
    }

    var userDefaultsPrefix: String {
        switch self {
        case .openAI: "account.openai"
        case .codex: "account.codex"
        case .deepSeek: "account.deepseek"
        }
    }
}

struct AccountSettings: Equatable, Sendable {
    var isEnabled: Bool
    var apiKey: String
    var monthlyBudget: Double
    var manualUsedAmount: Double
    var tokenLimit: Int
    var manualUsedTokens: Int

    static let empty = AccountSettings(
        isEnabled: false,
        apiKey: "",
        monthlyBudget: 0,
        manualUsedAmount: 0,
        tokenLimit: 0,
        manualUsedTokens: 0
    )
}

struct AccountSnapshot: Equatable, Sendable {
    var kind: AccountKind
    var remainingBudget: Double?
    var usedBudget: Double?
    var totalBudget: Double?
    var remainingTokens: Int?
    var usedTokens: Int?
    var tokenLimit: Int?
    var statusText: String
    var lastUpdated: Date?

    var menuTitle: String {
        switch kind {
        case .codex:
            if let remainingTokens {
                return "Codex: \(Self.formatInteger(remainingTokens)) tokens remaining"
            }
            if let usedTokens {
                return "Codex: \(Self.formatInteger(usedTokens)) tokens used"
            }
            return "Codex: \(statusText)"
        case .openAI, .deepSeek:
            if let remainingBudget {
                return "\(kind.title): \(Self.formatCurrency(remainingBudget)) remaining"
            }
            return "\(kind.title): \(statusText)"
        }
    }

    var detailText: String? {
        switch kind {
        case .codex:
            if let usedTokens, let tokenLimit {
                return "Used \(Self.formatInteger(usedTokens)) of \(Self.formatInteger(tokenLimit)) tokens"
            }
            if let tokenLimit {
                return "Limit \(Self.formatInteger(tokenLimit)) tokens"
            }
            return nil
        case .openAI, .deepSeek:
            if let usedBudget, let totalBudget {
                return "Used \(Self.formatCurrency(usedBudget)) of \(Self.formatCurrency(totalBudget))"
            }
            if let totalBudget {
                return "Budget \(Self.formatCurrency(totalBudget))"
            }
            return nil
        }
    }

    static func formatCurrency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func formatInteger(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

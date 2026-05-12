import Foundation

struct UsageSnapshot: Equatable, Sendable {
    var account: CodexAccount?
    var sessionWindow: QuotaWindow?
    var weeklyWindow: QuotaWindow?
    var updatedAt: Date?
    var sourceDescription: String

    static let empty = UsageSnapshot(
        account: nil,
        sessionWindow: nil,
        weeklyWindow: nil,
        updatedAt: nil,
        sourceDescription: CodexUsageDataSource.oauthAPI.title
    )

    static func empty(sourceDescription: String) -> UsageSnapshot {
        UsageSnapshot(
            account: nil,
            sessionWindow: nil,
            weeklyWindow: nil,
            updatedAt: nil,
            sourceDescription: sourceDescription
        )
    }
}

enum CodexUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case oauthAPI = "oauthAPI"
    case cliRPC = "cliRPC"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oauthAPI:
            return "OAuth API"
        case .cliRPC:
            return "CLI RPC"
        }
    }

    var detail: String {
        switch self {
        case .oauthAPI:
            return "Read Codex OAuth tokens and call the ChatGPT usage endpoint."
        case .cliRPC:
            return "Start codex app-server locally and read rate limits through JSON-RPC."
        }
    }
}

enum CodexRefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneMinute:
            return "1 minute"
        case .twoMinutes:
            return "2 minutes"
        case .fiveMinutes:
            return "5 minutes"
        case .fifteenMinutes:
            return "15 minutes"
        case .thirtyMinutes:
            return "30 minutes"
        }
    }

    var randomizedNanoseconds: UInt64 {
        let base = Double(rawValue)
        let multiplier = Double.random(in: 0.87...1.27)
        return UInt64(base * multiplier * 1_000_000_000)
    }
}

struct CodexAccount: Equatable, Sendable {
    var type: String
    var email: String?
    var planType: String?

    var displayName: String {
        if let email, !email.isEmpty {
            return email
        }
        return type
    }

    var planLabel: String {
        CodexPlanLabels.displayName(for: planType)
    }
}

struct CodexManagedAccount: Identifiable, Equatable, Sendable {
    var accountKey: String
    var chatgptAccountID: String
    var chatgptUserID: String
    var email: String
    var alias: String
    var accountName: String?
    var planType: String?
    var authMode: String?
    var createdAt: Date?
    var lastUsedAt: Date?
    var lastUsageAt: Date?
    var storedUsage: UsageSnapshot?
    var isActive: Bool

    var id: String { accountKey }

    var displayName: String {
        if !alias.isEmpty { return alias }
        if let accountName, !accountName.isEmpty { return accountName }
        if !email.isEmpty { return email }
        return accountKey
    }

    var detailName: String {
        if let accountName, !accountName.isEmpty, accountName != displayName {
            return "\(email) / \(accountName)"
        }
        return email
    }

    var planLabel: String {
        CodexPlanLabels.displayName(for: planType)
    }

    var codexAccount: CodexAccount {
        CodexAccount(type: authMode ?? "chatgpt", email: email, planType: planType)
    }
}

struct AccountUsageRow: Identifiable, Equatable, Sendable {
    var account: CodexManagedAccount
    var snapshot: UsageSnapshot
    var errorMessage: String?
    var isRefreshing: Bool

    var id: String { account.id }
    var isActive: Bool { account.isActive }

    var hasQuotaData: Bool {
        snapshot.sessionWindow != nil || snapshot.weeklyWindow != nil
    }

    var planLabel: String {
        let snapshotPlan = snapshot.account?.planLabel ?? "--"
        return snapshotPlan == "--" ? account.planLabel : snapshotPlan
    }
}

enum CodexPlanLabels {
    static func displayName(for planType: String?) -> String {
        guard let planType, !planType.isEmpty else { return "--" }
        switch planType.lowercased() {
        case "plus":
            return "Plus"
        case "prolite":
            return "Pro Lite"
        case "pro":
            return "Pro"
        case "team", "business":
            return "Business"
        case "enterprise":
            return "Enterprise"
        case "edu":
            return "Edu"
        case "free":
            return "Free"
        default:
            return planType
        }
    }
}

struct CodexAccountsRegistrySnapshot: Equatable, Sendable {
    var schemaVersion: Int
    var activeAccountKey: String?
    var accounts: [CodexManagedAccount]
    var loadedAt: Date
}

struct QuotaWindow: Identifiable, Hashable, Sendable {
    var id: String
    var usedPercent: Double
    var windowDurationMins: Int
    var resetsAt: Date?

    var remainingPercent: Double {
        min(max(100 - usedPercent, 0), 100)
    }

    var remainingFraction: Double {
        min(max(remainingPercent / 100, 0), 1)
    }
}

enum CodexUsageConstants {
    static let sessionWindowMinutes = 5 * 60
    static let weeklyWindowMinutes = 7 * 24 * 60
}

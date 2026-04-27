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

    var nanoseconds: UInt64 {
        UInt64(rawValue) * 1_000_000_000
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

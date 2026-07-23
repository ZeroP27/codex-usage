import Foundation

struct CodexUsagePreferences: Codable, Equatable, Sendable {
    static let defaults = CodexUsagePreferences(
        usageDataSource: .oauthAPI,
        refreshInterval: .fiveMinutes,
        codexExecutablePath: "codex"
    )

    var usageDataSource: CodexUsageDataSource
    var refreshInterval: CodexRefreshInterval
    var codexExecutablePath: String

    func validated() throws -> CodexUsagePreferences {
        let path = codexExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw CodexUsagePreferencesError.invalidExecutablePath
        }
        return CodexUsagePreferences(
            usageDataSource: usageDataSource,
            refreshInterval: refreshInterval,
            codexExecutablePath: path
        )
    }
}

@MainActor
struct CodexUsagePreferencesRepository {
    private static let preferencesKey = "codexUsagePreferences.v1"
    private static let legacyDataSourceKey = "usageDataSource"
    private static let legacyRefreshIntervalKey = "refreshInterval"
    private static let legacyExecutableKey = "codexExecutablePath"

    var defaults: UserDefaults = .standard

    func load() -> CodexUsagePreferences {
        if let data = defaults.data(forKey: Self.preferencesKey),
           let preferences = try? JSONDecoder().decode(CodexUsagePreferences.self, from: data),
           let validated = try? preferences.validated()
        {
            return validated
        }

        let storedSource = defaults.string(forKey: Self.legacyDataSourceKey)
        let storedInterval = defaults.integer(forKey: Self.legacyRefreshIntervalKey)
        let legacy = CodexUsagePreferences(
            usageDataSource: storedSource.flatMap(CodexUsageDataSource.init(rawValue:)) ?? .oauthAPI,
            refreshInterval: CodexRefreshInterval(rawValue: storedInterval) ?? .fiveMinutes,
            codexExecutablePath: defaults.string(forKey: Self.legacyExecutableKey) ?? "codex"
        )
        let migrated = (try? legacy.validated()) ?? .defaults
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: Self.preferencesKey)
        }
        return migrated
    }

    func save(_ preferences: CodexUsagePreferences) throws {
        let validated = try preferences.validated()
        let data = try JSONEncoder().encode(validated)
        defaults.set(data, forKey: Self.preferencesKey)
    }
}

enum CodexUsagePreferencesError: LocalizedError {
    case invalidExecutablePath

    var errorDescription: String? {
        switch self {
        case .invalidExecutablePath:
            return "Codex executable path is empty or invalid."
        }
    }
}

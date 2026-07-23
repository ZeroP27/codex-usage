import Foundation
import Testing
@testable import CodexUsageMonitor

@MainActor
struct CodexUsagePreferencesRepositoryTests {
    @Test
    func legacyKeysAreLoadedAndMigratedToTheNewKey() throws {
        let fixture = try makePreferencesFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(
            CodexUsageDataSource.cliRPC.rawValue,
            forKey: "usageDataSource"
        )
        fixture.defaults.set(
            CodexRefreshInterval.fifteenMinutes.rawValue,
            forKey: "refreshInterval"
        )
        fixture.defaults.set(
            "  /opt/homebrew/bin/codex  ",
            forKey: "codexExecutablePath"
        )

        let loaded = fixture.repository.load()

        #expect(
            loaded
                == CodexUsagePreferences(
                    usageDataSource: .cliRPC,
                    refreshInterval: .fifteenMinutes,
                    codexExecutablePath: "/opt/homebrew/bin/codex"
                )
        )
        #expect(fixture.defaults.data(forKey: "codexUsagePreferences.v1") != nil)

        fixture.defaults.set(
            CodexUsageDataSource.oauthAPI.rawValue,
            forKey: "usageDataSource"
        )
        #expect(fixture.repository.load() == loaded)
    }

    @Test
    func newPreferencesRoundTripInNormalizedForm() throws {
        let fixture = try makePreferencesFixture()
        defer { fixture.cleanup() }
        let preferences = CodexUsagePreferences(
            usageDataSource: .cliRPC,
            refreshInterval: .thirtyMinutes,
            codexExecutablePath: "  /Applications/Codex.app/Contents/MacOS/codex\n"
        )

        try fixture.repository.save(preferences)

        #expect(
            fixture.repository.load()
                == CodexUsagePreferences(
                    usageDataSource: .cliRPC,
                    refreshInterval: .thirtyMinutes,
                    codexExecutablePath: "/Applications/Codex.app/Contents/MacOS/codex"
                )
        )
    }

    @Test
    func validationTrimsWhitespaceAndPreservesPortableTildePath() throws {
        let preferences = CodexUsagePreferences(
            usageDataSource: .oauthAPI,
            refreshInterval: .fiveMinutes,
            codexExecutablePath: "  ~/bin/codex \n"
        )
        let validated = try preferences.validated()

        #expect(validated.codexExecutablePath == "~/bin/codex")
    }

    @Test
    func validationRejectsEmptyPathAfterTrimming() {
        let preferences = CodexUsagePreferences(
            usageDataSource: .oauthAPI,
            refreshInterval: .fiveMinutes,
            codexExecutablePath: " \n\t "
        )

        #expect(throws: CodexUsagePreferencesError.self) {
            try preferences.validated()
        }
    }

    @Test
    func validationRejectsNULInPath() {
        let preferences = CodexUsagePreferences(
            usageDataSource: .oauthAPI,
            refreshInterval: .fiveMinutes,
            codexExecutablePath: "/usr/local/bin/\0codex"
        )

        #expect(throws: CodexUsagePreferencesError.self) {
            try preferences.validated()
        }
    }

    @Test
    func validationRejectsEmbeddedControlCharactersInPath() {
        let preferences = CodexUsagePreferences(
            usageDataSource: .cliRPC,
            refreshInterval: .fiveMinutes,
            codexExecutablePath: "/usr/local/bin/evil\ncodex"
        )

        #expect(throws: CodexUsagePreferencesError.self) {
            try preferences.validated()
        }
    }

    @Test
    func validationRejectsPathLongerThanFourKiB() {
        let preferences = CodexUsagePreferences(
            usageDataSource: .oauthAPI,
            refreshInterval: .fiveMinutes,
            codexExecutablePath: String(repeating: "a", count: 4_097)
        )

        #expect(throws: CodexUsagePreferencesError.self) {
            try preferences.validated()
        }
    }
}

@MainActor
private struct PreferencesRepositoryFixture {
    var repository: CodexUsagePreferencesRepository
    var defaults: UserDefaults
    var suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func makePreferencesFixture() throws -> PreferencesRepositoryFixture {
    let suiteName = "CodexUsagePreferencesRepositoryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    return PreferencesRepositoryFixture(
        repository: CodexUsagePreferencesRepository(defaults: defaults),
        defaults: defaults,
        suiteName: suiteName
    )
}

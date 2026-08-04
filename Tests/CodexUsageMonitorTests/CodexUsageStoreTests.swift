import Foundation
import Testing
@testable import CodexUsageMonitor

@MainActor
struct CodexUsageStoreTests {
    @Test
    func testPendingAllRefreshWinsRegardlessOfArrivalOrder() {
        #expect(CodexPendingRefreshKind.current.merged(with: .all) == .all)
        #expect(CodexPendingRefreshKind.all.merged(with: .current) == .all)
        #expect(CodexPendingRefreshKind.current.merged(with: .current) == .current)
    }

    @Test
    func testQueuedAllRefreshIsNotDowngradedByLaterCurrentRefresh() async throws {
        let fixture = try makePreferencesFixture(.defaults)
        defer { fixture.cleanup() }
        let gate = StoreOperationGate()
        let counter = StoreOperationCounter()
        let currentResult = makeLoadResult(
            accountKey: "managed-current",
            email: "current@example.com"
        )
        let operations = makeOperations(
            loadCurrentManagedAccountUsage: {
                await counter.recordCurrentLoad()
                await gate.wait()
                return currentResult
            },
            loadUsage: { _, codexExecutablePath in
                await counter.recordFullLoad(path: codexExecutablePath)
                return makeLoadResult(
                    accountKey: codexExecutablePath,
                    email: codexExecutablePath
                )
            }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )

        store.refreshCurrentAccount()
        await gate.waitUntilEntered()

        store.updateCodexExecutablePath("/new/codex")
        store.refreshCurrentAccount()
        await gate.open()

        let refreshFinished = await waitUntilIdle(store)
        let counts = await counter.snapshot()
        #expect(refreshFinished)
        #expect(counts.current == 1)
        #expect(counts.fullPaths == ["/new/codex"])
        #expect(store.accountRows.map(\.id) == ["/new/codex"])
    }

    @Test
    func testSourceChangeClearsRowsBeforeLoadingNewSource() async throws {
        let fixture = try makePreferencesFixture(
            CodexUsagePreferences(
                usageDataSource: .oauthAPI,
                refreshInterval: .thirtyMinutes,
                codexExecutablePath: "codex"
            )
        )
        defer { fixture.cleanup() }

        let operations = makeOperations(
            loadUsage: { usageDataSource, _ in
                switch usageDataSource {
                case .oauthAPI:
                    return makeLoadResult(accountKey: "managed-old", email: "old@example.com")
                case .cliRPC:
                    return makeLoadResult(accountKey: "cli-active", email: "CLI RPC")
                }
            }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )

        store.refresh()
        let initialRefreshFinished = await waitUntilIdle(store)
        #expect(initialRefreshFinished)
        #expect(store.accountRows.map(\.id) == ["managed-old"])

        store.updateUsageDataSource(.cliRPC)

        #expect(store.usageDataSource == .cliRPC)
        #expect(store.accountRows.isEmpty)
        #expect(store.activeAccountKey == nil)

        let sourceRefreshFinished = await waitUntilIdle(store)
        #expect(sourceRefreshFinished)
        #expect(store.accountRows.map(\.id) == ["cli-active"])
    }

    @Test
    func testExecutablePathChangeClearsRowsBeforeReloading() async throws {
        let fixture = try makePreferencesFixture(
            CodexUsagePreferences(
                usageDataSource: .cliRPC,
                refreshInterval: .thirtyMinutes,
                codexExecutablePath: "/old/codex"
            )
        )
        defer { fixture.cleanup() }

        let operations = makeOperations(
            loadUsage: { _, codexExecutablePath in
                makeLoadResult(
                    accountKey: codexExecutablePath,
                    email: codexExecutablePath
                )
            }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )

        store.refresh()
        let initialRefreshFinished = await waitUntilIdle(store)
        #expect(initialRefreshFinished)
        #expect(store.accountRows.map(\.id) == ["/old/codex"])

        store.updateCodexExecutablePath("/new/codex")

        #expect(store.codexExecutablePath == "/new/codex")
        #expect(store.accountRows.isEmpty)
        #expect(store.activeAccountKey == nil)

        let pathRefreshFinished = await waitUntilIdle(store)
        #expect(pathRefreshFinished)
        #expect(store.accountRows.map(\.id) == ["/new/codex"])
    }

    @Test
    func testCurrentAccountRowErrorPropagatesToStore() async throws {
        let fixture = try makePreferencesFixture(.defaults)
        defer { fixture.cleanup() }
        let expectedError = "Current account token was rejected."
        var result = makeLoadResult(
            accountKey: "managed-current",
            email: "current@example.com"
        )
        result.rows[0].errorMessage = expectedError
        result.errorMessage = expectedError
        result.didRefreshCurrentAccount = false
        let currentResult = result
        let operations = makeOperations(
            loadCurrentManagedAccountUsage: { currentResult }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )

        store.refreshCurrentAccount()

        let refreshFinished = await waitUntilIdle(store)
        #expect(refreshFinished)
        #expect(store.errorMessage == expectedError)
        #expect(store.accountRows.first?.errorMessage == expectedError)
    }

    @Test
    func testFailedActivationKeepsErrorAndDoesNotRefreshCurrentAccount() async throws {
        let fixture = try makePreferencesFixture(.defaults)
        defer { fixture.cleanup() }
        let counter = StoreOperationCounter()
        let existingResult = makeLoadResult(
            accountKey: "managed-current",
            email: "current@example.com"
        )
        let operations = makeOperations(
            loadCurrentManagedAccountUsage: {
                await counter.recordCurrentLoad()
                return existingResult
            },
            loadUsage: { _, _ in existingResult },
            activateManagedAccount: { _ in
                throw StoreTestError.activationFailed
            }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )
        store.refresh()
        let initialRefreshFinished = await waitUntilIdle(store)
        #expect(initialRefreshFinished)

        store.activateAccount("managed-other")

        let activationFinished = await waitUntilAccountActivationFinishes(store)
        let postActivationRefreshFinished = await waitUntilIdle(store)
        let currentLoadCount = await counter.currentLoadCount
        #expect(activationFinished)
        #expect(postActivationRefreshFinished)
        #expect(store.errorMessage == StoreTestError.activationFailed.localizedDescription)
        #expect(store.activeAccountKey == "managed-current")
        #expect(currentLoadCount == 0)
    }

    @Test
    func testImportedEmptyAccountSetClearsRowsWithoutAutomaticRefresh() async throws {
        let fixture = try makePreferencesFixture(.defaults)
        defer { fixture.cleanup() }
        let counter = StoreOperationCounter()
        let existing = makeLoadResult(
            accountKey: "managed-current",
            email: "current@example.com"
        )
        let operations = makeOperations(
            loadUsage: { _, path in
                await counter.recordFullLoad(path: path)
                return existing
            }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )
        store.refresh()
        #expect(await waitUntilIdle(store))
        #expect(store.accountRows.count == 1)

        try store.applyImportedConfiguration(
            .defaults,
            accountsSnapshot: CodexManagedAccountsSnapshot(
                schemaVersion: 1,
                activeAccountKey: nil,
                accounts: [],
                loadedAt: Date()
            )
        )

        let counts = await counter.snapshot()
        #expect(store.accountRows.isEmpty)
        #expect(store.activeAccountKey == nil)
        #expect(counts.fullPaths == ["codex"])
    }

    @Test
    func testImportedConfigurationDiscardsInFlightResultWithSamePreferences() async throws {
        let fixture = try makePreferencesFixture(.defaults)
        defer { fixture.cleanup() }
        let gate = StoreOperationGate()
        let operations = makeOperations(
            loadUsage: { _, _ in
                await gate.wait()
                return makeLoadResult(
                    accountKey: "stale-account",
                    email: "stale@example.com"
                )
            }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )

        store.refresh()
        await gate.waitUntilEntered()
        try store.applyImportedConfiguration(
            .defaults,
            accountsSnapshot: CodexManagedAccountsSnapshot(
                schemaVersion: 1,
                activeAccountKey: nil,
                accounts: [],
                loadedAt: Date()
            )
        )
        await gate.open()

        #expect(await waitUntilIdle(store))
        #expect(store.accountRows.isEmpty)
        #expect(store.activeAccountKey == nil)
    }

    @Test
    func testConfigurationTransferSuspendsAllStoreOperationsUntilEnded() async throws {
        let fixture = try makePreferencesFixture(.defaults)
        defer { fixture.cleanup() }
        let counter = StoreOperationCounter()
        let result = makeLoadResult(
            accountKey: "managed-current",
            email: "current@example.com"
        )
        let operations = makeOperations(
            loadCurrentManagedAccountUsage: {
                await counter.recordCurrentLoad()
                return result
            },
            loadUsage: { _, path in
                await counter.recordFullLoad(path: path)
                return result
            },
            loadSingleUsage: { accountKey, _, _ in
                await counter.recordSingleLoad()
                return CodexSingleAccountUsageLoadResult(
                    row: makeLoadResult(
                        accountKey: accountKey,
                        email: "single@example.com"
                    ).rows[0],
                    activeAccountKey: result.activeAccountKey,
                    didRefreshCurrentAccount: false
                )
            },
            activateManagedAccount: { _ in
                await counter.recordActivation()
            },
            addManagedAccount: { _ in
                await counter.recordAddition()
                return result
            },
            removeManagedAccount: { _ in
                await counter.recordRemoval()
                return result
            }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )

        #expect(store.beginConfigurationTransfer())
        store.refresh()
        store.refreshCurrentAccount()
        store.refreshAccountUsage("managed-other")
        store.activateAccount("managed-other")
        store.addAccount()
        store.removeAccount("managed-other")

        let suspendedCounts = await counter.snapshot()
        #expect(suspendedCounts.current == 0)
        #expect(suspendedCounts.fullPaths.isEmpty)
        #expect(suspendedCounts.single == 0)
        #expect(suspendedCounts.activation == 0)
        #expect(suspendedCounts.addition == 0)
        #expect(suspendedCounts.removal == 0)

        store.endConfigurationTransfer()
        store.refresh()
        #expect(await waitUntilIdle(store))
        let resumedCounts = await counter.snapshot()
        #expect(resumedCounts.fullPaths == ["codex"])
    }

    @Test
    func testConfigurationTransferCannotStartWhileRefreshIsInFlight() async throws {
        let fixture = try makePreferencesFixture(.defaults)
        defer { fixture.cleanup() }
        let gate = StoreOperationGate()
        let operations = makeOperations(
            loadUsage: { _, _ in
                await gate.wait()
                return makeLoadResult(
                    accountKey: "managed-current",
                    email: "current@example.com"
                )
            }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )

        store.refresh()
        await gate.waitUntilEntered()
        #expect(!store.beginConfigurationTransfer())
        await gate.open()
        #expect(await waitUntilIdle(store))
    }

    @Test
    func testFailedRefreshAfterAccountSwitchIsImmediatelyStale() async throws {
        let fixture = try makePreferencesFixture(.defaults)
        defer { fixture.cleanup() }
        let counter = StoreOperationCounter()
        let original = makeLoadResult(
            accountKey: "managed-a",
            email: "a@example.com"
        )
        let operations = makeOperations(
            loadCurrentManagedAccountUsage: {
                await counter.recordCurrentLoad()
                throw StoreTestError.refreshFailed
            },
            loadUsage: { _, _ in original },
            activateManagedAccount: { _ in }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )
        store.refresh()
        #expect(await waitUntilIdle(store))

        store.activateAccount("managed-b")
        #expect(await waitUntilAccountActivationFinishes(store))
        #expect(await waitUntilIdle(store))
        #expect(await counter.currentLoadCount == 1)

        store.refreshIfStale()
        #expect(await waitUntilIdle(store))
        #expect(await counter.currentLoadCount == 2)
    }

    @Test
    func testRemovingOtherAccountPreservesCurrentAccountError() async throws {
        let fixture = try makePreferencesFixture(.defaults)
        defer { fixture.cleanup() }
        let tokenError = "Current account token was rejected."
        var current = makeLoadResult(
            accountKey: "managed-current",
            email: "current@example.com"
        ).rows[0]
        current.errorMessage = tokenError
        var other = makeLoadResult(
            accountKey: "managed-other",
            email: "other@example.com"
        ).rows[0]
        other.account.isActive = false
        let initial = CodexUsageLoadResult(
            rows: [current, other],
            activeAccountKey: current.id,
            errorMessage: tokenError,
            didRefreshCurrentAccount: false
        )
        var remaining = current
        remaining.errorMessage = nil
        let removed = CodexUsageLoadResult(
            rows: [remaining],
            activeAccountKey: current.id
        )
        let operations = makeOperations(
            loadUsage: { _, _ in initial },
            removeManagedAccount: { _ in removed }
        )
        let store = CodexUsageStore(
            preferencesRepository: fixture.repository,
            operations: operations,
            startsAutomatically: false
        )
        store.refresh()
        #expect(await waitUntilIdle(store))

        store.removeAccount(other.id)
        #expect(await waitUntilAccountRemovalFinishes(store))

        #expect(store.errorMessage == tokenError)
        #expect(store.accountRows.map(\.id) == [current.id])
        #expect(store.accountRows[0].errorMessage == tokenError)
    }
}

private enum StoreTestError: LocalizedError {
    case unexpectedOperation
    case activationFailed
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedOperation:
            return "Unexpected store operation."
        case .activationFailed:
            return "Activation failed for testing."
        case .refreshFailed:
            return "Refresh failed for testing."
        }
    }
}

private actor StoreOperationCounter {
    private(set) var currentLoadCount = 0
    private var fullLoadPaths: [String] = []
    private var singleLoadCount = 0
    private var activationCount = 0
    private var additionCount = 0
    private var removalCount = 0

    func recordCurrentLoad() {
        currentLoadCount += 1
    }

    func recordFullLoad(path: String) {
        fullLoadPaths.append(path)
    }

    func recordSingleLoad() {
        singleLoadCount += 1
    }

    func recordActivation() {
        activationCount += 1
    }

    func recordAddition() {
        additionCount += 1
    }

    func recordRemoval() {
        removalCount += 1
    }

    func snapshot() -> (
        current: Int,
        fullPaths: [String],
        single: Int,
        activation: Int,
        addition: Int,
        removal: Int
    ) {
        (
            currentLoadCount,
            fullLoadPaths,
            singleLoadCount,
            activationCount,
            additionCount,
            removalCount
        )
    }
}

private actor StoreOperationGate {
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasEntered = false

    func wait() async {
        hasEntered = true
        enteredContinuations.forEach { $0.resume() }
        enteredContinuations.removeAll()

        await withCheckedContinuation { continuation in
            openContinuation = continuation
        }
    }

    func open() {
        openContinuation?.resume()
        openContinuation = nil
    }

    func waitUntilEntered() async {
        guard !hasEntered else {
            return
        }

        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }
}

@MainActor
private struct PreferencesFixture {
    var repository: CodexUsagePreferencesRepository
    var suiteName: String

    func cleanup() {
        repository.defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func makePreferencesFixture(
    _ preferences: CodexUsagePreferences
) throws -> PreferencesFixture {
    let suiteName = "CodexUsageStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let repository = CodexUsagePreferencesRepository(defaults: defaults)
    try repository.save(preferences)
    return PreferencesFixture(repository: repository, suiteName: suiteName)
}

private func makeOperations(
    loadCurrentManagedAccountUsage: @escaping @Sendable () async throws -> CodexUsageLoadResult = {
        throw StoreTestError.unexpectedOperation
    },
    loadUsage: @escaping @Sendable (
        CodexUsageDataSource,
        String
    ) async throws -> CodexUsageLoadResult = { _, _ in
        throw StoreTestError.unexpectedOperation
    },
    loadSingleUsage: @escaping @Sendable (
        String,
        CodexUsageDataSource,
        String
    ) async throws -> CodexSingleAccountUsageLoadResult = { _, _, _ in
        throw StoreTestError.unexpectedOperation
    },
    activateManagedAccount: @escaping @Sendable (String) async throws -> Void = { _ in
        throw StoreTestError.unexpectedOperation
    },
    addManagedAccount: @escaping @Sendable (String) async throws -> CodexUsageLoadResult = { _ in
        throw StoreTestError.unexpectedOperation
    },
    removeManagedAccount: @escaping @Sendable (String) async throws -> CodexUsageLoadResult = { _ in
        throw StoreTestError.unexpectedOperation
    }
) -> CodexUsageStoreOperations {
    CodexUsageStoreOperations(
        loadCurrentManagedAccountUsage: loadCurrentManagedAccountUsage,
        loadUsage: loadUsage,
        loadSingleUsage: loadSingleUsage,
        activateManagedAccount: activateManagedAccount,
        addManagedAccount: addManagedAccount,
        removeManagedAccount: removeManagedAccount
    )
}

private func makeLoadResult(
    accountKey: String,
    email: String
) -> CodexUsageLoadResult {
    let account = CodexManagedAccount(
        accountKey: accountKey,
        chatgptAccountID: "account-\(accountKey)",
        chatgptUserID: "user-\(accountKey)",
        email: email,
        alias: "",
        accountName: nil,
        planType: "plus",
        authMode: "chatgpt",
        createdAt: nil,
        lastUsedAt: nil,
        lastUsageAt: nil,
        storedUsage: nil,
        isActive: true
    )
    let snapshot = UsageSnapshot(
        account: account.codexAccount,
        sessionWindow: nil,
        weeklyWindow: nil,
        updatedAt: nil,
        sourceDescription: "Test"
    )
    return CodexUsageLoadResult(
        rows: [
            AccountUsageRow(
                account: account,
                snapshot: snapshot,
                errorMessage: nil,
                isRefreshing: false
            )
        ],
        activeAccountKey: accountKey,
        didRefreshCurrentAccount: true
    )
}

@MainActor
private func waitUntilIdle(_ store: CodexUsageStore) async -> Bool {
    for _ in 0..<1_000 {
        if !store.isRefreshing {
            return true
        }
        await Task.yield()
    }
    return !store.isRefreshing
}

@MainActor
private func waitUntilAccountActivationFinishes(_ store: CodexUsageStore) async -> Bool {
    for _ in 0..<1_000 {
        if !store.isActivatingAccount {
            return true
        }
        await Task.yield()
    }
    return !store.isActivatingAccount
}

@MainActor
private func waitUntilAccountRemovalFinishes(_ store: CodexUsageStore) async -> Bool {
    for _ in 0..<1_000 {
        if !store.isRemovingAccount {
            return true
        }
        await Task.yield()
    }
    return !store.isRemovingAccount
}

import Foundation
import OSLog

enum CodexPendingRefreshKind: Equatable {
    case current
    case all

    func merged(with incoming: CodexPendingRefreshKind) -> CodexPendingRefreshKind {
        self == .all || incoming == .all ? .all : .current
    }
}

struct CodexUsageLoadResult: Sendable {
    var rows: [AccountUsageRow]
    var activeAccountKey: String?
    var errorMessage: String? = nil
    var didRefreshCurrentAccount = false
}

struct CodexSingleAccountUsageLoadResult: Sendable {
    var row: AccountUsageRow
    var activeAccountKey: String?
    var didRefreshCurrentAccount: Bool
}

struct CodexUsageStoreOperations: Sendable {
    var loadCurrentManagedAccountUsage: @Sendable () async throws -> CodexUsageLoadResult
    var loadUsage: @Sendable (
        _ usageDataSource: CodexUsageDataSource,
        _ codexExecutablePath: String
    ) async throws -> CodexUsageLoadResult
    var loadSingleUsage: @Sendable (
        _ accountKey: String,
        _ usageDataSource: CodexUsageDataSource,
        _ codexExecutablePath: String
    ) async throws -> CodexSingleAccountUsageLoadResult
    var activateManagedAccount: @Sendable (_ accountKey: String) async throws -> Void
    var addManagedAccount: @Sendable (_ codexExecutablePath: String) async throws -> CodexUsageLoadResult
    var removeManagedAccount: @Sendable (_ accountKey: String) async throws -> CodexUsageLoadResult
}

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var accountRows: [AccountUsageRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var isActivatingAccount = false
    @Published private(set) var isAddingAccount = false
    @Published private(set) var isRemovingAccount = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeAccountKey: String?
    @Published private(set) var usageDataSource: CodexUsageDataSource
    @Published private(set) var refreshInterval: CodexRefreshInterval
    @Published private(set) var codexExecutablePath: String

    private struct FetchConfiguration: Equatable {
        var usageDataSource: CodexUsageDataSource
        var codexExecutablePath: String
        var generation: UInt64 = 0
    }

    private enum RefreshTrigger: String {
        case appStart
        case manual
        case timer
        case staleMenuOpen
        case settingsChange
        case pathChange
        case accountSwitch
        case manualAccount
    }

    private struct PendingRefresh {
        var kind: CodexPendingRefreshKind
        var trigger: RefreshTrigger
    }

    private struct CurrentAccountRefreshState {
        var accountKey: String
        var completedAt: Date
    }

    private enum AccountUsageCredentialSource {
        case managedSnapshot
        case activeAuthReadOnly
    }

    private let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "UsageStore"
    )
    nonisolated private static let backgroundLogger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "UsageStore"
    )
    nonisolated private static let liveOperations = CodexUsageStoreOperations(
        loadCurrentManagedAccountUsage: {
            try await CodexUsageStore.loadCurrentManagedAccountUsage()
        },
        loadUsage: { usageDataSource, codexExecutablePath in
            try await CodexUsageStore.loadUsage(
                configuration: FetchConfiguration(
                    usageDataSource: usageDataSource,
                    codexExecutablePath: codexExecutablePath
                )
            )
        },
        loadSingleUsage: { accountKey, usageDataSource, codexExecutablePath in
            try await CodexUsageStore.loadSingleUsage(
                accountKey: accountKey,
                configuration: FetchConfiguration(
                    usageDataSource: usageDataSource,
                    codexExecutablePath: codexExecutablePath
                )
            )
        },
        activateManagedAccount: { accountKey in
            try await CodexUsageStore.activateManagedAccount(accountKey: accountKey)
        },
        addManagedAccount: { codexExecutablePath in
            try await CodexUsageStore.addManagedAccount(
                codexExecutablePath: codexExecutablePath
            )
        },
        removeManagedAccount: { accountKey in
            try await CodexUsageStore.removeManagedAccount(accountKey: accountKey)
        }
    )
    private let preferencesRepository: CodexUsagePreferencesRepository
    private let operations: CodexUsageStoreOperations
    private var autoRefreshTask: Task<Void, Never>?
    private var pendingRefresh: PendingRefresh?
    private var currentAccountRefreshState: CurrentAccountRefreshState?
    private var fetchGeneration: UInt64 = 0
    private var isConfigurationTransferSuspended = false

    private var isAccountManagementBusy: Bool {
        isAddingAccount || isRemovingAccount || isActivatingAccount
    }

    var activeUsageRow: AccountUsageRow? {
        if let activeAccountKey,
           let active = accountRows.first(where: { $0.id == activeAccountKey })
        {
            return active
        }
        if let active = accountRows.first(where: { $0.isActive }) {
            return active
        }
        if usageDataSource == .cliRPC {
            return accountRows.first
        }
        return nil
    }

    var snapshot: UsageSnapshot {
        activeUsageRow?.snapshot ?? UsageSnapshot.empty(sourceDescription: usageDataSource.title)
    }

    convenience init(
        preferencesRepository: CodexUsagePreferencesRepository = CodexUsagePreferencesRepository()
    ) {
        self.init(
            preferencesRepository: preferencesRepository,
            operations: Self.liveOperations,
            startsAutomatically: true
        )
    }

    init(
        preferencesRepository: CodexUsagePreferencesRepository,
        operations: CodexUsageStoreOperations,
        startsAutomatically: Bool
    ) {
        self.preferencesRepository = preferencesRepository
        self.operations = operations
        let preferences = preferencesRepository.load()
        usageDataSource = preferences.usageDataSource
        refreshInterval = preferences.refreshInterval
        codexExecutablePath = preferences.codexExecutablePath

        if startsAutomatically {
            performStartupMaintenance()
            refreshCurrentAccount(trigger: .appStart)
            startAutoRefresh()
        }
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    var preferences: CodexUsagePreferences {
        CodexUsagePreferences(
            usageDataSource: usageDataSource,
            refreshInterval: refreshInterval,
            codexExecutablePath: codexExecutablePath
        )
    }

    func updateUsageDataSource(_ source: CodexUsageDataSource) {
        guard source != usageDataSource else { return }
        do {
            var next = preferences
            next.usageDataSource = source
            try persistAndApply(next, refreshReason: .settingsChange)
            logger.info("data source changed source=\(source.rawValue, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("data source change failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
        }
    }

    func updateRefreshInterval(_ interval: CodexRefreshInterval) {
        guard interval != refreshInterval else { return }
        do {
            var next = preferences
            next.refreshInterval = interval
            try preferencesRepository.save(next)
            refreshInterval = interval
            startAutoRefresh()
            logger.info("refresh interval changed seconds=\(interval.rawValue, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("refresh interval change failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
        }
    }

    func applyImportedConfiguration(
        _ imported: CodexUsagePreferences,
        accountsSnapshot: CodexManagedAccountsSnapshot
    ) throws {
        let validated = try imported.validated()
        try preferencesRepository.save(validated)
        usageDataSource = validated.usageDataSource
        refreshInterval = validated.refreshInterval
        codexExecutablePath = validated.codexExecutablePath
        fetchGeneration &+= 1
        pendingRefresh = nil
        currentAccountRefreshState = nil
        errorMessage = nil

        if validated.usageDataSource == .oauthAPI {
            let stored = Self.storedRows(from: accountsSnapshot)
            accountRows = stored.rows
            activeAccountKey = stored.activeAccountKey
            reconcileActiveAccount()
        } else {
            accountRows = []
            activeAccountKey = nil
        }
        startAutoRefresh()
        logger.info("imported preferences applied source=\(validated.usageDataSource.rawValue, privacy: .public) refresh_seconds=\(validated.refreshInterval.rawValue, privacy: .public)")
    }

    @discardableResult
    func beginConfigurationTransfer() -> Bool {
        guard !isConfigurationTransferSuspended else {
            logger.info("configuration transfer suspension ignored reason=already_suspended")
            return false
        }
        guard !isRefreshing && !isAccountManagementBusy else {
            logger.info("configuration transfer suspension rejected reason=store_busy")
            return false
        }

        isConfigurationTransferSuspended = true
        fetchGeneration &+= 1
        pendingRefresh = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        logger.info("configuration transfer suspension started")
        return true
    }

    func endConfigurationTransfer() {
        guard isConfigurationTransferSuspended else { return }
        isConfigurationTransferSuspended = false
        startAutoRefresh()
        logger.info("configuration transfer suspension ended")
    }

    func refresh() {
        refresh(trigger: .manual)
    }

    func refreshCurrentAccount() {
        refreshCurrentAccount(trigger: .manualAccount)
    }

    func refreshAccountUsage(_ accountKey: String) {
        refreshAccount(accountKey: accountKey, trigger: .manualAccount)
    }

    private func refreshCurrentAccount(trigger: RefreshTrigger) {
        guard !isConfigurationTransferSuspended else {
            logger.info("current account refresh ignored during configuration transfer trigger=\(trigger.rawValue, privacy: .public)")
            return
        }
        if usageDataSource == .oauthAPI {
            refreshStoredCurrentAccount(trigger: trigger)
            return
        }
        guard let accountKey = currentAccountKey else {
            if usageDataSource == .cliRPC {
                refresh(trigger: trigger)
                return
            }
            errorMessage = "No current Codex account is available to refresh."
            logger.error("current account refresh failed reason=no_current_account trigger=\(trigger.rawValue, privacy: .public)")
            return
        }
        refreshAccount(accountKey: accountKey, trigger: trigger)
    }

    private func refreshStoredCurrentAccount(trigger: RefreshTrigger) {
        logger.info("stored current account refresh requested trigger=\(trigger.rawValue, privacy: .public)")
        guard !blockRefreshIfAccountManagementIsBusy(trigger: trigger) else {
            enqueueRefresh(.current, trigger: trigger)
            return
        }
        guard !isRefreshing else {
            enqueueRefresh(.current, trigger: trigger)
            logger.info("stored current account refresh queued trigger=\(trigger.rawValue, privacy: .public)")
            return
        }

        isRefreshing = true
        let configuration = currentFetchConfiguration

        Task {
            do {
                let result = try await operations.loadCurrentManagedAccountUsage()
                if configuration == currentFetchConfiguration {
                    accountRows = result.rows
                    activeAccountKey = result.activeAccountKey
                    reconcileActiveAccount()
                    errorMessage = result.errorMessage
                    if result.didRefreshCurrentAccount,
                       let activeAccountKey
                    {
                        currentAccountRefreshState = CurrentAccountRefreshState(
                            accountKey: activeAccountKey,
                            completedAt: Date()
                        )
                    }
                    logger.info("stored current account refresh completed rows=\(result.rows.count, privacy: .public)")
                } else {
                    logger.info("discarded stale current-account refresh result")
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("stored current account refresh failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    logger.info("discarded stale current-account refresh error")
                }
            }

            isRefreshing = false
            runPendingRefreshIfPossible()
        }
    }

    private func refresh(trigger: RefreshTrigger) {
        logger.info("refresh requested trigger=\(trigger.rawValue, privacy: .public) source=\(self.usageDataSource.rawValue, privacy: .public)")
        guard !isConfigurationTransferSuspended else {
            logger.info("refresh ignored during configuration transfer trigger=\(trigger.rawValue, privacy: .public)")
            return
        }
        guard !blockRefreshIfAccountManagementIsBusy(trigger: trigger) else {
            enqueueRefresh(.all, trigger: trigger)
            return
        }
        guard !isRefreshing else {
            enqueueRefresh(.all, trigger: trigger)
            logger.info("refresh queued trigger=\(trigger.rawValue, privacy: .public)")
            return
        }

        isRefreshing = true
        isRefreshingAll = true
        let configuration = currentFetchConfiguration

        Task {
            do {
                let result = try await operations.loadUsage(
                    configuration.usageDataSource,
                    configuration.codexExecutablePath
                )
                if configuration == currentFetchConfiguration {
                    accountRows = result.rows
                    activeAccountKey = result.activeAccountKey
                    reconcileActiveAccount()
                    errorMessage = result.errorMessage
                    if result.didRefreshCurrentAccount,
                       let activeAccountKey
                    {
                        currentAccountRefreshState = CurrentAccountRefreshState(
                            accountKey: activeAccountKey,
                            completedAt: Date()
                        )
                    }
                    logger.info("refresh completed rows=\(result.rows.count, privacy: .public)")
                } else {
                    logger.info("discarded stale all-account refresh result")
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("refresh failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    logger.info("discarded stale all-account refresh error")
                }
            }

            isRefreshingAll = false
            isRefreshing = false
            runPendingRefreshIfPossible()
        }
    }

    private func refreshAccount(accountKey: String, trigger: RefreshTrigger) {
        logger.info("account refresh requested trigger=\(trigger.rawValue, privacy: .public) key=\(accountKey, privacy: .private)")
        guard !isConfigurationTransferSuspended else {
            logger.info("account refresh ignored during configuration transfer trigger=\(trigger.rawValue, privacy: .public) key=\(accountKey, privacy: .private)")
            return
        }
        guard !blockRefreshIfAccountManagementIsBusy(trigger: trigger) else { return }
        guard !isRefreshing else {
            logger.info("account refresh ignored because another refresh is active key=\(accountKey, privacy: .private)")
            return
        }

        isRefreshing = true
        setAccountRefreshing(accountKey: accountKey, isRefreshing: true)
        let configuration = currentFetchConfiguration

        Task {
            do {
                let result = try await operations.loadSingleUsage(
                    accountKey,
                    configuration.usageDataSource,
                    configuration.codexExecutablePath
                )
                if configuration == currentFetchConfiguration {
                    replaceAccountRow(result.row, activeAccountKey: result.activeAccountKey)
                    errorMessage = result.row.errorMessage
                    if result.didRefreshCurrentAccount,
                       let activeAccountKey = result.activeAccountKey
                    {
                        currentAccountRefreshState = CurrentAccountRefreshState(
                            accountKey: activeAccountKey,
                            completedAt: Date()
                        )
                    }
                    logger.info("account refresh completed key=\(accountKey, privacy: .private)")
                } else {
                    logger.info("discarded stale single-account refresh result key=\(accountKey, privacy: .private)")
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("account refresh failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    logger.info("discarded stale single-account refresh error key=\(accountKey, privacy: .private)")
                }
            }

            setAccountRefreshing(accountKey: accountKey, isRefreshing: false)
            isRefreshing = false
            runPendingRefreshIfPossible()
        }
    }

    func refreshIfStale() {
        guard !isRefreshing else { return }
        guard let currentAccountKey,
              let currentAccountRefreshState,
              currentAccountRefreshState.accountKey == currentAccountKey
        else {
            refreshCurrentAccount(trigger: .staleMenuOpen)
            return
        }
        if Date().timeIntervalSince(currentAccountRefreshState.completedAt)
            >= TimeInterval(refreshInterval.rawValue)
        {
            refreshCurrentAccount(trigger: .staleMenuOpen)
        }
    }

    func updateCodexExecutablePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = preferences
        next.codexExecutablePath = trimmed.isEmpty ? "codex" : trimmed
        do {
            try persistAndApply(next, refreshReason: .pathChange)
            logger.info("codex executable path changed")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("codex executable path change failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
        }
    }

    func resetCodexExecutablePath() {
        updateCodexExecutablePath("codex")
    }

    func activateAccount(_ accountKey: String) {
        guard !isConfigurationTransferSuspended else {
            errorMessage = "Finish or cancel the configuration import before switching accounts."
            logger.info("account activation blocked during configuration transfer key=\(accountKey, privacy: .private)")
            return
        }
        guard usageDataSource == .oauthAPI else {
            errorMessage = "Account switching is available only for managed accounts."
            return
        }
        guard !isActivatingAccount else { return }
        guard !isRefreshing else {
            errorMessage = "Wait for the current quota refresh to finish before switching accounts."
            logger.info("account activation blocked during refresh key=\(accountKey, privacy: .private)")
            return
        }
        guard !isAddingAccount && !isRemovingAccount else {
            errorMessage = "Wait for the current account operation to finish before switching accounts."
            logger.info("account activation blocked during account operation key=\(accountKey, privacy: .private)")
            return
        }

        isActivatingAccount = true
        let configuration = currentFetchConfiguration
        logger.info("account activation requested key=\(accountKey, privacy: .private)")

        Task {
            var activationSucceeded = false
            do {
                try await operations.activateManagedAccount(accountKey)
                activationSucceeded = true
                if configuration == currentFetchConfiguration {
                    activeAccountKey = accountKey
                    accountRows = accountRows.map { row in
                        var next = row
                        next.account.isActive = row.id == accountKey
                        return next
                    }
                    errorMessage = nil
                    logger.info("account activation completed key=\(accountKey, privacy: .private)")
                } else {
                    logger.info("discarded stale account activation result key=\(accountKey, privacy: .private)")
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("account activation failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    logger.info("discarded stale account activation error key=\(accountKey, privacy: .private)")
                }
            }

            isActivatingAccount = false
            if activationSucceeded, configuration == currentFetchConfiguration {
                enqueueRefresh(.current, trigger: .accountSwitch)
            }
            runPendingRefreshIfPossible()
        }
    }

    func addAccount() {
        guard !isConfigurationTransferSuspended else {
            errorMessage = "Finish or cancel the configuration import before adding an account."
            logger.info("account login blocked during configuration transfer")
            return
        }
        guard usageDataSource == .oauthAPI else {
            errorMessage = "Account login is available only for managed accounts."
            return
        }
        guard !isAddingAccount else { return }
        guard !isRefreshing && !isActivatingAccount && !isRemovingAccount else {
            errorMessage = "Wait for the current account operation or quota refresh to finish before adding an account."
            logger.info("account login blocked by busy state")
            return
        }

        isAddingAccount = true
        errorMessage = nil
        let executablePath = codexExecutablePath
        let configuration = currentFetchConfiguration
        logger.info("account login requested")

        Task {
            do {
                let result = try await operations.addManagedAccount(executablePath)
                if configuration == currentFetchConfiguration {
                    accountRows = result.rows
                    activeAccountKey = result.activeAccountKey
                    reconcileActiveAccount()
                    errorMessage = result.errorMessage
                    if result.didRefreshCurrentAccount,
                       let activeAccountKey
                    {
                        currentAccountRefreshState = CurrentAccountRefreshState(
                            accountKey: activeAccountKey,
                            completedAt: Date()
                        )
                    }
                    logger.info("account login completed rows=\(result.rows.count, privacy: .public)")
                } else {
                    logger.info("discarded stale account login result")
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("account login failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    logger.info("discarded stale account login error")
                }
            }

            isAddingAccount = false
            runPendingRefreshIfPossible()
        }
    }

    func removeAccount(_ accountKey: String) {
        guard !isConfigurationTransferSuspended else {
            errorMessage = "Finish or cancel the configuration import before removing an account."
            logger.info("account removal blocked during configuration transfer key=\(accountKey, privacy: .private)")
            return
        }
        guard usageDataSource == .oauthAPI else {
            errorMessage = "Account removal is available only for managed accounts."
            return
        }
        guard !isCurrentManagedAccount(accountKey) else {
            errorMessage = "The current Codex Usage account cannot be removed. Switch to another account first."
            logger.info("account removal blocked for active account key=\(accountKey, privacy: .private)")
            return
        }
        guard !isRemovingAccount else { return }
        guard !isRefreshing && !isAddingAccount && !isActivatingAccount else {
            errorMessage = "Wait for the current account operation or quota refresh to finish before removing an account."
            logger.info("account removal blocked by busy state key=\(accountKey, privacy: .private)")
            return
        }

        isRemovingAccount = true
        let configuration = currentFetchConfiguration
        let previousActiveAccountKey = activeAccountKey
        let previousErrorMessage = errorMessage
        logger.info("account removal requested key=\(accountKey, privacy: .private)")

        Task {
            do {
                let result = try await operations.removeManagedAccount(accountKey)
                if configuration == currentFetchConfiguration {
                    let previousRows = Dictionary(
                        uniqueKeysWithValues: accountRows.map { ($0.id, $0) }
                    )
                    accountRows = result.rows.map { resultRow in
                        previousRows[resultRow.id] ?? resultRow
                    }
                    activeAccountKey = result.activeAccountKey
                    reconcileActiveAccount()
                    accountRows = accountRows.map { row in
                        var next = row
                        next.account.isActive = next.id == activeAccountKey
                        return next
                    }
                    errorMessage = activeAccountKey == previousActiveAccountKey
                        ? previousErrorMessage
                        : activeUsageRow?.errorMessage
                    logger.info("account removal completed key=\(accountKey, privacy: .private)")
                } else {
                    logger.info("discarded stale account removal result key=\(accountKey, privacy: .private)")
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("account removal failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    logger.info("discarded stale account removal error key=\(accountKey, privacy: .private)")
                }
            }

            isRemovingAccount = false
            runPendingRefreshIfPossible()
        }
    }

    private func isCurrentManagedAccount(_ accountKey: String) -> Bool {
        activeAccountKey == accountKey
            || accountRows.first(where: { $0.id == accountKey })?.isActive == true
    }

    private var currentFetchConfiguration: FetchConfiguration {
        FetchConfiguration(
            usageDataSource: usageDataSource,
            codexExecutablePath: codexExecutablePath,
            generation: fetchGeneration
        )
    }

    private func persistAndApply(
        _ nextPreferences: CodexUsagePreferences,
        refreshReason: RefreshTrigger
    ) throws {
        let validated = try nextPreferences.validated()
        try preferencesRepository.save(validated)

        let fetchConfigurationChanged = usageDataSource != validated.usageDataSource
            || codexExecutablePath != validated.codexExecutablePath
        let intervalChanged = refreshInterval != validated.refreshInterval

        usageDataSource = validated.usageDataSource
        refreshInterval = validated.refreshInterval
        codexExecutablePath = validated.codexExecutablePath

        if fetchConfigurationChanged {
            fetchGeneration &+= 1
            pendingRefresh = nil
            accountRows = []
            activeAccountKey = nil
            currentAccountRefreshState = nil
            errorMessage = nil
        }
        if intervalChanged {
            startAutoRefresh()
        }
        refresh(trigger: refreshReason)
    }

    private func enqueueRefresh(
        _ kind: CodexPendingRefreshKind,
        trigger: RefreshTrigger
    ) {
        guard !isConfigurationTransferSuspended else {
            logger.info("refresh queue ignored during configuration transfer kind=\(String(describing: kind), privacy: .public) trigger=\(trigger.rawValue, privacy: .public)")
            return
        }
        if let pendingRefresh {
            self.pendingRefresh = PendingRefresh(
                kind: pendingRefresh.kind.merged(with: kind),
                trigger: kind == .all ? trigger : pendingRefresh.trigger
            )
        } else {
            pendingRefresh = PendingRefresh(kind: kind, trigger: trigger)
        }
        logger.info("refresh intent queued kind=\(self.pendingRefresh?.kind == .all ? "all" : "current", privacy: .public) trigger=\(trigger.rawValue, privacy: .public)")
    }

    private func runPendingRefreshIfPossible() {
        guard !isRefreshing, !isAccountManagementBusy, let pendingRefresh else { return }
        self.pendingRefresh = nil
        logger.info("running queued refresh kind=\(pendingRefresh.kind == .all ? "all" : "current", privacy: .public) trigger=\(pendingRefresh.trigger.rawValue, privacy: .public)")
        switch pendingRefresh.kind {
        case .current:
            refreshCurrentAccount(trigger: pendingRefresh.trigger)
        case .all:
            refresh(trigger: pendingRefresh.trigger)
        }
    }

    private func blockRefreshIfAccountManagementIsBusy(trigger: RefreshTrigger) -> Bool {
        guard isAccountManagementBusy else { return false }
        if trigger == .manual || trigger == .manualAccount || trigger == .settingsChange || trigger == .pathChange {
            errorMessage = "Wait for the current account operation to finish before refreshing quota."
        }
        logger.info("refresh blocked during account operation trigger=\(trigger.rawValue, privacy: .public)")
        return true
    }

    private var currentAccountKey: String? {
        if let activeAccountKey,
           accountRows.contains(where: { $0.id == activeAccountKey })
        {
            return activeAccountKey
        }
        if let active = accountRows.first(where: { $0.isActive }) {
            return active.id
        }
        if usageDataSource == .cliRPC {
            return accountRows.first?.id
        }
        return nil
    }

    nonisolated private static func loadUsage(
        configuration: FetchConfiguration
    ) async throws -> CodexUsageLoadResult {
        switch configuration.usageDataSource {
        case .oauthAPI:
            return try await Self.loadManagedAccountsUsage()
        case .cliRPC:
            let snapshot = try await Self.loadCLISnapshot(codexExecutablePath: configuration.codexExecutablePath)
            let account = CodexManagedAccount(
                accountKey: "cli-active",
                chatgptAccountID: "",
                chatgptUserID: "",
                email: snapshot.account?.email ?? "CLI RPC",
                alias: "",
                accountName: nil,
                planType: snapshot.account?.planType,
                authMode: snapshot.account?.type ?? "cli",
                createdAt: nil,
                lastUsedAt: nil,
                lastUsageAt: snapshot.updatedAt,
                storedUsage: snapshot,
                isActive: true
            )
            return CodexUsageLoadResult(
                rows: [AccountUsageRow(
                    account: account,
                    snapshot: snapshot,
                    errorMessage: nil,
                    isRefreshing: false
                )],
                activeAccountKey: account.accountKey,
                didRefreshCurrentAccount: true
            )
        }
    }

    nonisolated private static func loadSingleUsage(
        accountKey: String,
        configuration: FetchConfiguration
    ) async throws -> CodexSingleAccountUsageLoadResult {
        switch configuration.usageDataSource {
        case .oauthAPI:
            return try await Self.loadManagedAccountsUsage(accountKey: accountKey)
        case .cliRPC:
            let snapshot = try await Self.loadCLISnapshot(codexExecutablePath: configuration.codexExecutablePath)
            let account = CodexManagedAccount(
                accountKey: "cli-active",
                chatgptAccountID: "",
                chatgptUserID: "",
                email: snapshot.account?.email ?? "CLI RPC",
                alias: "",
                accountName: nil,
                planType: snapshot.account?.planType,
                authMode: snapshot.account?.type ?? "cli",
                createdAt: nil,
                lastUsedAt: nil,
                lastUsageAt: snapshot.updatedAt,
                storedUsage: snapshot,
                isActive: true
            )
            return CodexSingleAccountUsageLoadResult(
                row: AccountUsageRow(
                    account: account,
                    snapshot: snapshot,
                    errorMessage: nil,
                    isRefreshing: false
                ),
                activeAccountKey: account.accountKey,
                didRefreshCurrentAccount: true
            )
        }
    }

    nonisolated private static func loadManagedAccountsUsage() async throws -> CodexUsageLoadResult {
        let accountStore = CodexUsageAccountStore()
        var activeAccountKey = try accountStore.managedAccountKeyForActiveAuth()
        let registry = try accountStore.loadSnapshot(markingActiveAccountKey: activeAccountKey)
        guard !registry.accounts.isEmpty else {
            throw CodexUsageAccountStoreError.noManagedAccounts
        }

        var rows: [AccountUsageRow] = []
        rows.reserveCapacity(registry.accounts.count)
        let usageClient = CodexOAuthUsageClient()

        for account in registry.accounts {
            activeAccountKey = try accountStore.managedAccountKeyForActiveAuth()
            guard account.accountKey != activeAccountKey else {
                Self.backgroundLogger.info("managed account batch refresh skipped current account key_fp=\(LogFingerprint.account(account.accountKey), privacy: .public) key=\(account.accountKey, privacy: .private)")
                rows.append(Self.storedRow(for: account))
                continue
            }

            rows.append(
                await Self.loadManagedAccountRow(
                    account: account,
                    accountStore: accountStore,
                    usageClient: usageClient,
                    credentialSource: .managedSnapshot
                )
            )
        }

        activeAccountKey = try accountStore.managedAccountKeyForActiveAuth()
        rows = Self.markRows(rows, activeAccountKey: activeAccountKey)
        return CodexUsageLoadResult(rows: rows, activeAccountKey: activeAccountKey)
    }

    nonisolated private static func loadManagedAccountsUsage(
        accountKey: String
    ) async throws -> CodexSingleAccountUsageLoadResult {
        let accountStore = CodexUsageAccountStore()
        let activeAccountKey = try accountStore.managedAccountKeyForActiveAuth()
        let registry = try accountStore.loadSnapshot(markingActiveAccountKey: activeAccountKey)
        guard let account = registry.accounts.first(where: { $0.accountKey == accountKey }) else {
            throw CodexUsageAccountStoreError.accountNotFound
        }

        let usageClient = CodexOAuthUsageClient()
        let row = await Self.loadManagedAccountRow(
            account: account,
            accountStore: accountStore,
            usageClient: usageClient,
            credentialSource: account.accountKey == activeAccountKey
                ? .activeAuthReadOnly
                : .managedSnapshot
        )
        let finalActiveAccountKey = try accountStore.managedAccountKeyForActiveAuth()
        return CodexSingleAccountUsageLoadResult(
            row: row,
            activeAccountKey: finalActiveAccountKey,
            didRefreshCurrentAccount: accountKey == finalActiveAccountKey
                && activeAccountKey == finalActiveAccountKey
                && row.errorMessage == nil
        )
    }

    nonisolated private static func loadCurrentManagedAccountUsage() async throws -> CodexUsageLoadResult {
        let accountStore = CodexUsageAccountStore()
        let activeAccountKey = try accountStore.managedAccountKeyForActiveAuth()
        let registry = try accountStore.loadSnapshot(markingActiveAccountKey: activeAccountKey)
        guard !registry.accounts.isEmpty else {
            throw CodexUsageAccountStoreError.noManagedAccounts
        }

        var result = Self.storedRows(from: registry)
        guard let activeAccountKey else {
            result.errorMessage = "Current Codex auth is not one of the managed accounts. Switch to a managed account or add the current Codex account."
            return result
        }

        guard let account = registry.accounts.first(where: { $0.accountKey == activeAccountKey })
        else {
            result.activeAccountKey = nil
            result.errorMessage = "The selected managed account is missing. Choose an account from Accounts."
            return result
        }

        let usageClient = CodexOAuthUsageClient()
        let refreshedRow = await Self.loadManagedAccountRow(
            account: account,
            accountStore: accountStore,
            usageClient: usageClient,
            credentialSource: .activeAuthReadOnly
        )
        let finalActiveAccountKey = try accountStore.managedAccountKeyForActiveAuth()
        guard finalActiveAccountKey == activeAccountKey else {
            let latestRegistry = try accountStore.loadSnapshot(
                markingActiveAccountKey: finalActiveAccountKey
            )
            var changedResult = Self.storedRows(from: latestRegistry)
            changedResult.errorMessage = "Current Codex account changed while quota was refreshing. Refresh again for the new account."
            return changedResult
        }
        if let index = result.rows.firstIndex(where: { $0.id == refreshedRow.id }) {
            result.rows[index] = refreshedRow
        } else {
            result.rows.append(refreshedRow)
        }
        result.activeAccountKey = activeAccountKey
        result.errorMessage = refreshedRow.errorMessage
        result.didRefreshCurrentAccount = refreshedRow.errorMessage == nil
        result.rows = result.rows.map { row in
            var next = row
            next.account.isActive = next.id == activeAccountKey
            return next
        }
        return result
    }

    nonisolated private static func loadManagedAccountRow(
        account: CodexManagedAccount,
        accountStore: CodexUsageAccountStore,
        usageClient: CodexOAuthUsageClient,
        credentialSource: AccountUsageCredentialSource
    ) async -> AccountUsageRow {
        let storedRow = Self.storedRow(for: account)
        let storedSnapshot = storedRow.snapshot

        guard account.authMode == nil || account.authMode == "chatgpt" else {
            return AccountUsageRow(
                account: account,
                snapshot: storedSnapshot,
                errorMessage: "API key accounts do not report ChatGPT quota through Managed Accounts.",
                isRefreshing: false
            )
        }

        do {
            let snapshot: UsageSnapshot
            switch credentialSource {
            case .managedSnapshot:
                if try accountStore.managedAccountKeyForActiveAuth() == account.accountKey {
                    var currentAccount = account
                    currentAccount.isActive = true
                    Self.backgroundLogger.info("managed account row refresh skipped because account became current key_fp=\(LogFingerprint.account(account.accountKey), privacy: .public) key=\(account.accountKey, privacy: .private)")
                    return Self.storedRow(for: currentAccount)
                }
                snapshot = try await usageClient.loadSnapshot(
                    managedAccount: account,
                    accountStore: accountStore
                )
            case .activeAuthReadOnly:
                snapshot = try await usageClient.loadSnapshotReadOnly(
                    authFileURL: accountStore.activeAuthFileURL,
                    managedAccount: account
                )
            }
            var updatedAccount = try accountStore.updateUsage(accountKey: account.accountKey, snapshot: snapshot)
            updatedAccount.isActive = account.isActive
            return AccountUsageRow(
                account: updatedAccount,
                snapshot: snapshot,
                errorMessage: nil,
                isRefreshing: false
            )
        } catch {
            let errorMessage = Self.accountUsageErrorMessage(error, credentialSource: credentialSource)
            Self.backgroundLogger.error("managed account row refresh failed key_fp=\(LogFingerprint.account(account.accountKey), privacy: .public) account_id_fp=\(LogFingerprint.account(account.chatgptAccountID), privacy: .public) is_active=\(account.isActive, privacy: .public) read_only=\((credentialSource == .activeAuthReadOnly), privacy: .public) error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            return AccountUsageRow(
                account: account,
                snapshot: storedSnapshot,
                errorMessage: errorMessage,
                isRefreshing: false
            )
        }
    }

    nonisolated private static func addManagedAccount(
        codexExecutablePath: String
    ) async throws -> CodexUsageLoadResult {
        let authData: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let client = CodexAppServerClient(executablePath: codexExecutablePath)
                    continuation.resume(returning: try client.loginChatGPTAuthData())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        _ = try CodexUsageAccountStore().addAccount(authData: authData)
        return try await Self.loadCurrentManagedAccountUsage()
    }

    nonisolated private static func removeManagedAccount(
        accountKey: String
    ) async throws -> CodexUsageLoadResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let snapshot = try CodexUsageAccountStore().removeAccount(accountKey: accountKey)
                    continuation.resume(returning: Self.storedRows(from: snapshot))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func storedRows(
        from snapshot: CodexManagedAccountsSnapshot
    ) -> CodexUsageLoadResult {
        let rows = snapshot.accounts.map(Self.storedRow(for:))
        return CodexUsageLoadResult(rows: rows, activeAccountKey: snapshot.activeAccountKey)
    }

    nonisolated private static func storedRow(for account: CodexManagedAccount) -> AccountUsageRow {
        AccountUsageRow(
            account: account,
            snapshot: account.storedUsage ?? UsageSnapshot(
                account: account.codexAccount,
                sessionWindow: nil,
                weeklyWindow: nil,
                updatedAt: account.lastUsageAt,
                sourceDescription: "Stored account"
            ),
            errorMessage: nil,
            isRefreshing: false
        )
    }

    nonisolated private static func markRows(
        _ rows: [AccountUsageRow],
        activeAccountKey: String?
    ) -> [AccountUsageRow] {
        rows.map { row in
            var next = row
            next.account.isActive = next.id == activeAccountKey
            return next
        }
    }

    nonisolated private static func accountUsageErrorMessage(
        _ error: Error,
        credentialSource: AccountUsageCredentialSource
    ) -> String {
        if credentialSource == .activeAuthReadOnly,
           case CodexOAuthUsageError.unauthorized = error
        {
            return "Current Codex auth token was rejected. Use Codex to refresh the current login, then refresh quota again."
        }
        return error.localizedDescription
    }

    nonisolated private static func loadCLISnapshot(codexExecutablePath: String) async throws -> UsageSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let client = CodexAppServerClient(executablePath: codexExecutablePath)
                    continuation.resume(returning: try client.loadSnapshot())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func activateManagedAccount(accountKey: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try CodexUsageAccountStore().activateAccount(accountKey: accountKey)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func reconcileActiveAccount() {
        let nextActive = activeAccountKey
            .flatMap { key in accountRows.first(where: { $0.id == key })?.id }
            ?? accountRows.first(where: { $0.isActive })?.id

        activeAccountKey = nextActive ?? (usageDataSource == .cliRPC ? accountRows.first?.id : nil)
    }

    private func replaceAccountRow(_ row: AccountUsageRow, activeAccountKey: String?) {
        if let index = accountRows.firstIndex(where: { $0.id == row.id }) {
            accountRows[index] = row
        } else {
            accountRows.append(row)
        }

        self.activeAccountKey = activeAccountKey
        accountRows = accountRows.map { existing in
            var next = existing
            next.account.isActive = next.id == activeAccountKey
            return next
        }
        reconcileActiveAccount()
    }

    private func setAccountRefreshing(accountKey: String, isRefreshing: Bool) {
        accountRows = accountRows.map { row in
            guard row.id == accountKey else { return row }
            var next = row
            next.isRefreshing = isRefreshing
            return next
        }
    }

    private func performStartupMaintenance() {
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try CodexUsageAccountStore().performStartupMaintenance()
                }.value
                logger.info("managed account startup maintenance completed")
            } catch {
                if errorMessage == nil {
                    errorMessage = error.localizedDescription
                }
                logger.error("managed account startup maintenance failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        guard !isConfigurationTransferSuspended else {
            autoRefreshTask = nil
            logger.info("auto refresh timer paused for configuration transfer")
            return
        }
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.refreshInterval.randomizedNanoseconds else { return }
                self?.logger.info("next timer refresh delay_ns=\(interval, privacy: .public)")
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                self?.refreshCurrentAccount(trigger: .timer)
            }
        }
    }
}

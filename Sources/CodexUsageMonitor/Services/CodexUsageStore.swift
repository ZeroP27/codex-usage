import Foundation
import OSLog

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
    @Published var usageDataSource: CodexUsageDataSource {
        didSet {
            UserDefaults.standard.set(usageDataSource.rawValue, forKey: Self.usageDataSourceDefaultsKey)
            logger.info("data source changed source=\(self.usageDataSource.rawValue, privacy: .public)")
            refresh(trigger: .settingsChange)
        }
    }
    @Published var refreshInterval: CodexRefreshInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: Self.refreshIntervalDefaultsKey)
            logger.info("refresh interval changed seconds=\(self.refreshInterval.rawValue, privacy: .public)")
            startAutoRefresh()
        }
    }
    @Published var codexExecutablePath: String {
        didSet {
            UserDefaults.standard.set(codexExecutablePath, forKey: Self.codexExecutableDefaultsKey)
            logger.info("codex executable path changed")
        }
    }

    private struct FetchConfiguration: Equatable {
        var usageDataSource: CodexUsageDataSource
        var codexExecutablePath: String
    }

    private struct UsageLoadResult: Sendable {
        var rows: [AccountUsageRow]
        var activeAccountKey: String?
        var errorMessage: String? = nil
    }

    private struct SingleAccountUsageLoadResult: Sendable {
        var row: AccountUsageRow
        var activeAccountKey: String?
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

    private enum AccountUsageCredentialSource {
        case managedSnapshot
        case activeAuthReadOnly
    }

    private static let usageDataSourceDefaultsKey = "usageDataSource"
    private static let refreshIntervalDefaultsKey = "refreshInterval"
    private static let codexExecutableDefaultsKey = "codexExecutablePath"
    private let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "UsageStore"
    )
    nonisolated private static let backgroundLogger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "UsageStore"
    )
    private var autoRefreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var lastRefreshCompletedAt: Date?

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

    init() {
        let storedSource = UserDefaults.standard.string(forKey: Self.usageDataSourceDefaultsKey)
        usageDataSource = storedSource.flatMap(CodexUsageDataSource.init(rawValue:)) ?? .oauthAPI

        let storedInterval = UserDefaults.standard.integer(forKey: Self.refreshIntervalDefaultsKey)
        refreshInterval = CodexRefreshInterval(rawValue: storedInterval) ?? .fiveMinutes

        codexExecutablePath = UserDefaults.standard.string(forKey: Self.codexExecutableDefaultsKey)
            ?? "codex"

        refreshCurrentAccount(trigger: .appStart)
        startAutoRefresh()
    }

    deinit {
        autoRefreshTask?.cancel()
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
        guard !blockRefreshIfAccountManagementIsBusy(trigger: trigger) else { return }
        guard !isRefreshing else {
            refreshRequested = true
            logger.info("stored current account refresh queued trigger=\(trigger.rawValue, privacy: .public)")
            return
        }

        isRefreshing = true
        refreshRequested = false
        let configuration = currentFetchConfiguration

        Task {
            do {
                let result = try await Self.loadCurrentManagedAccountUsage()
                if configuration == currentFetchConfiguration {
                    accountRows = result.rows
                    activeAccountKey = result.activeAccountKey
                    reconcileActiveAccount()
                    errorMessage = result.errorMessage
                    lastRefreshCompletedAt = Date()
                    logger.info("stored current account refresh completed rows=\(result.rows.count, privacy: .public)")
                } else {
                    refreshRequested = true
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("stored current account refresh failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    refreshRequested = true
                }
            }

            isRefreshing = false
            if refreshRequested {
                refreshCurrentAccount(trigger: trigger)
            }
        }
    }

    private func refresh(trigger: RefreshTrigger) {
        logger.info("refresh requested trigger=\(trigger.rawValue, privacy: .public) source=\(self.usageDataSource.rawValue, privacy: .public)")
        guard !blockRefreshIfAccountManagementIsBusy(trigger: trigger) else { return }
        guard !isRefreshing else {
            refreshRequested = true
            logger.info("refresh queued trigger=\(trigger.rawValue, privacy: .public)")
            return
        }

        isRefreshing = true
        isRefreshingAll = true
        refreshRequested = false
        let configuration = currentFetchConfiguration

        Task {
            do {
                let result = try await Self.loadUsage(configuration: configuration)
                if configuration == currentFetchConfiguration {
                    accountRows = result.rows
                    activeAccountKey = result.activeAccountKey
                    reconcileActiveAccount()
                    errorMessage = result.errorMessage
                    lastRefreshCompletedAt = Date()
                    logger.info("refresh completed rows=\(result.rows.count, privacy: .public)")
                } else {
                    refreshRequested = true
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("refresh failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    refreshRequested = true
                }
            }

            isRefreshingAll = false
            isRefreshing = false
            if refreshRequested {
                refresh(trigger: trigger)
            }
        }
    }

    private func refreshAccount(accountKey: String, trigger: RefreshTrigger) {
        logger.info("account refresh requested trigger=\(trigger.rawValue, privacy: .public) key=\(accountKey, privacy: .private)")
        guard !blockRefreshIfAccountManagementIsBusy(trigger: trigger) else { return }
        guard !isRefreshing else {
            logger.info("account refresh ignored because another refresh is active key=\(accountKey, privacy: .private)")
            return
        }

        isRefreshing = true
        refreshRequested = false
        setAccountRefreshing(accountKey: accountKey, isRefreshing: true)
        let configuration = currentFetchConfiguration

        Task {
            do {
                let result = try await Self.loadSingleUsage(
                    accountKey: accountKey,
                    configuration: configuration
                )
                if configuration == currentFetchConfiguration {
                    replaceAccountRow(result.row, activeAccountKey: result.activeAccountKey)
                    errorMessage = result.row.errorMessage
                    lastRefreshCompletedAt = Date()
                    logger.info("account refresh completed key=\(accountKey, privacy: .private)")
                } else {
                    refreshRequested = true
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("account refresh failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    refreshRequested = true
                }
            }

            setAccountRefreshing(accountKey: accountKey, isRefreshing: false)
            isRefreshing = false
            if refreshRequested {
                refresh(trigger: trigger)
            }
        }
    }

    func refreshIfStale() {
        guard !isRefreshing else { return }
        guard let lastRefreshCompletedAt else {
            refreshCurrentAccount(trigger: .staleMenuOpen)
            return
        }
        if Date().timeIntervalSince(lastRefreshCompletedAt) >= TimeInterval(refreshInterval.rawValue) {
            refreshCurrentAccount(trigger: .staleMenuOpen)
        }
    }

    func updateCodexExecutablePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        codexExecutablePath = trimmed.isEmpty ? "codex" : trimmed.expandingTildeInPath
        refresh(trigger: .pathChange)
    }

    func resetCodexExecutablePath() {
        codexExecutablePath = "codex"
        refresh(trigger: .pathChange)
    }

    func activateAccount(_ accountKey: String) {
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
        refreshRequested = false
        let configuration = currentFetchConfiguration
        logger.info("account activation requested key=\(accountKey, privacy: .private)")

        Task {
            do {
                try await Self.activateManagedAccount(accountKey: accountKey)
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
                    refreshRequested = true
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("account activation failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    refreshRequested = true
                }
            }

            isActivatingAccount = false
            if refreshRequested {
                refresh(trigger: .settingsChange)
            } else {
                refreshCurrentAccount(trigger: .accountSwitch)
            }
        }
    }

    func addAccount() {
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
        refreshRequested = false
        errorMessage = nil
        let executablePath = codexExecutablePath
        let configuration = currentFetchConfiguration
        logger.info("account login requested")

        Task {
            do {
                let result = try await Self.addManagedAccount(codexExecutablePath: executablePath)
                if configuration == currentFetchConfiguration {
                    accountRows = result.rows
                    activeAccountKey = result.activeAccountKey
                    reconcileActiveAccount()
                    errorMessage = nil
                    lastRefreshCompletedAt = Date()
                    logger.info("account login completed rows=\(result.rows.count, privacy: .public)")
                } else {
                    refreshRequested = true
                }
            } catch {
                if executablePath == codexExecutablePath {
                    errorMessage = error.localizedDescription
                    logger.error("account login failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    refreshRequested = true
                }
            }

            isAddingAccount = false
            if refreshRequested {
                refresh(trigger: .settingsChange)
            }
        }
    }

    func removeAccount(_ accountKey: String) {
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
        refreshRequested = false
        let configuration = currentFetchConfiguration
        logger.info("account removal requested key=\(accountKey, privacy: .private)")

        Task {
            do {
                let result = try await Self.removeManagedAccount(accountKey: accountKey)
                if configuration == currentFetchConfiguration {
                    accountRows = result.rows
                    activeAccountKey = result.activeAccountKey
                    reconcileActiveAccount()
                    errorMessage = nil
                    logger.info("account removal completed key=\(accountKey, privacy: .private)")
                } else {
                    refreshRequested = true
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("account removal failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                } else {
                    refreshRequested = true
                }
            }

            isRemovingAccount = false
            if refreshRequested {
                refresh(trigger: .settingsChange)
            }
        }
    }

    private func isCurrentManagedAccount(_ accountKey: String) -> Bool {
        activeAccountKey == accountKey
            || accountRows.first(where: { $0.id == accountKey })?.isActive == true
    }

    private var currentFetchConfiguration: FetchConfiguration {
        FetchConfiguration(
            usageDataSource: usageDataSource,
            codexExecutablePath: codexExecutablePath
        )
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

    nonisolated private static func loadUsage(configuration: FetchConfiguration) async throws -> UsageLoadResult {
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
            return UsageLoadResult(
                rows: [AccountUsageRow(
                    account: account,
                    snapshot: snapshot,
                    errorMessage: nil,
                    isRefreshing: false
                )],
                activeAccountKey: account.accountKey
            )
        }
    }

    nonisolated private static func loadSingleUsage(
        accountKey: String,
        configuration: FetchConfiguration
    ) async throws -> SingleAccountUsageLoadResult {
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
            return SingleAccountUsageLoadResult(
                row: AccountUsageRow(
                    account: account,
                    snapshot: snapshot,
                    errorMessage: nil,
                    isRefreshing: false
                ),
                activeAccountKey: account.accountKey
            )
        }
    }

    nonisolated private static func loadManagedAccountsUsage() async throws -> UsageLoadResult {
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
        return UsageLoadResult(rows: rows, activeAccountKey: activeAccountKey)
    }

    nonisolated private static func loadManagedAccountsUsage(
        accountKey: String
    ) async throws -> SingleAccountUsageLoadResult {
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
        return SingleAccountUsageLoadResult(row: row, activeAccountKey: activeAccountKey)
    }

    nonisolated private static func loadCurrentManagedAccountUsage() async throws -> UsageLoadResult {
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
        if let index = result.rows.firstIndex(where: { $0.id == refreshedRow.id }) {
            result.rows[index] = refreshedRow
        } else {
            result.rows.append(refreshedRow)
        }
        result.activeAccountKey = activeAccountKey
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
                let authFileURL = try accountStore.authFileURL(for: account.accountKey)
                snapshot = try await usageClient.loadSnapshot(
                    authFileURL: authFileURL,
                    managedAccount: account
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

    nonisolated private static func addManagedAccount(codexExecutablePath: String) async throws -> UsageLoadResult {
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

    nonisolated private static func removeManagedAccount(accountKey: String) async throws -> UsageLoadResult {
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

    nonisolated private static func storedRows(from snapshot: CodexManagedAccountsSnapshot) -> UsageLoadResult {
        let rows = snapshot.accounts.map(Self.storedRow(for:))
        return UsageLoadResult(rows: rows, activeAccountKey: snapshot.activeAccountKey)
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

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
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

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

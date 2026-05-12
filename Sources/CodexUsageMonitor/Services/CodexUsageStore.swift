import Foundation
import OSLog

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var accountRows: [AccountUsageRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var isActivatingAccount = false
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

    private static let usageDataSourceDefaultsKey = "usageDataSource"
    private static let refreshIntervalDefaultsKey = "refreshInterval"
    private static let codexExecutableDefaultsKey = "codexExecutablePath"
    private let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "UsageStore"
    )
    private(set) var hasLoaded = false
    private var autoRefreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var lastRefreshCompletedAt: Date?

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

        refresh(trigger: .appStart)
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
        guard let accountKey = currentAccountKey else {
            errorMessage = "No current Codex account is available to refresh."
            logger.error("current account refresh failed reason=no_current_account trigger=\(trigger.rawValue, privacy: .public)")
            return
        }
        refreshAccount(accountKey: accountKey, trigger: trigger)
    }

    private func refresh(trigger: RefreshTrigger) {
        logger.info("refresh requested trigger=\(trigger.rawValue, privacy: .public) source=\(self.usageDataSource.rawValue, privacy: .public)")
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
                    errorMessage = nil
                    lastRefreshCompletedAt = Date()
                    logger.info("refresh completed rows=\(result.rows.count, privacy: .public)")
                } else {
                    refreshRequested = true
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                    logger.error("refresh failed error=\(error.localizedDescription, privacy: .public)")
                } else {
                    refreshRequested = true
                }
            }

            isRefreshingAll = false
            isRefreshing = false
            hasLoaded = true

            if refreshRequested {
                refresh(trigger: trigger)
            }
        }
    }

    private func refreshAccount(accountKey: String, trigger: RefreshTrigger) {
        logger.info("account refresh requested trigger=\(trigger.rawValue, privacy: .public) key=\(accountKey, privacy: .private)")
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
                    logger.error("account refresh failed error=\(error.localizedDescription, privacy: .public)")
                } else {
                    refreshRequested = true
                }
            }

            setAccountRefreshing(accountKey: accountKey, isRefreshing: false)
            isRefreshing = false
            hasLoaded = true

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
            errorMessage = "Account switching is available only for the OAuth API account registry source."
            return
        }
        guard !isActivatingAccount else { return }

        isActivatingAccount = true
        logger.info("account activation requested key=\(accountKey, privacy: .private)")

        Task {
            do {
                try await Self.activateStoredAccount(accountKey: accountKey)
                activeAccountKey = accountKey
                accountRows = accountRows.map { row in
                    var next = row
                    next.account.isActive = row.id == accountKey
                    return next
                }
                errorMessage = nil
                logger.info("account activation completed key=\(accountKey, privacy: .private)")
                isActivatingAccount = false
                refreshCurrentAccount(trigger: .accountSwitch)
            } catch {
                errorMessage = error.localizedDescription
                logger.error("account activation failed error=\(error.localizedDescription, privacy: .public)")
                isActivatingAccount = false
            }
        }
    }

    private var currentFetchConfiguration: FetchConfiguration {
        FetchConfiguration(
            usageDataSource: usageDataSource,
            codexExecutablePath: codexExecutablePath
        )
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
            return try await Self.loadAccountRegistryUsage()
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
            return try await Self.loadAccountRegistryUsage(accountKey: accountKey)
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

    nonisolated private static func loadAccountRegistryUsage() async throws -> UsageLoadResult {
        let registryStore = CodexAccountsRegistryStore()
        let registry = try registryStore.loadSnapshot()
        guard !registry.accounts.isEmpty else {
            throw CodexAccountsRegistryError.accountNotFound
        }

        var rows: [AccountUsageRow] = []
        rows.reserveCapacity(registry.accounts.count)
        let usageClient = CodexOAuthUsageClient()

        for account in registry.accounts {
            rows.append(
                await Self.loadAccountRegistryRow(
                    account: account,
                    registryStore: registryStore,
                    usageClient: usageClient
                )
            )
        }

        return UsageLoadResult(rows: rows, activeAccountKey: registry.activeAccountKey)
    }

    nonisolated private static func loadAccountRegistryUsage(
        accountKey: String
    ) async throws -> SingleAccountUsageLoadResult {
        let registryStore = CodexAccountsRegistryStore()
        let registry = try registryStore.loadSnapshot()
        guard let account = registry.accounts.first(where: { $0.accountKey == accountKey }) else {
            throw CodexAccountsRegistryError.accountNotFound
        }

        let usageClient = CodexOAuthUsageClient()
        let row = await Self.loadAccountRegistryRow(
            account: account,
            registryStore: registryStore,
            usageClient: usageClient
        )
        return SingleAccountUsageLoadResult(row: row, activeAccountKey: registry.activeAccountKey)
    }

    nonisolated private static func loadAccountRegistryRow(
        account: CodexManagedAccount,
        registryStore: CodexAccountsRegistryStore,
        usageClient: CodexOAuthUsageClient
    ) async -> AccountUsageRow {
        let storedSnapshot = account.storedUsage ?? UsageSnapshot(
            account: account.codexAccount,
            sessionWindow: nil,
            weeklyWindow: nil,
            updatedAt: account.lastUsageAt,
            sourceDescription: "Stored registry"
        )

        guard account.authMode == nil || account.authMode == "chatgpt" else {
            return AccountUsageRow(
                account: account,
                snapshot: storedSnapshot,
                errorMessage: "API key accounts do not report ChatGPT quota through OAuth API.",
                isRefreshing: false
            )
        }

        do {
            let authFileURL = try registryStore.authFileURL(for: account.accountKey)
            let snapshot = try await usageClient.loadSnapshot(
                authFileURL: authFileURL,
                registryAccount: account,
                activeAuthFileURL: registryStore.activeAuthFileURL
            )
            return AccountUsageRow(
                account: account,
                snapshot: snapshot,
                errorMessage: nil,
                isRefreshing: false
            )
        } catch {
            return AccountUsageRow(
                account: account,
                snapshot: storedSnapshot,
                errorMessage: error.localizedDescription,
                isRefreshing: false
            )
        }
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

    nonisolated private static func activateStoredAccount(accountKey: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try CodexAccountsRegistryStore().activateAccount(accountKey: accountKey)
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

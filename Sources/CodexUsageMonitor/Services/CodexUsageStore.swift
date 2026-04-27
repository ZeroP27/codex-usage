import Foundation

@MainActor
final class CodexUsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published var usageDataSource: CodexUsageDataSource {
        didSet {
            UserDefaults.standard.set(usageDataSource.rawValue, forKey: Self.usageDataSourceDefaultsKey)
            refresh()
        }
    }
    @Published var refreshInterval: CodexRefreshInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: Self.refreshIntervalDefaultsKey)
            startAutoRefresh()
        }
    }
    @Published var codexExecutablePath: String {
        didSet {
            UserDefaults.standard.set(codexExecutablePath, forKey: Self.codexExecutableDefaultsKey)
        }
    }

    private struct FetchConfiguration: Equatable {
        var usageDataSource: CodexUsageDataSource
        var codexExecutablePath: String
    }

    private static let usageDataSourceDefaultsKey = "usageDataSource"
    private static let refreshIntervalDefaultsKey = "refreshInterval"
    private static let codexExecutableDefaultsKey = "codexExecutablePath"
    private(set) var hasLoaded = false
    private var autoRefreshTask: Task<Void, Never>?
    private var refreshRequested = false

    init() {
        let storedSource = UserDefaults.standard.string(forKey: Self.usageDataSourceDefaultsKey)
        usageDataSource = storedSource.flatMap(CodexUsageDataSource.init(rawValue:)) ?? .oauthAPI

        let storedInterval = UserDefaults.standard.integer(forKey: Self.refreshIntervalDefaultsKey)
        refreshInterval = CodexRefreshInterval(rawValue: storedInterval) ?? .fiveMinutes

        codexExecutablePath = UserDefaults.standard.string(forKey: Self.codexExecutableDefaultsKey)
            ?? "codex"
        refresh()
        startAutoRefresh()
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    func refresh() {
        guard !isRefreshing else {
            refreshRequested = true
            return
        }

        isRefreshing = true
        refreshRequested = false
        let configuration = currentFetchConfiguration

        Task {
            do {
                let nextSnapshot = try await Self.loadSnapshot(configuration: configuration)
                if configuration == currentFetchConfiguration {
                    snapshot = nextSnapshot
                    errorMessage = nil
                } else {
                    refreshRequested = true
                }
            } catch {
                if configuration == currentFetchConfiguration {
                    errorMessage = error.localizedDescription
                } else {
                    refreshRequested = true
                }
            }

            isRefreshing = false
            hasLoaded = true

            if refreshRequested {
                refresh()
            }
        }
    }

    func refreshIfStale() {
        guard !isRefreshing else { return }
        guard let updatedAt = snapshot.updatedAt else {
            refresh()
            return
        }
        if Date().timeIntervalSince(updatedAt) >= TimeInterval(refreshInterval.rawValue) {
            refresh()
        }
    }

    func updateCodexExecutablePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        codexExecutablePath = trimmed.isEmpty ? "codex" : trimmed.expandingTildeInPath
        refresh()
    }

    func resetCodexExecutablePath() {
        codexExecutablePath = "codex"
        refresh()
    }

    private var currentFetchConfiguration: FetchConfiguration {
        FetchConfiguration(
            usageDataSource: usageDataSource,
            codexExecutablePath: codexExecutablePath
        )
    }

    nonisolated private static func loadSnapshot(configuration: FetchConfiguration) async throws -> UsageSnapshot {
        switch configuration.usageDataSource {
        case .oauthAPI:
            return try await CodexOAuthUsageClient().loadSnapshot()
        case .cliRPC:
            return try await Self.loadCLISnapshot(codexExecutablePath: configuration.codexExecutablePath)
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

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.refreshInterval.nanoseconds else { return }
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

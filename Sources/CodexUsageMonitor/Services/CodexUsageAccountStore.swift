import Foundation
import OSLog

struct CodexUsageAccountStore {
    var applicationSupportURL: URL = Self.defaultApplicationSupportURL()
    var codexHomeURL: URL = Self.defaultCodexHomeURL()

    private static let schemaVersion = 1
    private static let maxSupportedSchemaVersion = 1
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "ManagedAccounts"
    )

    var accountsDirectoryURL: URL {
        applicationSupportURL.appendingPathComponent("accounts", isDirectory: true)
    }

    var registryFileURL: URL {
        accountsDirectoryURL.appendingPathComponent("registry.json")
    }

    var activeAuthFileURL: URL {
        codexHomeURL.appendingPathComponent("auth.json")
    }

    func loadSnapshot() throws -> CodexManagedAccountsSnapshot {
        let registry = try loadRegistryFile()
        let activeAccountKey = registry.activeAccountKey
        let accounts = registry.accounts.map {
            $0.managedAccount(activeAccountKey: activeAccountKey)
        }
        Self.logger.info("loaded managed accounts count=\(accounts.count, privacy: .public) active_present=\((activeAccountKey?.isEmpty == false), privacy: .public) active_fp=\(LogFingerprint.account(activeAccountKey), privacy: .public)")

        return CodexManagedAccountsSnapshot(
            schemaVersion: registry.schemaVersion,
            activeAccountKey: activeAccountKey,
            accounts: accounts,
            loadedAt: Date()
        )
    }

    func authFileURL(for accountKey: String) throws -> URL {
        accountsDirectoryURL.appendingPathComponent(try Self.accountSnapshotFilename(accountKey: accountKey))
    }

    func addAccount(authData sourceData: Data) throws -> CodexManagedAccount {
        let credentials = try CodexOAuthCredentialsStore.load(from: sourceData)
        let accountInfo = try credentials.accountInfo()
        let destinationURL = try self.authFileURL(for: accountInfo.accountKey)
        Self.logger.info("importing managed account key_fp=\(LogFingerprint.account(accountInfo.accountKey), privacy: .public) account_id_fp=\(LogFingerprint.account(accountInfo.chatgptAccountID), privacy: .public) key=\(accountInfo.accountKey, privacy: .private) email=\(accountInfo.email, privacy: .private) plan=\(accountInfo.planType ?? "missing", privacy: .public) account_id_source=\(accountInfo.accountIDSource, privacy: .public)")

        try ensureAccountsDirectory()
        let previousSnapshotData = try authSnapshotDataIfExists(at: destinationURL)
        try sourceData.write(to: destinationURL, options: .atomic)
        try Self.setOwnerOnlyPermissions(destinationURL)
        Self.logger.info("stored managed auth snapshot key_fp=\(LogFingerprint.account(accountInfo.accountKey), privacy: .public) key=\(accountInfo.accountKey, privacy: .private) path=\(destinationURL.path, privacy: .private)")

        do {
            var registry = try loadRegistryFile()
            let now = Int64(Date().timeIntervalSince1970)
            let existing = registry.accounts.first { $0.accountKey == accountInfo.accountKey }
            let nextRecord = ManagedAccountRecord(
                accountKey: accountInfo.accountKey,
                chatgptAccountID: accountInfo.chatgptAccountID,
                chatgptUserID: accountInfo.chatgptUserID,
                email: accountInfo.email,
                alias: existing?.alias ?? "",
                accountName: existing?.accountName,
                plan: accountInfo.planType,
                authMode: "chatgpt",
                createdAt: existing?.createdAt ?? now,
                lastUsedAt: now,
                lastUsage: existing?.lastUsage,
                lastUsageAt: existing?.lastUsageAt
            )

            upsert(nextRecord, in: &registry)
            let previousActiveKey = registry.activeAccountKey
            registry.activeAccountKey = accountInfo.accountKey
            Self.logger.info("managed account registry prepared key_fp=\(LogFingerprint.account(accountInfo.accountKey), privacy: .public) previous_active_fp=\(LogFingerprint.account(previousActiveKey), privacy: .public) key=\(accountInfo.accountKey, privacy: .private) replacing_existing=\((existing != nil), privacy: .public) previous_active=\(previousActiveKey ?? "missing", privacy: .private) next_count=\(registry.accounts.count, privacy: .public)")
            try replaceActiveAuthThenSaveRegistry(
                sourceAuthURL: destinationURL,
                registry: registry,
                keyForLog: accountInfo.accountKey
            )

            Self.logger.info("added managed account key_fp=\(LogFingerprint.account(accountInfo.accountKey), privacy: .public) key=\(accountInfo.accountKey, privacy: .private) active_auth_synced=true registry_saved=true")
            return nextRecord.managedAccount(activeAccountKey: registry.activeAccountKey)
        } catch {
            try restoreAuthSnapshotAfterFailure(
                at: destinationURL,
                previousData: previousSnapshotData,
                keyForLog: accountInfo.accountKey
            )
            throw error
        }
    }

    func removeAccount(accountKey: String) throws -> CodexManagedAccountsSnapshot {
        var registry = try loadRegistryFile()
        guard registry.accounts.contains(where: { $0.accountKey == accountKey }) else {
            throw CodexUsageAccountStoreError.accountNotFound
        }
        guard registry.activeAccountKey != accountKey else {
            throw CodexUsageAccountStoreError.activeAccountCannotBeRemoved
        }

        let authURL = try authFileURL(for: accountKey)
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            Self.logger.error("managed account removal failed missing auth snapshot key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private) path=\(authURL.path, privacy: .private)")
            throw CodexUsageAccountStoreError.authSnapshotNotFound(authURL.path)
        }

        Self.logger.info("removing managed account key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private) previous_count=\(registry.accounts.count, privacy: .public)")
        let previousSnapshotData = try Data(contentsOf: authURL)
        registry.accounts.removeAll { $0.accountKey == accountKey }

        try FileManager.default.removeItem(at: authURL)
        do {
            try saveRegistryFile(registry)
        } catch {
            try restoreAuthSnapshotAfterFailure(
                at: authURL,
                previousData: previousSnapshotData,
                keyForLog: accountKey
            )
            throw error
        }
        Self.logger.info("removed managed account key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private) next_count=\(registry.accounts.count, privacy: .public)")
        return try loadSnapshot()
    }

    func activateAccount(accountKey: String) throws {
        var registry = try loadRegistryFile()
        guard registry.accounts.contains(where: { $0.accountKey == accountKey }) else {
            throw CodexUsageAccountStoreError.accountNotFound
        }

        let sourceAuthURL = try authFileURL(for: accountKey)
        guard FileManager.default.fileExists(atPath: sourceAuthURL.path) else {
            throw CodexUsageAccountStoreError.authSnapshotNotFound(sourceAuthURL.path)
        }

        let previousActiveKey = registry.activeAccountKey
        Self.logger.info("activating managed account key_fp=\(LogFingerprint.account(accountKey), privacy: .public) previous_active_fp=\(LogFingerprint.account(previousActiveKey), privacy: .public) key=\(accountKey, privacy: .private) previous_active=\(previousActiveKey ?? "missing", privacy: .private)")
        patchActiveAccount(accountKey: accountKey, in: &registry)
        try replaceActiveAuthThenSaveRegistry(
            sourceAuthURL: sourceAuthURL,
            registry: registry,
            keyForLog: accountKey
        )

        Self.logger.info("activated managed account key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private)")
    }

    func syncActiveAuthIfAccountIsActive(accountKey: String, authFileURL: URL) throws {
        let registry = try loadRegistryFile()
        guard registry.activeAccountKey == accountKey else {
            Self.logger.info("skipped active auth sync for non-active account key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private)")
            return
        }
        try replaceActiveAuth(with: authFileURL)
        Self.logger.info("synced refreshed active auth key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private)")
    }

    func updateUsage(accountKey: String, snapshot: UsageSnapshot) throws -> CodexManagedAccount {
        var registry = try loadRegistryFile()
        guard let index = registry.accounts.firstIndex(where: { $0.accountKey == accountKey }) else {
            throw CodexUsageAccountStoreError.accountNotFound
        }

        let now = Int64(Date().timeIntervalSince1970)
        registry.accounts[index].lastUsage = ManagedRateLimitSnapshot(snapshot: snapshot)
        registry.accounts[index].lastUsageAt = now
        registry.accounts[index].plan = snapshot.account?.planType ?? registry.accounts[index].plan
        registry.accounts[index].email = snapshot.account?.email ?? registry.accounts[index].email

        try saveRegistryFile(registry)
        Self.logger.info("updated managed account usage key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private) session_present=\((snapshot.sessionWindow != nil), privacy: .public) weekly_present=\((snapshot.weeklyWindow != nil), privacy: .public)")
        return registry.accounts[index].managedAccount(activeAccountKey: registry.activeAccountKey)
    }

    private func loadRegistryFile() throws -> ManagedAccountsRegistryFile {
        guard FileManager.default.fileExists(atPath: registryFileURL.path) else {
            return ManagedAccountsRegistryFile(
                schemaVersion: Self.schemaVersion,
                activeAccountKey: nil,
                accounts: []
            )
        }

        let data = try Data(contentsOf: registryFileURL)
        let decoder = JSONDecoder()
        let decoded: ManagedAccountsRegistryFile
        do {
            decoded = try decoder.decode(ManagedAccountsRegistryFile.self, from: data)
        } catch {
            throw CodexUsageAccountStoreError.decodeFailed(error.localizedDescription)
        }

        guard decoded.schemaVersion > 0 && decoded.schemaVersion <= Self.maxSupportedSchemaVersion else {
            throw CodexUsageAccountStoreError.unsupportedSchema(decoded.schemaVersion)
        }
        return decoded
    }

    private func saveRegistryFile(_ registry: ManagedAccountsRegistryFile) throws {
        try ensureAccountsDirectory()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try data.write(to: registryFileURL, options: .atomic)
        try Self.setOwnerOnlyPermissions(registryFileURL)
    }

    private func upsert(_ record: ManagedAccountRecord, in registry: inout ManagedAccountsRegistryFile) {
        if let index = registry.accounts.firstIndex(where: { $0.accountKey == record.accountKey }) {
            registry.accounts[index] = record
        } else {
            registry.accounts.append(record)
        }
        registry.accounts.sort { lhs, rhs in
            lhs.email.localizedCaseInsensitiveCompare(rhs.email) == .orderedAscending
        }
    }

    private func patchActiveAccount(accountKey: String, in registry: inout ManagedAccountsRegistryFile) {
        registry.activeAccountKey = accountKey
        let now = Int64(Date().timeIntervalSince1970)
        for index in registry.accounts.indices where registry.accounts[index].accountKey == accountKey {
            registry.accounts[index].lastUsedAt = now
        }
    }

    private func replaceActiveAuthThenSaveRegistry(
        sourceAuthURL: URL,
        registry: ManagedAccountsRegistryFile,
        keyForLog accountKey: String
    ) throws {
        let previousActiveAuthData = try authSnapshotDataIfExists(at: activeAuthFileURL)
        try backupActiveAuthIfChanged(sourceAuthURL: sourceAuthURL)
        try replaceActiveAuth(with: sourceAuthURL)

        do {
            try saveRegistryFile(registry)
        } catch {
            do {
                try restoreActiveAuth(previousActiveAuthData)
            } catch {
                Self.logger.fault("active auth restore failed key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private) restore_error_type=\(LogErrorSummary.category(error), privacy: .public) restore_error=\(error.localizedDescription, privacy: .private)")
                throw CodexUsageAccountStoreError.activeAuthRestoreFailed(error.localizedDescription)
            }
            throw error
        }
    }

    private func authSnapshotDataIfExists(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func restoreAuthSnapshotAfterFailure(
        at url: URL,
        previousData: Data?,
        keyForLog accountKey: String
    ) throws {
        do {
            try restoreAuthSnapshot(at: url, previousData: previousData)
        } catch {
            Self.logger.fault("managed auth snapshot restore failed key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private) restore_error_type=\(LogErrorSummary.category(error), privacy: .public) restore_error=\(error.localizedDescription, privacy: .private)")
            throw CodexUsageAccountStoreError.authSnapshotRestoreFailed(error.localizedDescription)
        }
    }

    private func restoreAuthSnapshot(at url: URL, previousData: Data?) throws {
        if let previousData {
            try previousData.write(to: url, options: .atomic)
            try Self.setOwnerOnlyPermissions(url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func restoreActiveAuth(_ previousData: Data?) throws {
        try FileManager.default.createDirectory(
            at: activeAuthFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try restoreAuthSnapshot(at: activeAuthFileURL, previousData: previousData)
        Self.logger.info("restored active auth after registry save failure")
    }

    private func backupActiveAuthIfChanged(sourceAuthURL: URL) throws {
        guard FileManager.default.fileExists(atPath: activeAuthFileURL.path) else { return }

        let current = try Data(contentsOf: activeAuthFileURL)
        let next = try Data(contentsOf: sourceAuthURL)
        guard current != next else { return }

        try ensureAccountsDirectory()
        let backupURL = accountsDirectoryURL.appendingPathComponent("auth.json.bak")
        try current.write(to: backupURL, options: .atomic)
        try Self.setOwnerOnlyPermissions(backupURL)
        Self.logger.info("backed up active auth to \(backupURL.lastPathComponent, privacy: .public)")
    }

    private func replaceActiveAuth(with sourceAuthURL: URL) throws {
        let data = try Data(contentsOf: sourceAuthURL)
        try FileManager.default.createDirectory(
            at: activeAuthFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: activeAuthFileURL, options: .atomic)
        try Self.setOwnerOnlyPermissions(activeAuthFileURL)
        Self.logger.info("replaced active auth source=\(sourceAuthURL.path, privacy: .private) target=\(activeAuthFileURL.path, privacy: .private)")
    }

    private func ensureAccountsDirectory() throws {
        try FileManager.default.createDirectory(
            at: accountsDirectoryURL,
            withIntermediateDirectories: true
        )
        try Self.setOwnerOnlyDirectoryPermissions(accountsDirectoryURL)
    }

    private static func defaultApplicationSupportURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Usage", isDirectory: true)
    }

    private static func defaultCodexHomeURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            return URL(fileURLWithPath: configured.expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private static func accountSnapshotFilename(accountKey: String) throws -> String {
        let fileKey = keyNeedsFilenameEncoding(accountKey)
            ? base64URLNoPadding(accountKey)
            : accountKey
        return fileKey + ".auth.json"
    }

    private static func keyNeedsFilenameEncoding(_ key: String) -> Bool {
        if key.isEmpty || key == "." || key == ".." { return true }
        for scalar in key.unicodeScalars {
            if CharacterSet.codexAccountFilenameAllowed.contains(scalar) {
                continue
            }
            return true
        }
        return false
    }

    private static func base64URLNoPadding(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func setOwnerOnlyPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func setOwnerOnlyDirectoryPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}

enum CodexUsageAccountStoreError: LocalizedError {
    case authSnapshotNotFound(String)
    case unsupportedSchema(Int)
    case decodeFailed(String)
    case accountNotFound
    case noManagedAccounts
    case activeAccountCannotBeRemoved
    case activeAuthRestoreFailed(String)
    case authSnapshotRestoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .authSnapshotNotFound(let path):
            return "Managed account auth snapshot was not found at \(path)."
        case .unsupportedSchema(let version):
            return "Codex Usage account registry schema \(version) is newer than this app supports."
        case .decodeFailed(let message):
            return "Could not decode Codex Usage account registry: \(message)"
        case .accountNotFound:
            return "Selected Codex Usage account was not found."
        case .noManagedAccounts:
            return "No Codex Usage accounts are configured. Add an account in Settings."
        case .activeAccountCannotBeRemoved:
            return "The current Codex Usage account cannot be removed. Switch to another account first."
        case .activeAuthRestoreFailed(let message):
            return "Could not restore the previous active Codex auth after a failed account update: \(message)"
        case .authSnapshotRestoreFailed(let message):
            return "Could not restore the managed account auth snapshot after a failed account update: \(message)"
        }
    }
}

private struct ManagedAccountsRegistryFile: Codable {
    var schemaVersion: Int
    var activeAccountKey: String?
    var accounts: [ManagedAccountRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case activeAccountKey = "active_account_key"
        case accounts
    }
}

private struct ManagedAccountRecord: Codable {
    var accountKey: String
    var chatgptAccountID: String
    var chatgptUserID: String
    var email: String
    var alias: String
    var accountName: String?
    var plan: String?
    var authMode: String?
    var createdAt: Int64?
    var lastUsedAt: Int64?
    var lastUsage: ManagedRateLimitSnapshot?
    var lastUsageAt: Int64?

    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
        case chatgptAccountID = "chatgpt_account_id"
        case chatgptUserID = "chatgpt_user_id"
        case email
        case alias
        case accountName = "account_name"
        case plan
        case authMode = "auth_mode"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case lastUsage = "last_usage"
        case lastUsageAt = "last_usage_at"
    }

    func managedAccount(activeAccountKey: String?) -> CodexManagedAccount {
        var account = CodexManagedAccount(
            accountKey: accountKey,
            chatgptAccountID: chatgptAccountID,
            chatgptUserID: chatgptUserID,
            email: email,
            alias: alias,
            accountName: accountName,
            planType: plan ?? lastUsage?.planType,
            authMode: authMode,
            createdAt: createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastUsedAt: lastUsedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastUsageAt: lastUsageAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            storedUsage: nil,
            isActive: activeAccountKey == accountKey
        )

        if let lastUsage {
            account.storedUsage = lastUsage.usageSnapshot(
                account: account.codexAccount,
                updatedAt: account.lastUsageAt,
                sourceDescription: "Stored account"
            )
        }
        return account
    }
}

private struct ManagedRateLimitSnapshot: Codable {
    var primary: ManagedRateLimitWindow?
    var secondary: ManagedRateLimitWindow?
    var planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case planType = "plan_type"
    }

    init(primary: ManagedRateLimitWindow?, secondary: ManagedRateLimitWindow?, planType: String?) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }

    init(snapshot: UsageSnapshot) {
        self.primary = snapshot.sessionWindow.map(ManagedRateLimitWindow.init(window:))
        self.secondary = snapshot.weeklyWindow.map(ManagedRateLimitWindow.init(window:))
        self.planType = snapshot.account?.planType
    }

    func usageSnapshot(
        account: CodexAccount,
        updatedAt: Date?,
        sourceDescription: String
    ) -> UsageSnapshot {
        let session = [primary, secondary].compactMap { $0?.quotaWindow(role: "stored") }.first {
            $0.windowDurationMins == CodexUsageConstants.sessionWindowMinutes
        }
        let weekly = [primary, secondary].compactMap { $0?.quotaWindow(role: "stored") }.first {
            $0.windowDurationMins == CodexUsageConstants.weeklyWindowMinutes
        }

        return UsageSnapshot(
            account: CodexAccount(
                type: account.type,
                email: account.email,
                planType: planType ?? account.planType
            ),
            sessionWindow: session,
            weeklyWindow: weekly,
            updatedAt: updatedAt,
            sourceDescription: sourceDescription
        )
    }
}

private struct ManagedRateLimitWindow: Codable {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }

    init(usedPercent: Double?, windowMinutes: Int?, resetsAt: Int64?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    init(window: QuotaWindow) {
        self.usedPercent = window.usedPercent
        self.windowMinutes = window.windowDurationMins
        self.resetsAt = window.resetsAt.map { Int64($0.timeIntervalSince1970) }
    }

    func quotaWindow(role: String) -> QuotaWindow? {
        guard let usedPercent, let windowMinutes else { return nil }
        return QuotaWindow(
            id: "\(role)-\(windowMinutes)",
            usedPercent: usedPercent,
            windowDurationMins: windowMinutes,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private extension CharacterSet {
    static let codexAccountFilenameAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
    )
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

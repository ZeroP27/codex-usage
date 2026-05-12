import Foundation
import OSLog

struct CodexAccountsRegistryStore {
    var codexHomeURL: URL = Self.defaultCodexHomeURL()

    private static let maxSupportedSchemaVersion = 4
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "AccountsRegistry"
    )

    var accountsDirectoryURL: URL {
        codexHomeURL.appendingPathComponent("accounts", isDirectory: true)
    }

    var registryFileURL: URL {
        accountsDirectoryURL.appendingPathComponent("registry.json")
    }

    var activeAuthFileURL: URL {
        codexHomeURL.appendingPathComponent("auth.json")
    }

    func loadSnapshot() throws -> CodexAccountsRegistrySnapshot {
        guard FileManager.default.fileExists(atPath: registryFileURL.path) else {
            throw CodexAccountsRegistryError.registryNotFound(registryFileURL.path)
        }

        let data = try Data(contentsOf: registryFileURL)
        let decoded: RegistryFile
        do {
            decoded = try JSONDecoder().decode(RegistryFile.self, from: data)
        } catch {
            throw CodexAccountsRegistryError.decodeFailed(error.localizedDescription)
        }

        let schemaVersion = decoded.schemaVersion
        guard schemaVersion > 0 && schemaVersion <= Self.maxSupportedSchemaVersion else {
            throw CodexAccountsRegistryError.unsupportedSchema(schemaVersion)
        }

        let activeAccountKey = decoded.activeAccountKey
        let accounts = decoded.accounts.map { record in
            record.managedAccount(
                activeAccountKey: activeAccountKey,
                sourceDescription: "Stored registry"
            )
        }

        return CodexAccountsRegistrySnapshot(
            schemaVersion: schemaVersion,
            activeAccountKey: activeAccountKey,
            accounts: accounts,
            loadedAt: Date()
        )
    }

    func authFileURL(for accountKey: String) throws -> URL {
        let filename = try Self.accountSnapshotFilename(accountKey: accountKey)
        return accountsDirectoryURL.appendingPathComponent(filename)
    }

    func activateAccount(accountKey: String) throws {
        let registry = try loadSnapshot()
        guard registry.accounts.contains(where: { $0.accountKey == accountKey }) else {
            throw CodexAccountsRegistryError.accountNotFound
        }

        let sourceAuthURL = try authFileURL(for: accountKey)
        guard FileManager.default.fileExists(atPath: sourceAuthURL.path) else {
            throw CodexAccountsRegistryError.authSnapshotNotFound(sourceAuthURL.path)
        }

        try backupActiveAuthIfChanged(sourceAuthURL: sourceAuthURL)
        try replaceActiveAuth(with: sourceAuthURL)
        try patchActiveAccount(accountKey: accountKey, currentActiveAccountKey: registry.activeAccountKey)

        Self.logger.info("activated account key=\(accountKey, privacy: .private)")
    }

    func syncActiveAuthIfAccountIsActive(accountKey: String, authFileURL: URL) throws {
        let registry = try loadSnapshot()
        guard registry.activeAccountKey == accountKey else { return }
        try replaceActiveAuth(with: authFileURL)
        Self.logger.info("synced refreshed active auth key=\(accountKey, privacy: .private)")
    }

    private func backupActiveAuthIfChanged(sourceAuthURL: URL) throws {
        guard FileManager.default.fileExists(atPath: activeAuthFileURL.path) else { return }

        let current = try Data(contentsOf: activeAuthFileURL)
        let next = try Data(contentsOf: sourceAuthURL)
        guard current != next else { return }

        try ensureAccountsDirectory()
        let backupURL = accountsDirectoryURL.appendingPathComponent(
            "auth.json.bak.\(Self.backupTimestamp())"
        )
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
    }

    private func patchActiveAccount(accountKey: String, currentActiveAccountKey: String?) throws {
        guard currentActiveAccountKey != accountKey else { return }

        try ensureAccountsDirectory()
        let originalData = try Data(contentsOf: registryFileURL)
        guard var json = try JSONSerialization.jsonObject(with: originalData) as? [String: Any] else {
            throw CodexAccountsRegistryError.decodeFailed("Invalid registry.json")
        }

        json["active_account_key"] = accountKey
        json["active_account_activated_at_ms"] = Int64(Date().timeIntervalSince1970 * 1_000)

        let nowSeconds = Int64(Date().timeIntervalSince1970)
        if var accounts = json["accounts"] as? [[String: Any]] {
            for index in accounts.indices {
                if accounts[index]["account_key"] as? String == accountKey {
                    accounts[index]["last_used_at"] = nowSeconds
                }
            }
            json["accounts"] = accounts
        }

        let nextData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted]
        )
        guard nextData != originalData else { return }

        let backupURL = accountsDirectoryURL.appendingPathComponent(
            "registry.json.bak.\(Self.backupTimestamp())"
        )
        try originalData.write(to: backupURL, options: .atomic)
        try Self.setOwnerOnlyPermissions(backupURL)

        try nextData.write(to: registryFileURL, options: .atomic)
        try Self.setOwnerOnlyPermissions(registryFileURL)
        Self.logger.info("patched active account key=\(accountKey, privacy: .private)")
    }

    private func ensureAccountsDirectory() throws {
        try FileManager.default.createDirectory(
            at: accountsDirectoryURL,
            withIntermediateDirectories: true
        )
        try Self.setOwnerOnlyDirectoryPermissions(accountsDirectoryURL)
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

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
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

enum CodexAccountsRegistryError: LocalizedError {
    case registryNotFound(String)
    case authSnapshotNotFound(String)
    case unsupportedSchema(Int)
    case decodeFailed(String)
    case accountNotFound

    var errorDescription: String? {
        switch self {
        case .registryNotFound(let path):
            return "Codex accounts registry was not found at \(path). Add accounts with codex-auth first."
        case .authSnapshotNotFound(let path):
            return "Codex account auth snapshot was not found at \(path)."
        case .unsupportedSchema(let version):
            return "Codex accounts registry schema \(version) is newer than this app supports."
        case .decodeFailed(let message):
            return "Could not decode Codex accounts registry: \(message)"
        case .accountNotFound:
            return "Selected Codex account was not found in registry.json."
        }
    }
}

private struct RegistryFile: Decodable {
    var schemaVersion: Int
    var activeAccountKey: String?
    var accounts: [RegistryAccountRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case legacyVersion = "version"
        case activeAccountKey = "active_account_key"
        case accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .legacyVersion))
            ?? 0
        activeAccountKey = try container.decodeIfPresent(String.self, forKey: .activeAccountKey)
        accounts = try container.decodeIfPresent([RegistryAccountRecord].self, forKey: .accounts) ?? []
    }
}

private struct RegistryAccountRecord: Decodable {
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
    var lastUsage: RegistryRateLimitSnapshot?
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

    func managedAccount(
        activeAccountKey: String?,
        sourceDescription: String
    ) -> CodexManagedAccount {
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
                sourceDescription: sourceDescription
            )
        }
        return account
    }
}

private struct RegistryRateLimitSnapshot: Decodable {
    var primary: RegistryRateLimitWindow?
    var secondary: RegistryRateLimitWindow?
    var planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case planType = "plan_type"
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

private struct RegistryRateLimitWindow: Decodable {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
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

import Darwin
import CryptoKit
import Foundation
import OSLog

struct CodexManagedAccountsArchive: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var registryData: Data
    var authSnapshots: [CodexManagedAuthArchive]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case registryData = "registry_data"
        case authSnapshots = "auth_snapshots"
    }
}

struct CodexManagedAuthArchive: Codable, Equatable, Sendable {
    var accountKey: String
    var authData: Data

    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
        case authData = "auth_data"
    }
}

struct CodexManagedCredentialsSnapshot: Sendable {
    var accountKey: String
    var authData: Data
    var credentials: CodexOAuthCredentials
}

struct CodexManagedAccountsImportBaseline: Sendable {
    var snapshot: CodexManagedAccountsSnapshot
    var storageRevision: String
}

struct CodexUsageAccountStore {
    var applicationSupportURL: URL = Self.defaultApplicationSupportURL()
    var codexHomeURL: URL = Self.defaultCodexHomeURL()

    private static let schemaVersion = 1
    private static let maxSupportedSchemaVersion = 1
    private static let maximumManagedAccountCount = 100
    private static let maximumRegistryByteCount = 4 * 1_024 * 1_024
    private static let maximumAuthSnapshotByteCount = 2 * 1_024 * 1_024
    private static let maximumArchivePlaintextByteCount = 32 * 1_024 * 1_024
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "ManagedAccounts"
    )

    private enum FileLockMode {
        case shared
        case exclusive

        var operation: Int32 {
            switch self {
            case .shared:
                return LOCK_SH
            case .exclusive:
                return LOCK_EX
            }
        }
    }

    private enum ActiveAuthState {
        case managed(accountKey: String, authData: Data)
        case unmanaged
        case missing
        case unreadable
    }

    private enum ReplacementCredentialAuthority: Equatable {
        case newlyAuthenticated
        case currentActiveAuth
    }

    private struct ValidatedArchive {
        var registry: ManagedAccountsRegistryFile
        var authDataByAccountKey: [String: Data]
    }

    var accountsDirectoryURL: URL {
        applicationSupportURL.appendingPathComponent("accounts", isDirectory: true)
    }

    var registryFileURL: URL {
        accountsDirectoryURL.appendingPathComponent("registry.json")
    }

    var activeAuthFileURL: URL {
        codexHomeURL.appendingPathComponent("auth.json")
    }

    private var lockFileURL: URL {
        applicationSupportURL.appendingPathComponent("accounts.lock")
    }

    private var legacyPlaintextBackupURL: URL {
        accountsDirectoryURL.appendingPathComponent("auth.json.bak")
    }

    private static let importStagingDirectoryPrefix = ".accounts-import-"

    func performStartupMaintenance() throws {
        try withFileLock(.exclusive) {
            reportLegacyPlaintextBackupIfPresentLocked()
            try removeAbandonedImportStagingDirectoriesLocked()
        }
    }

    func loadSnapshot() throws -> CodexManagedAccountsSnapshot {
        try withFileLock(.shared) {
            let registry = try loadRegistryFile()
            return makeSnapshot(from: registry, activeAccountKey: registry.activeAccountKey)
        }
    }

    func loadSnapshot(markingActiveAccountKey activeAccountKey: String?) throws -> CodexManagedAccountsSnapshot {
        try withFileLock(.shared) {
            let registry = try loadRegistryFile()
            return makeSnapshot(from: registry, activeAccountKey: activeAccountKey)
        }
    }

    func loadImportBaseline() throws -> CodexManagedAccountsImportBaseline {
        try withFileLock(.shared) {
            let registry = try loadRegistryFile()
            return CodexManagedAccountsImportBaseline(
                snapshot: makeSnapshot(
                    from: registry,
                    activeAccountKey: registry.activeAccountKey
                ),
                storageRevision: try storageRevisionLocked()
            )
        }
    }

    private func makeSnapshot(
        from registry: ManagedAccountsRegistryFile,
        activeAccountKey: String?
    ) -> CodexManagedAccountsSnapshot {
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

    func loadManagedCredentialsForRefresh(
        accountKey: String
    ) throws -> CodexManagedCredentialsSnapshot {
        try withFileLock(.shared) {
            let registry = try loadRegistryFile()
            guard let account = registry.accounts.first(where: {
                $0.accountKey == accountKey
            }) else {
                throw CodexUsageAccountStoreError.accountNotFound
            }
            if case .managed(let activeAccountKey, _) = try activeAuthState(
                registry: registry
            ), activeAccountKey == accountKey {
                throw CodexUsageAccountStoreError.managedAuthRefreshConflict
            }

            let authURL = try authFileURL(for: accountKey)
            guard FileManager.default.fileExists(atPath: authURL.path) else {
                throw CodexUsageAccountStoreError.authSnapshotNotFound(
                    authURL.path
                )
            }
            let authData = try readSizeLimitedData(
                at: authURL,
                maximumByteCount: Self.maximumAuthSnapshotByteCount
            )
            var credentials = try validateAuthData(authData, for: account)
            if credentials.accountID == nil {
                credentials.accountID = account.chatgptAccountID
                Self.logger.info("resolved managed refresh account id from validated registry key_fp=\(LogFingerprint.account(accountKey), privacy: .public)")
            }
            return CodexManagedCredentialsSnapshot(
                accountKey: accountKey,
                authData: authData,
                credentials: credentials
            )
        }
    }

    func commitRefreshedManagedCredentials(
        accountKey: String,
        expectedAuthData: Data,
        credentials: CodexOAuthCredentials
    ) throws -> Data {
        try withFileLock(.exclusive) {
            let registry = try loadRegistryFile()
            guard let account = registry.accounts.first(where: {
                $0.accountKey == accountKey
            }) else {
                throw CodexUsageAccountStoreError.managedAuthRefreshConflict
            }
            if case .managed(let activeAccountKey, _) = try activeAuthState(
                registry: registry
            ), activeAccountKey == accountKey {
                throw CodexUsageAccountStoreError.managedAuthRefreshConflict
            }

            let authURL = try authFileURL(for: accountKey)
            guard FileManager.default.fileExists(atPath: authURL.path) else {
                throw CodexUsageAccountStoreError.managedAuthRefreshConflict
            }
            let currentAuthData = try readSizeLimitedData(
                at: authURL,
                maximumByteCount: Self.maximumAuthSnapshotByteCount
            )
            guard currentAuthData == expectedAuthData else {
                throw CodexUsageAccountStoreError.managedAuthRefreshConflict
            }
            _ = try validateAuthData(currentAuthData, for: account)

            let refreshedAccountInfo = try credentials.accountInfo()
            guard refreshedAccountInfo.accountKey == accountKey else {
                throw CodexUsageAccountStoreError.authSnapshotAccountMismatch(
                    expected: accountKey,
                    actual: refreshedAccountInfo.accountKey
                )
            }
            let updatedData = try CodexOAuthCredentialsStore.updatedData(
                credentials,
                existingData: currentAuthData
            )
            guard updatedData.count <= Self.maximumAuthSnapshotByteCount else {
                throw CodexUsageAccountStoreError.archiveTooLarge
            }
            _ = try validateAuthData(updatedData, for: account)
            try OwnerOnlyFileWriter.write(updatedData, to: authURL)
            Self.logger.info("committed refreshed managed credentials key_fp=\(LogFingerprint.account(accountKey), privacy: .public)")
            return updatedData
        }
    }

    func exportArchive() throws -> CodexManagedAccountsArchive {
        try withFileLock(.shared) {
            var registry = try loadRegistryFile()
            try validateRegistry(registry)
            var activeAuthOverride: (accountKey: String, authData: Data)?
            switch try activeAuthState(registry: registry) {
            case .managed(let accountKey, let authData):
                registry.activeAccountKey = accountKey
                activeAuthOverride = (accountKey, authData)
            case .missing, .unmanaged:
                registry.activeAccountKey = nil
            case .unreadable:
                break
            }

            let snapshots = try registry.accounts.map { account in
                let authURL = try authFileURL(for: account.accountKey)
                guard FileManager.default.fileExists(atPath: authURL.path) else {
                    throw CodexUsageAccountStoreError.authSnapshotNotFound(authURL.path)
                }
                let authData: Data
                if activeAuthOverride?.accountKey == account.accountKey,
                   let currentAuthData = activeAuthOverride?.authData
                {
                    authData = currentAuthData
                } else {
                    authData = try readSizeLimitedData(
                        at: authURL,
                        maximumByteCount: Self.maximumAuthSnapshotByteCount
                    )
                }
                guard authData.count <= Self.maximumAuthSnapshotByteCount else {
                    throw CodexUsageAccountStoreError.archiveTooLarge
                }
                try validateAuthData(authData, for: account)
                return CodexManagedAuthArchive(
                    accountKey: account.accountKey,
                    authData: authData
                )
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return CodexManagedAccountsArchive(
                schemaVersion: Self.schemaVersion,
                registryData: try encoder.encode(registry),
                authSnapshots: snapshots
            )
        }
    }

    func importArchive(
        _ archive: CodexManagedAccountsArchive,
        replacingStorageRevision expectedStorageRevision: String
    ) throws -> CodexManagedAccountsSnapshot {
        try withFileLock(.exclusive) {
            guard try storageRevisionLocked() == expectedStorageRevision else {
                throw CodexUsageAccountStoreError.storageChangedSinceImportPreview
            }
            return try importArchiveLocked(archive)
        }
    }

    func validateArchive(
        _ archive: CodexManagedAccountsArchive
    ) throws -> CodexManagedAccountsSnapshot {
        let validated = try validatedArchive(archive)
        return makeSnapshot(
            from: validated.registry,
            activeAccountKey: validated.registry.activeAccountKey
        )
    }

    private func importArchiveLocked(
        _ archive: CodexManagedAccountsArchive
    ) throws -> CodexManagedAccountsSnapshot {
        let validated = try validatedArchive(archive)
        var registry = validated.registry
        switch try activeAuthState(registry: registry) {
        case .managed(let accountKey, _):
            registry.activeAccountKey = accountKey
        case .missing, .unmanaged, .unreadable:
            registry.activeAccountKey = nil
        }

        let stagingURL = applicationSupportURL.appendingPathComponent(
            "\(Self.importStagingDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        var removeStagingOnExit = true
        defer {
            if removeStagingOnExit,
               FileManager.default.fileExists(atPath: stagingURL.path)
            {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false
        )
        try Self.setOwnerOnlyDirectoryPermissions(stagingURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try OwnerOnlyFileWriter.write(
            try encoder.encode(registry),
            to: stagingURL.appendingPathComponent("registry.json")
        )
        for account in registry.accounts {
            guard let authData = validated.authDataByAccountKey[account.accountKey] else {
                throw CodexUsageAccountStoreError.archiveInvalid(
                    "An account auth snapshot is missing."
                )
            }
            try OwnerOnlyFileWriter.write(
                authData,
                to: stagingURL.appendingPathComponent(
                    try Self.accountSnapshotFilename(accountKey: account.accountKey)
                )
            )
        }
        if FileManager.default.fileExists(atPath: legacyPlaintextBackupURL.path) {
            let legacyBackupData = try readSizeLimitedData(
                at: legacyPlaintextBackupURL,
                maximumByteCount: Self.maximumAuthSnapshotByteCount
            )
            try OwnerOnlyFileWriter.write(
                legacyBackupData,
                to: stagingURL.appendingPathComponent("auth.json.bak")
            )
            Self.logger.info("preserved legacy active auth backup during managed account import filename=auth.json.bak")
        }

        if FileManager.default.fileExists(atPath: accountsDirectoryURL.path) {
            guard renameatx_np(
                AT_FDCWD,
                stagingURL.path,
                AT_FDCWD,
                accountsDirectoryURL.path,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                let message = POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                ).localizedDescription
                throw CodexUsageAccountStoreError.importCommitFailed(message)
            }

            do {
                try FileManager.default.removeItem(at: stagingURL)
                removeStagingOnExit = false
            } catch {
                // The swap is the commit point. removeItem may already have
                // deleted part of the old directory, so swapping it back can
                // corrupt the live account set. Keep any remainder for the
                // next startup's exact UUID-staging cleanup instead.
                removeStagingOnExit = false
                Self.logger.error("managed account import committed but old directory cleanup failed staging=\(stagingURL.path, privacy: .private) error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            }
        } else {
            guard rename(stagingURL.path, accountsDirectoryURL.path) == 0 else {
                let message = POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                ).localizedDescription
                throw CodexUsageAccountStoreError.importCommitFailed(message)
            }
            removeStagingOnExit = false
        }

        Self.logger.info("imported managed account archive count=\(registry.accounts.count, privacy: .public) active_fp=\(LogFingerprint.account(registry.activeAccountKey), privacy: .public)")
        return makeSnapshot(from: registry, activeAccountKey: registry.activeAccountKey)
    }

    private func reportLegacyPlaintextBackupIfPresentLocked() {
        guard FileManager.default.fileExists(
            atPath: legacyPlaintextBackupURL.path
        ) else {
            return
        }
        Self.logger.warning("legacy active auth backup preserved pending explicit user cleanup filename=auth.json.bak")
    }

    private func removeAbandonedImportStagingDirectoriesLocked() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: applicationSupportURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(Self.importStagingDirectoryPrefix) else {
                continue
            }
            let identifier = String(
                name.dropFirst(Self.importStagingDirectoryPrefix.count)
            )
            guard UUID(uuidString: identifier) != nil else {
                continue
            }
            try FileManager.default.removeItem(at: entry)
            Self.logger.info("removed abandoned managed account import staging directory id=\(identifier, privacy: .private)")
        }
    }

    private func validatedArchive(
        _ archive: CodexManagedAccountsArchive
    ) throws -> ValidatedArchive {
        guard archive.schemaVersion == Self.schemaVersion else {
            throw CodexUsageAccountStoreError.unsupportedSchema(
                archive.schemaVersion
            )
        }
        guard archive.registryData.count <= Self.maximumRegistryByteCount else {
            throw CodexUsageAccountStoreError.archiveTooLarge
        }

        let registry: ManagedAccountsRegistryFile
        do {
            registry = try JSONDecoder().decode(
                ManagedAccountsRegistryFile.self,
                from: archive.registryData
            )
        } catch {
            throw CodexUsageAccountStoreError.archiveInvalid(
                "The managed account registry could not be decoded."
            )
        }
        try validateRegistry(registry)

        guard archive.authSnapshots.count == registry.accounts.count else {
            throw CodexUsageAccountStoreError.archiveInvalid(
                "The auth snapshot count does not match the account registry."
            )
        }

        var totalBytes = archive.registryData.count
        var authDataByAccountKey: [String: Data] = [:]
        for snapshot in archive.authSnapshots {
            guard snapshot.authData.count <= Self.maximumAuthSnapshotByteCount else {
                throw CodexUsageAccountStoreError.archiveTooLarge
            }
            guard totalBytes <= Self.maximumArchivePlaintextByteCount - snapshot.authData.count else {
                throw CodexUsageAccountStoreError.archiveTooLarge
            }
            totalBytes += snapshot.authData.count
            guard authDataByAccountKey.updateValue(
                snapshot.authData,
                forKey: snapshot.accountKey
            ) == nil else {
                throw CodexUsageAccountStoreError.archiveInvalid(
                    "The archive contains duplicate auth snapshots."
                )
            }
        }

        let expectedAccountKeys = Set(registry.accounts.map(\.accountKey))
        guard Set(authDataByAccountKey.keys) == expectedAccountKeys else {
            throw CodexUsageAccountStoreError.archiveInvalid(
                "The auth snapshots do not match the account registry."
            )
        }
        for account in registry.accounts {
            guard let authData = authDataByAccountKey[account.accountKey] else {
                throw CodexUsageAccountStoreError.archiveInvalid(
                    "An account auth snapshot is missing."
                )
            }
            try validateAuthData(authData, for: account)
        }

        return ValidatedArchive(
            registry: registry,
            authDataByAccountKey: authDataByAccountKey
        )
    }

    private func validateRegistry(
        _ registry: ManagedAccountsRegistryFile
    ) throws {
        guard registry.schemaVersion == Self.schemaVersion else {
            throw CodexUsageAccountStoreError.unsupportedSchema(
                registry.schemaVersion
            )
        }
        guard registry.accounts.count <= Self.maximumManagedAccountCount else {
            throw CodexUsageAccountStoreError.archiveInvalid(
                "The archive contains too many managed accounts."
            )
        }

        var accountKeys = Set<String>()
        var snapshotFilenames = Set<String>()
        for account in registry.accounts {
            let accountKey = account.accountKey
            guard !accountKey.isEmpty,
                  accountKey.utf8.count <= 160,
                  !account.chatgptAccountID.isEmpty,
                  account.chatgptAccountID.utf8.count <= 160,
                  !account.chatgptAccountID.contains("::"),
                  !account.chatgptUserID.isEmpty,
                  account.chatgptUserID.utf8.count <= 160,
                  !account.chatgptUserID.contains("::"),
                  accountKey == "\(account.chatgptUserID)::\(account.chatgptAccountID)",
                  !account.email.isEmpty,
                  account.email.utf8.count <= 512,
                  account.alias.utf8.count <= 512,
                  (account.accountName?.utf8.count ?? 0) <= 512,
                  (account.plan?.utf8.count ?? 0) <= 128,
                  account.authMode == nil || account.authMode == "chatgpt"
            else {
                throw CodexUsageAccountStoreError.archiveInvalid(
                    "The account registry contains an invalid account identity."
                )
            }
            guard accountKeys.insert(accountKey).inserted else {
                throw CodexUsageAccountStoreError.archiveInvalid(
                    "The account registry contains duplicate accounts."
                )
            }
            if let resetCredits = account.lastUsage?.resetCredits {
                let maximumExpiration = Date()
                    .addingTimeInterval(
                        ResetCreditsNormalizer.maximumExpirationHorizon
                    )
                    .timeIntervalSince1970
                guard (0...ResetCreditsNormalizer.maximumAvailableCount)
                    .contains(resetCredits.availableCount),
                    (0...resetCredits.availableCount)
                    .contains(resetCredits.reportedAvailableCount),
                    resetCredits.expirations.count
                        <= resetCredits.reportedAvailableCount,
                    (resetCredits.expirations.allSatisfy {
                        $0 >= 0 && TimeInterval($0) <= maximumExpiration
                    })
                else {
                    throw CodexUsageAccountStoreError.archiveInvalid(
                        "The account registry contains invalid reset credit data."
                    )
                }
            }
            let filename = try Self.accountSnapshotFilename(
                accountKey: accountKey
            )
            guard snapshotFilenames.insert(filename.lowercased()).inserted else {
                throw CodexUsageAccountStoreError.archiveInvalid(
                    "Two accounts resolve to the same auth snapshot filename."
                )
            }
        }

        if let activeAccountKey = registry.activeAccountKey,
           !accountKeys.contains(activeAccountKey)
        {
            throw CodexUsageAccountStoreError.archiveInvalid(
                "The active account is not present in the account registry."
            )
        }
    }

    @discardableResult
    private func validateAuthData(
        _ authData: Data,
        for account: ManagedAccountRecord
    ) throws -> CodexOAuthCredentials {
        let credentials: CodexOAuthCredentials
        let accountInfo: CodexOAuthAccountInfo
        do {
            credentials = try CodexOAuthCredentialsStore.load(from: authData)
            accountInfo = try credentials.accountInfo()
        } catch {
            throw CodexUsageAccountStoreError.archiveInvalid(
                "A managed account auth snapshot is invalid."
            )
        }
        guard accountInfo.accountKey == account.accountKey,
              accountInfo.chatgptAccountID == account.chatgptAccountID,
              accountInfo.chatgptUserID == account.chatgptUserID
        else {
            throw CodexUsageAccountStoreError.authSnapshotAccountMismatch(
                expected: account.accountKey,
                actual: accountInfo.accountKey
            )
        }
        return credentials
    }

    func addAccount(authData sourceData: Data) throws -> CodexManagedAccount {
        try withFileLock(.exclusive) {
            try addAccountLocked(authData: sourceData)
        }
    }

    private func addAccountLocked(authData sourceData: Data) throws -> CodexManagedAccount {
        guard sourceData.count <= Self.maximumAuthSnapshotByteCount else {
            throw CodexUsageAccountStoreError.archiveTooLarge
        }
        let credentials = try CodexOAuthCredentialsStore.load(from: sourceData)
        let accountInfo = try credentials.accountInfo()
        let destinationURL = try self.authFileURL(for: accountInfo.accountKey)
        Self.logger.info("importing managed account key_fp=\(LogFingerprint.account(accountInfo.accountKey), privacy: .public) account_id_fp=\(LogFingerprint.account(accountInfo.chatgptAccountID), privacy: .public) key=\(accountInfo.accountKey, privacy: .private) email=\(accountInfo.email, privacy: .private) plan=\(accountInfo.planType ?? "missing", privacy: .public) account_id_source=\(accountInfo.accountIDSource, privacy: .public)")

        _ = try captureActiveAuthToManagedSnapshotLocked()

        let existingRegistry = try loadRegistryFile()
        for existingAccount in existingRegistry.accounts
            where existingAccount.accountKey != accountInfo.accountKey
        {
            let existingFilename = try Self.accountSnapshotFilename(
                accountKey: existingAccount.accountKey
            )
            guard existingFilename.lowercased()
                    != destinationURL.lastPathComponent.lowercased()
            else {
                throw CodexUsageAccountStoreError.archiveInvalid(
                    "Two accounts resolve to the same auth snapshot filename."
                )
            }
        }

        try ensureAccountsDirectory()
        let previousSnapshotData = try authSnapshotDataIfExists(at: destinationURL)
        try OwnerOnlyFileWriter.write(sourceData, to: destinationURL)
        Self.logger.info("stored managed auth snapshot key_fp=\(LogFingerprint.account(accountInfo.accountKey), privacy: .public) key=\(accountInfo.accountKey, privacy: .private) path=\(destinationURL.path, privacy: .private)")

        do {
            var registry = existingRegistry
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
            try validateRegistry(registry)
            Self.logger.info("managed account registry prepared key_fp=\(LogFingerprint.account(accountInfo.accountKey), privacy: .public) previous_active_fp=\(LogFingerprint.account(previousActiveKey), privacy: .public) key=\(accountInfo.accountKey, privacy: .private) replacing_existing=\((existing != nil), privacy: .public) previous_active=\(previousActiveKey ?? "missing", privacy: .private) next_count=\(registry.accounts.count, privacy: .public)")
            try replaceActiveAuthThenSaveRegistry(
                sourceAuthURL: destinationURL,
                registry: registry,
                keyForLog: accountInfo.accountKey,
                credentialAuthority: .newlyAuthenticated
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
        try withFileLock(.exclusive) {
            try removeAccountLocked(accountKey: accountKey)
        }
    }

    private func removeAccountLocked(accountKey: String) throws -> CodexManagedAccountsSnapshot {
        var registry = try loadRegistryFile()
        guard registry.accounts.contains(where: { $0.accountKey == accountKey }) else {
            throw CodexUsageAccountStoreError.accountNotFound
        }

        let previousRegistryActiveKey = registry.activeAccountKey
        let activeAuthState = try activeAuthState(registry: registry)
        switch activeAuthState {
        case .managed(let activeAccountKey, _):
            registry.activeAccountKey = activeAccountKey
        case .missing, .unmanaged:
            registry.activeAccountKey = nil
        case .unreadable:
            break
        }

        guard registry.activeAccountKey != accountKey else {
            throw CodexUsageAccountStoreError.activeAccountCannotBeRemoved
        }
        if registry.activeAccountKey != previousRegistryActiveKey {
            Self.logger.info("reconciled registry active account before removal previous_fp=\(LogFingerprint.account(previousRegistryActiveKey), privacy: .public) actual_fp=\(LogFingerprint.account(registry.activeAccountKey), privacy: .public)")
        }

        let authURL = try authFileURL(for: accountKey)
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            Self.logger.error("managed account removal failed missing auth snapshot key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private) path=\(authURL.path, privacy: .private)")
            throw CodexUsageAccountStoreError.authSnapshotNotFound(authURL.path)
        }

        Self.logger.info("removing managed account key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private) previous_count=\(registry.accounts.count, privacy: .public)")
        let previousSnapshotData = try readSizeLimitedData(
            at: authURL,
            maximumByteCount: Self.maximumAuthSnapshotByteCount
        )
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
        return makeSnapshot(from: registry, activeAccountKey: registry.activeAccountKey)
    }

    func activateAccount(accountKey: String) throws {
        try withFileLock(.exclusive) {
            try activateAccountLocked(accountKey: accountKey)
        }
    }

    private func activateAccountLocked(accountKey: String) throws {
        var registry = try loadRegistryFile()
        guard registry.accounts.contains(where: { $0.accountKey == accountKey }) else {
            throw CodexUsageAccountStoreError.accountNotFound
        }

        _ = try captureActiveAuthToManagedSnapshotLocked()

        let sourceAuthURL = try authFileURL(for: accountKey)
        guard FileManager.default.fileExists(atPath: sourceAuthURL.path) else {
            throw CodexUsageAccountStoreError.authSnapshotNotFound(sourceAuthURL.path)
        }
        let sourceCredentials = try CodexOAuthCredentialsStore.load(from: sourceAuthURL)
        let sourceAccountInfo = try sourceCredentials.accountInfo()
        guard sourceAccountInfo.accountKey == accountKey else {
            throw CodexUsageAccountStoreError.authSnapshotAccountMismatch(
                expected: accountKey,
                actual: sourceAccountInfo.accountKey
            )
        }

        let previousActiveKey = registry.activeAccountKey
        Self.logger.info("activating managed account key_fp=\(LogFingerprint.account(accountKey), privacy: .public) previous_active_fp=\(LogFingerprint.account(previousActiveKey), privacy: .public) key=\(accountKey, privacy: .private) previous_active=\(previousActiveKey ?? "missing", privacy: .private)")
        patchActiveAccount(accountKey: accountKey, in: &registry)
        try replaceActiveAuthThenSaveRegistry(
            sourceAuthURL: sourceAuthURL,
            registry: registry,
            keyForLog: accountKey,
            credentialAuthority: .currentActiveAuth
        )

        Self.logger.info("activated managed account key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private)")
    }

    @discardableResult
    func captureActiveAuthToManagedSnapshot(expectedAccountKey: String? = nil) throws -> String? {
        try withFileLock(.exclusive) {
            try captureActiveAuthToManagedSnapshotLocked(expectedAccountKey: expectedAccountKey)
        }
    }

    private func captureActiveAuthToManagedSnapshotLocked(
        expectedAccountKey: String? = nil
    ) throws -> String? {
        guard FileManager.default.fileExists(atPath: activeAuthFileURL.path) else {
            Self.logger.info("active auth capture skipped reason=missing_active_auth expected_fp=\(LogFingerprint.account(expectedAccountKey), privacy: .public)")
            return nil
        }

        let activeData = try readSizeLimitedData(
            at: activeAuthFileURL,
            maximumByteCount: Self.maximumAuthSnapshotByteCount
        )
        let activeAccountInfo: CodexOAuthAccountInfo
        do {
            let activeCredentials = try CodexOAuthCredentialsStore.load(from: activeData)
            activeAccountInfo = try activeCredentials.accountInfo()
        } catch {
            Self.logger.info("active auth capture skipped reason=unreadable_active_auth expected_fp=\(LogFingerprint.account(expectedAccountKey), privacy: .public) error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            return nil
        }

        if let expectedAccountKey, activeAccountInfo.accountKey != expectedAccountKey {
            Self.logger.info("active auth capture skipped reason=unexpected_account expected_fp=\(LogFingerprint.account(expectedAccountKey), privacy: .public) active_fp=\(LogFingerprint.account(activeAccountInfo.accountKey), privacy: .public) expected=\(expectedAccountKey, privacy: .private) active=\(activeAccountInfo.accountKey, privacy: .private)")
            return nil
        }

        let registry = try loadRegistryFile()
        guard registryContainsIdentity(activeAccountInfo, in: registry) else {
            Self.logger.info("active auth capture skipped reason=unmanaged_account active_fp=\(LogFingerprint.account(activeAccountInfo.accountKey), privacy: .public) active=\(activeAccountInfo.accountKey, privacy: .private)")
            return nil
        }

        let managedAuthURL = try authFileURL(for: activeAccountInfo.accountKey)
        if let managedData = try authSnapshotDataIfExists(at: managedAuthURL),
           managedData == activeData
        {
            Self.logger.info("active auth capture skipped reason=identical_snapshot active_fp=\(LogFingerprint.account(activeAccountInfo.accountKey), privacy: .public) active=\(activeAccountInfo.accountKey, privacy: .private)")
            return activeAccountInfo.accountKey
        }

        try ensureAccountsDirectory()
        try OwnerOnlyFileWriter.write(activeData, to: managedAuthURL)
        Self.logger.info("active auth captured into managed snapshot active_fp=\(LogFingerprint.account(activeAccountInfo.accountKey), privacy: .public) active=\(activeAccountInfo.accountKey, privacy: .private)")
        return activeAccountInfo.accountKey
    }

    func managedAccountKeyForActiveAuth() throws -> String? {
        try withFileLock(.shared) {
            let registry = try loadRegistryFile()
            guard case .managed(let accountKey, _) = try activeAuthState(registry: registry) else {
                return nil
            }
            return accountKey
        }
    }

    private func activeAuthState(
        registry: ManagedAccountsRegistryFile
    ) throws -> ActiveAuthState {
        guard FileManager.default.fileExists(atPath: activeAuthFileURL.path) else {
            Self.logger.info("active auth account lookup skipped reason=missing_active_auth")
            return .missing
        }

        let activeData = try readSizeLimitedData(
            at: activeAuthFileURL,
            maximumByteCount: Self.maximumAuthSnapshotByteCount
        )
        let activeAccountInfo: CodexOAuthAccountInfo
        do {
            activeAccountInfo = try CodexOAuthCredentialsStore.load(from: activeData).accountInfo()
        } catch {
            Self.logger.info("active auth account lookup skipped reason=unreadable_active_auth error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            return .unreadable
        }

        guard registryContainsIdentity(activeAccountInfo, in: registry) else {
            Self.logger.info("active auth account lookup skipped reason=unmanaged_account active_fp=\(LogFingerprint.account(activeAccountInfo.accountKey), privacy: .public) active=\(activeAccountInfo.accountKey, privacy: .private)")
            return .unmanaged
        }

        Self.logger.info("active auth account resolved active_fp=\(LogFingerprint.account(activeAccountInfo.accountKey), privacy: .public) active=\(activeAccountInfo.accountKey, privacy: .private)")
        return .managed(
            accountKey: activeAccountInfo.accountKey,
            authData: activeData
        )
    }

    func updateUsage(accountKey: String, snapshot: UsageSnapshot) throws -> CodexManagedAccount {
        try withFileLock(.exclusive) {
            try updateUsageLocked(accountKey: accountKey, snapshot: snapshot)
        }
    }

    private func updateUsageLocked(
        accountKey: String,
        snapshot: UsageSnapshot
    ) throws -> CodexManagedAccount {
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
        Self.logger.info("updated managed account usage key_fp=\(LogFingerprint.account(accountKey), privacy: .public) key=\(accountKey, privacy: .private) session_present=\((snapshot.sessionWindow != nil), privacy: .public) weekly_present=\((snapshot.weeklyWindow != nil), privacy: .public) reset_credits_present=\((snapshot.resetCredits != nil), privacy: .public) reset_credits_count=\(snapshot.resetCredits?.availableCount ?? 0, privacy: .public)")
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

        let data = try readSizeLimitedData(
            at: registryFileURL,
            maximumByteCount: Self.maximumRegistryByteCount
        )
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
        try validateRegistry(decoded)
        return decoded
    }

    private func storageRevisionLocked() throws -> String {
        var hasher = SHA256()

        func update(_ data: Data, in hasher: inout SHA256) {
            var byteCount = UInt64(data.count).bigEndian
            Swift.withUnsafeBytes(of: &byteCount) { bytes in
                hasher.update(data: Data(bytes))
            }
            hasher.update(data: data)
        }

        if FileManager.default.fileExists(atPath: registryFileURL.path) {
            update(
                try readSizeLimitedData(
                    at: registryFileURL,
                    maximumByteCount: Self.maximumRegistryByteCount
                ),
                in: &hasher
            )
        } else {
            update(Data("missing-registry".utf8), in: &hasher)
        }

        let registry = try loadRegistryFile()
        for account in registry.accounts.sorted(by: {
            $0.accountKey < $1.accountKey
        }) {
            update(Data(account.accountKey.utf8), in: &hasher)
            let authURL = try authFileURL(for: account.accountKey)
            if FileManager.default.fileExists(atPath: authURL.path) {
                update(
                    try readSizeLimitedData(
                        at: authURL,
                        maximumByteCount: Self.maximumAuthSnapshotByteCount
                    ),
                    in: &hasher
                )
            } else {
                update(Data("missing-auth".utf8), in: &hasher)
            }
        }

        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func saveRegistryFile(_ registry: ManagedAccountsRegistryFile) throws {
        try validateRegistry(registry)
        try ensureAccountsDirectory()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        guard data.count <= Self.maximumRegistryByteCount else {
            throw CodexUsageAccountStoreError.archiveTooLarge
        }
        try OwnerOnlyFileWriter.write(data, to: registryFileURL)
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
        keyForLog accountKey: String,
        credentialAuthority: ReplacementCredentialAuthority
    ) throws {
        let previousActiveAuthData = try authSnapshotDataIfExists(at: activeAuthFileURL)
        if let previousActiveAuthData {
            let activeAccountInfo: CodexOAuthAccountInfo
            do {
                activeAccountInfo = try CodexOAuthCredentialsStore
                    .load(from: previousActiveAuthData)
                    .accountInfo()
            } catch {
                throw CodexUsageAccountStoreError.activeAuthCannotBeReplaced(
                    "The current ~/.codex/auth.json could not be identified, so Codex Usage left it unchanged."
                )
            }
            guard registryContainsIdentity(activeAccountInfo, in: registry) else {
                throw CodexUsageAccountStoreError.activeAuthCannotBeReplaced(
                    "The current ~/.codex/auth.json belongs to an account that Codex Usage does not manage, so it was left unchanged."
                )
            }

            if activeAccountInfo.accountKey == accountKey,
               credentialAuthority == .currentActiveAuth
            {
                let previousSourceData = try authSnapshotDataIfExists(
                    at: sourceAuthURL
                )
                try OwnerOnlyFileWriter.write(
                    previousActiveAuthData,
                    to: sourceAuthURL
                )
                do {
                    try saveRegistryFile(registry)
                } catch {
                    try restoreAuthSnapshotAfterFailure(
                        at: sourceAuthURL,
                        previousData: previousSourceData,
                        keyForLog: accountKey
                    )
                    throw error
                }
                Self.logger.info("active auth already matched requested account; captured latest credentials without replacement key_fp=\(LogFingerprint.account(accountKey), privacy: .public)")
                return
            }

            try captureLatestActiveAuthBeforeReplacement(
                previousActiveAuthData,
                excludingAccountKey: accountKey,
                registry: registry
            )
        }
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
        return try readSizeLimitedData(
            at: url,
            maximumByteCount: Self.maximumAuthSnapshotByteCount
        )
    }

    private func readSizeLimitedData(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        let chunkByteCount = 64 * 1_024
        while data.count <= maximumByteCount {
            let remaining = maximumByteCount + 1 - data.count
            let chunk = try handle.read(
                upToCount: min(chunkByteCount, remaining)
            ) ?? Data()
            if chunk.isEmpty {
                return data
            }
            data.append(chunk)
        }
        throw CodexUsageAccountStoreError.archiveTooLarge
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
            try OwnerOnlyFileWriter.write(previousData, to: url)
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

    private func captureLatestActiveAuthBeforeReplacement(
        _ activeData: Data,
        excludingAccountKey: String,
        registry: ManagedAccountsRegistryFile
    ) throws {
        let credentials: CodexOAuthCredentials
        let accountInfo: CodexOAuthAccountInfo
        do {
            credentials = try CodexOAuthCredentialsStore.load(from: activeData)
            accountInfo = try credentials.accountInfo()
        } catch {
            Self.logger.info("final active auth capture skipped reason=unreadable_active_auth error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            return
        }

        guard accountInfo.accountKey != excludingAccountKey,
              registryContainsIdentity(accountInfo, in: registry)
        else {
            return
        }

        let managedAuthURL = try authFileURL(for: accountInfo.accountKey)
        if try authSnapshotDataIfExists(at: managedAuthURL) == activeData {
            return
        }
        try ensureAccountsDirectory()
        try OwnerOnlyFileWriter.write(activeData, to: managedAuthURL)
        Self.logger.info("captured latest active auth immediately before replacement active_fp=\(LogFingerprint.account(accountInfo.accountKey), privacy: .public) active=\(accountInfo.accountKey, privacy: .private)")
    }

    private func registryContainsIdentity(
        _ accountInfo: CodexOAuthAccountInfo,
        in registry: ManagedAccountsRegistryFile
    ) -> Bool {
        registry.accounts.contains {
            $0.accountKey == accountInfo.accountKey
                && $0.chatgptAccountID == accountInfo.chatgptAccountID
                && $0.chatgptUserID == accountInfo.chatgptUserID
        }
    }

    private func replaceActiveAuth(with sourceAuthURL: URL) throws {
        let data = try readSizeLimitedData(
            at: sourceAuthURL,
            maximumByteCount: Self.maximumAuthSnapshotByteCount
        )
        try FileManager.default.createDirectory(
            at: activeAuthFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try OwnerOnlyFileWriter.write(data, to: activeAuthFileURL)
        Self.logger.info("replaced active auth source=\(sourceAuthURL.path, privacy: .private) target=\(activeAuthFileURL.path, privacy: .private)")
    }

    private func ensureAccountsDirectory() throws {
        try ensureApplicationSupportDirectory()
        try FileManager.default.createDirectory(
            at: accountsDirectoryURL,
            withIntermediateDirectories: true
        )
        try Self.setOwnerOnlyDirectoryPermissions(accountsDirectoryURL)
    }

    private func ensureApplicationSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        try Self.setOwnerOnlyDirectoryPermissions(applicationSupportURL)
    }

    private func withFileLock<T>(
        _ mode: FileLockMode,
        operation: () throws -> T
    ) throws -> T {
        try ensureApplicationSupportDirectory()
        let descriptor = Darwin.open(
            lockFileURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CodexUsageAccountStoreError.lockFailed(
                POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            )
        }
        defer { Darwin.close(descriptor) }

        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CodexUsageAccountStoreError.lockFailed(
                POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            )
        }
        guard flock(descriptor, mode.operation) == 0 else {
            throw CodexUsageAccountStoreError.lockFailed(
                POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            )
        }
        defer { flock(descriptor, LOCK_UN) }

        return try operation()
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

    private static func setOwnerOnlyDirectoryPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}

enum CodexUsageAccountStoreError: LocalizedError {
    case authSnapshotNotFound(String)
    case authSnapshotAccountMismatch(expected: String, actual: String)
    case unsupportedSchema(Int)
    case decodeFailed(String)
    case accountNotFound
    case noManagedAccounts
    case activeAccountCannotBeRemoved
    case activeAuthRestoreFailed(String)
    case authSnapshotRestoreFailed(String)
    case lockFailed(String)
    case archiveInvalid(String)
    case archiveTooLarge
    case importCommitFailed(String)
    case activeAuthCannotBeReplaced(String)
    case managedAuthRefreshConflict
    case storageChangedSinceImportPreview

    var errorDescription: String? {
        switch self {
        case .authSnapshotNotFound(let path):
            return "Managed account auth snapshot was not found at \(path)."
        case .authSnapshotAccountMismatch:
            return "Managed account auth snapshot belongs to a different account. Add the account again."
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
        case .lockFailed(let message):
            return "Could not lock Codex Usage managed account storage: \(message)"
        case .archiveInvalid(let message):
            return "The Codex Usage account archive is invalid. \(message)"
        case .archiveTooLarge:
            return "The Codex Usage account archive exceeds the supported size limit."
        case .importCommitFailed(let message):
            return "Could not replace the managed account configuration: \(message)"
        case .activeAuthCannotBeReplaced(let message):
            return message
        case .managedAuthRefreshConflict:
            return "Managed account credentials changed while quota was refreshing. Refresh the account again."
        case .storageChangedSinceImportPreview:
            return "Managed accounts changed after the import preview. Open the backup again and review the updated replacement summary."
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
    var resetCredits: ManagedResetCreditsSummary?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case planType = "plan_type"
        case resetCredits = "reset_credits"
    }

    init(
        primary: ManagedRateLimitWindow?,
        secondary: ManagedRateLimitWindow?,
        planType: String?,
        resetCredits: ManagedResetCreditsSummary? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.resetCredits = resetCredits
    }

    init(snapshot: UsageSnapshot) {
        self.primary = snapshot.sessionWindow.map(ManagedRateLimitWindow.init(window:))
        self.secondary = snapshot.weeklyWindow.map(ManagedRateLimitWindow.init(window:))
        self.planType = snapshot.account?.planType
        self.resetCredits = snapshot.resetCredits.map(
            ManagedResetCreditsSummary.init(summary:)
        )
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
            resetCredits: resetCredits?.summary,
            updatedAt: updatedAt,
            sourceDescription: sourceDescription
        )
    }
}

private struct ManagedResetCreditsSummary: Codable {
    var availableCount: Int
    var reportedAvailableCount: Int
    var expirations: [Int64]

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case reportedAvailableCount = "reported_available_count"
        case expirations
    }

    init(summary: ResetCreditsSummary) {
        self.availableCount = summary.availableCount
        self.reportedAvailableCount = summary.reportedAvailableCount
        self.expirations = summary.expirations.compactMap {
            SafeNumericConversions.truncatingInt64($0.timeIntervalSince1970)
        }
    }

    var summary: ResetCreditsSummary {
        ResetCreditsSummary(
            availableCount: availableCount,
            reportedAvailableCount: reportedAvailableCount,
            expirations: expirations
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                .sorted()
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
        self.resetsAt = window.resetsAt.flatMap {
            SafeNumericConversions.truncatingInt64($0.timeIntervalSince1970)
        }
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

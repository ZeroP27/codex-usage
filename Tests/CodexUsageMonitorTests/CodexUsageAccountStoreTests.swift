import Foundation
import Testing
@testable import CodexUsageMonitor

struct CodexUsageAccountStoreTests {
    @Test
    func testAuthFileURLEncodesUnsafeAccountKeysOnly() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }

        #expect(try fixture.store.authFileURL(for: "simple-Key_1.2").lastPathComponent == "simple-Key_1.2.auth.json")
        #expect(
            try fixture.store.authFileURL(for: "user::account").lastPathComponent
                == "\(base64URLNoPadding("user::account")).auth.json"
        )
    }

    @Test
    func testAddAccountCreatesRegistrySnapshotAndActiveAuth() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let authData = try makeAuthData(
            email: "USER@example.COM",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus"
        )

        let account = try fixture.store.addAccount(authData: authData)
        let snapshot = try fixture.store.loadSnapshot()

        #expect(account.accountKey == "user-1::account-1")
        #expect(account.email == "user@example.com")
        #expect(account.planType == "plus")
        #expect(account.isActive)
        #expect(snapshot.activeAccountKey == account.accountKey)
        #expect(snapshot.accounts == [account])
        #expect(FileManager.default.fileExists(
            atPath: try fixture.store.authFileURL(for: account.accountKey).path
        ))
        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == authData)

        let registryData = try Data(contentsOf: fixture.store.registryFileURL)
        let registry = try #require(
            JSONSerialization.jsonObject(with: registryData) as? [String: Any]
        )
        #expect(registry["schema_version"] as? Int == 1)
        #expect(registry["active_account_key"] as? String == account.accountKey)
    }

    @Test
    func testManagedRefreshUsesValidatedRegistryAccountIDWhenTokenFieldIsMissing() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.addAccount(authData: makeAuthData(
            email: "first@example.com",
            userID: "first-user",
            accountID: "first-account",
            planType: "plus",
            includesTokenAccountID: false
        ))
        _ = try fixture.store.addAccount(authData: makeAuthData(
            email: "second@example.com",
            userID: "second-user",
            accountID: "second-account",
            planType: "pro"
        ))

        let credentials = try fixture.store.loadManagedCredentialsForRefresh(
            accountKey: first.accountKey
        ).credentials

        #expect(credentials.accountID == first.chatgptAccountID)
    }

    @Test
    func testUpdateUsagePersistsOnlySanitizedResetCreditSummary() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let account = try fixture.store.addAccount(authData: makeAuthData(
            email: "credits@example.com",
            userID: "credits-user",
            accountID: "credits-account",
            planType: "plus"
        ))
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            account: account.codexAccount,
            sessionWindow: nil,
            weeklyWindow: nil,
            resetCredits: ResetCreditsSummary(
                availableCount: 2,
                reportedAvailableCount: 1,
                expirations: [expiration]
            ),
            updatedAt: Date(),
            sourceDescription: "Test"
        )

        _ = try fixture.store.updateUsage(
            accountKey: account.accountKey,
            snapshot: snapshot
        )
        let reloaded = try #require(
            fixture.store.loadSnapshot().accounts.first?.storedUsage?.resetCredits
        )

        #expect(reloaded.availableCount == 2)
        #expect(reloaded.reportedAvailableCount == 1)
        #expect(reloaded.expirations == [expiration])

        let registryText = try #require(
            String(
                data: Data(contentsOf: fixture.store.registryFileURL),
                encoding: .utf8
            )
        )
        #expect(registryText.contains(#""reset_credits""#))
        #expect(!registryText.contains(#""credit_id""#))
    }

    @Test
    func testAddingDuplicateAccountUpdatesSnapshotWithoutDuplicatingRegistry() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let firstAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus"
        )
        let secondAuthData = try makeAuthData(
            email: "second@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "business"
        )

        let first = try fixture.store.addAccount(authData: firstAuthData)
        let second = try fixture.store.addAccount(authData: secondAuthData)
        let snapshot = try fixture.store.loadSnapshot()

        #expect(first.accountKey == second.accountKey)
        #expect(snapshot.accounts.count == 1)
        #expect(snapshot.activeAccountKey == second.accountKey)
        #expect(snapshot.accounts[0].email == "second@example.com")
        #expect(snapshot.accounts[0].planType == "business")
        #expect(snapshot.accounts[0].createdAt == first.createdAt)
        #expect(try Data(contentsOf: try fixture.store.authFileURL(for: second.accountKey)) == secondAuthData)
        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == secondAuthData)
    }

    @Test
    func testCaptureActiveAuthStoresActiveSnapshot() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let oldAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "access-old",
            refreshToken: "refresh-old",
            lastRefresh: "2026-01-01T00:00:00Z"
        )
        let newAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "access-new",
            refreshToken: "refresh-new",
            lastRefresh: "2026-01-02T00:00:00Z"
        )

        let account = try fixture.store.addAccount(authData: oldAuthData)
        try newAuthData.write(to: fixture.store.activeAuthFileURL, options: .atomic)

        let capturedAccountKey = try fixture.store.captureActiveAuthToManagedSnapshot()

        #expect(capturedAccountKey == account.accountKey)
        #expect(try Data(contentsOf: try fixture.store.authFileURL(for: account.accountKey)) == newAuthData)
    }

    @Test
    func testCaptureActiveAuthUsesActiveSnapshotAsSourceOfTruth() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let oldAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "access-old",
            refreshToken: "refresh-old",
            lastRefresh: "2026-01-01T00:00:00Z"
        )
        let newAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "access-new",
            refreshToken: "refresh-new",
            lastRefresh: "2026-01-02T00:00:00Z"
        )

        let account = try fixture.store.addAccount(authData: newAuthData)
        try oldAuthData.write(to: fixture.store.activeAuthFileURL, options: .atomic)

        let capturedAccountKey = try fixture.store.captureActiveAuthToManagedSnapshot()

        #expect(capturedAccountKey == account.accountKey)
        #expect(try Data(contentsOf: try fixture.store.authFileURL(for: account.accountKey)) == oldAuthData)
    }

    @Test
    func testManagedAccountKeyForActiveAuthUsesAuthJsonInsteadOfRegistryActiveKey() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let firstAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus"
        )
        let secondAuthData = try makeAuthData(
            email: "second@example.com",
            userID: "user-2",
            accountID: "account-2",
            planType: "pro"
        )

        let first = try fixture.store.addAccount(authData: firstAuthData)
        let second = try fixture.store.addAccount(authData: secondAuthData)
        try firstAuthData.write(to: fixture.store.activeAuthFileURL, options: .atomic)

        let activeAccountKey = try fixture.store.managedAccountKeyForActiveAuth()
        let snapshot = try fixture.store.loadSnapshot(markingActiveAccountKey: activeAccountKey)

        #expect(second.isActive)
        #expect(activeAccountKey == first.accountKey)
        #expect(snapshot.activeAccountKey == first.accountKey)
        #expect(snapshot.accounts.first(where: { $0.accountKey == first.accountKey })?.isActive == true)
        #expect(snapshot.accounts.first(where: { $0.accountKey == second.accountKey })?.isActive == false)
    }

    @Test
    func testActivateAccountPreservesExternallyRefreshedActiveSnapshotBeforeSwitching() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let firstOldAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "access-first-old",
            refreshToken: "refresh-first-old",
            lastRefresh: "2026-01-01T00:00:00Z"
        )
        let firstNewAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "access-first-new",
            refreshToken: "refresh-first-new",
            lastRefresh: "2026-01-02T00:00:00Z"
        )
        let secondAuthData = try makeAuthData(
            email: "second@example.com",
            userID: "user-2",
            accountID: "account-2",
            planType: "pro",
            accessToken: "access-second",
            refreshToken: "refresh-second",
            lastRefresh: "2026-01-01T12:00:00Z"
        )

        let first = try fixture.store.addAccount(authData: firstOldAuthData)
        let second = try fixture.store.addAccount(authData: secondAuthData)
        try fixture.store.activateAccount(accountKey: first.accountKey)
        try firstNewAuthData.write(to: fixture.store.activeAuthFileURL, options: .atomic)

        try fixture.store.activateAccount(accountKey: second.accountKey)

        #expect(try Data(contentsOf: try fixture.store.authFileURL(for: first.accountKey)) == firstNewAuthData)
        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == secondAuthData)
    }

    @Test
    func testAddAccountPreservesExternallyRefreshedActiveSnapshotBeforeSwitching() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let firstOldAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "access-first-old",
            refreshToken: "refresh-first-old",
            lastRefresh: "2026-01-01T00:00:00Z"
        )
        let firstNewAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "access-first-new",
            refreshToken: "refresh-first-new",
            lastRefresh: "2026-01-02T00:00:00Z"
        )
        let secondAuthData = try makeAuthData(
            email: "second@example.com",
            userID: "user-2",
            accountID: "account-2",
            planType: "pro",
            accessToken: "access-second",
            refreshToken: "refresh-second",
            lastRefresh: "2026-01-01T12:00:00Z"
        )

        let first = try fixture.store.addAccount(authData: firstOldAuthData)
        try firstNewAuthData.write(to: fixture.store.activeAuthFileURL, options: .atomic)

        _ = try fixture.store.addAccount(authData: secondAuthData)

        #expect(try Data(contentsOf: try fixture.store.authFileURL(for: first.accountKey)) == firstNewAuthData)
        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == secondAuthData)
    }

    @Test
    func testAddAccountRefusesToOverwriteUnmanagedCurrentAuth() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let unmanagedAuth = try makeAuthData(
            email: "outside@example.com",
            userID: "outside-user",
            accountID: "outside-account",
            planType: "plus"
        )
        try FileManager.default.createDirectory(
            at: fixture.store.activeAuthFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try unmanagedAuth.write(to: fixture.store.activeAuthFileURL)

        do {
            _ = try fixture.store.addAccount(authData: makeAuthData(
                email: "managed@example.com",
                userID: "managed-user",
                accountID: "managed-account",
                planType: "pro"
            ))
            #expect(Bool(false), "Expected activeAuthCannotBeReplaced")
        } catch CodexUsageAccountStoreError.activeAuthCannotBeReplaced {
        } catch {
            #expect(Bool(false), "Expected activeAuthCannotBeReplaced, got \(error)")
        }

        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == unmanagedAuth)
        #expect(try fixture.store.loadSnapshot().accounts.isEmpty)
    }

    @Test
    func testActivateAccountRefusesToOverwriteUnreadableCurrentAuth() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.addAccount(authData: makeAuthData(
            email: "first@example.com",
            userID: "first-user",
            accountID: "first-account",
            planType: "plus"
        ))
        _ = try fixture.store.addAccount(authData: makeAuthData(
            email: "second@example.com",
            userID: "second-user",
            accountID: "second-account",
            planType: "pro"
        ))
        let invalidActiveAuth = Data("not valid auth json".utf8)
        try invalidActiveAuth.write(to: fixture.store.activeAuthFileURL)
        let registryBefore = try Data(contentsOf: fixture.store.registryFileURL)
        let firstSnapshotBefore = try Data(
            contentsOf: fixture.store.authFileURL(for: first.accountKey)
        )

        do {
            try fixture.store.activateAccount(accountKey: first.accountKey)
            #expect(Bool(false), "Expected activeAuthCannotBeReplaced")
        } catch CodexUsageAccountStoreError.activeAuthCannotBeReplaced {
        } catch {
            #expect(Bool(false), "Expected activeAuthCannotBeReplaced, got \(error)")
        }

        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == invalidActiveAuth)
        #expect(try Data(contentsOf: fixture.store.registryFileURL) == registryBefore)
        #expect(
            try Data(contentsOf: fixture.store.authFileURL(for: first.accountKey))
                == firstSnapshotBefore
        )
    }

    @Test
    func testActivatingAlreadyCurrentAccountCapturesLatestActiveCredentials() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let oldAuth = try makeAuthData(
            email: "first@example.com",
            userID: "first-user",
            accountID: "first-account",
            planType: "plus",
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let latestAuth = try makeAuthData(
            email: "first@example.com",
            userID: "first-user",
            accountID: "first-account",
            planType: "plus",
            accessToken: "latest-access",
            refreshToken: "latest-refresh"
        )
        let account = try fixture.store.addAccount(authData: oldAuth)
        try latestAuth.write(to: fixture.store.activeAuthFileURL)

        try fixture.store.activateAccount(accountKey: account.accountKey)

        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == latestAuth)
        #expect(
            try Data(contentsOf: fixture.store.authFileURL(for: account.accountKey))
                == latestAuth
        )
    }

    @Test
    func testReauthenticatingCurrentAccountKeepsNewLoginCredentials() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let oldAuth = try makeAuthData(
            email: "first@example.com",
            userID: "first-user",
            accountID: "first-account",
            planType: "plus",
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let newAuth = try makeAuthData(
            email: "first@example.com",
            userID: "first-user",
            accountID: "first-account",
            planType: "plus",
            accessToken: "new-access",
            refreshToken: "new-refresh"
        )
        let account = try fixture.store.addAccount(authData: oldAuth)

        _ = try fixture.store.addAccount(authData: newAuth)

        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == newAuth)
        #expect(
            try Data(contentsOf: fixture.store.authFileURL(for: account.accountKey))
                == newAuth
        )
    }

    @Test
    func testAddAccountRejectsCaseInsensitiveSnapshotFilenameCollision() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.addAccount(authData: makeAuthData(
            email: "first@example.com",
            userID: "aaa",
            accountID: "a",
            planType: "plus"
        ))
        let activeBefore = try Data(contentsOf: fixture.store.activeAuthFileURL)
        let registryBefore = try Data(contentsOf: fixture.store.registryFileURL)

        do {
            _ = try fixture.store.addAccount(authData: makeAuthData(
                email: "second@example.com",
                userID: "aaG",
                accountID: "a",
                planType: "pro"
            ))
            #expect(Bool(false), "Expected filename collision rejection")
        } catch CodexUsageAccountStoreError.archiveInvalid {
        } catch {
            #expect(Bool(false), "Expected archiveInvalid, got \(error)")
        }

        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == activeBefore)
        #expect(try Data(contentsOf: fixture.store.registryFileURL) == registryBefore)
        #expect(try fixture.store.loadSnapshot().accounts.map(\.accountKey) == [first.accountKey])
    }

    @Test
    func testAddAccountRejectsAmbiguousIdentityDelimiter() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }

        do {
            _ = try fixture.store.addAccount(authData: makeAuthData(
                email: "ambiguous@example.com",
                userID: "a",
                accountID: "b::c",
                planType: "plus"
            ))
            #expect(Bool(false), "Expected missingAccountInfo")
        } catch CodexOAuthUsageError.missingAccountInfo {
        } catch {
            #expect(Bool(false), "Expected missingAccountInfo, got \(error)")
        }

        #expect(try fixture.store.loadSnapshot().accounts.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.store.activeAuthFileURL.path
        ))
    }

    @Test
    func testStartupMaintenancePreservesLegacyAuthBackupForExplicitReview() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.addAccount(authData: makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus"
        ))
        let backupURL = fixture.store.accountsDirectoryURL
            .appendingPathComponent("auth.json.bak")
        try Data("legacy-oauth-credentials".utf8).write(
            to: backupURL,
            options: .atomic
        )
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        try fixture.store.performStartupMaintenance()

        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(try Data(contentsOf: backupURL) == Data("legacy-oauth-credentials".utf8))
    }

    @Test
    func testStartupMaintenanceRemovesAbandonedImportStagingDirectory() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.store.applicationSupportURL,
            withIntermediateDirectories: true
        )
        let stagingURL = fixture.store.applicationSupportURL.appendingPathComponent(
            ".accounts-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false
        )
        try Data("stale-oauth-credentials".utf8).write(
            to: stagingURL.appendingPathComponent("account.auth.json")
        )

        try fixture.store.performStartupMaintenance()

        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test
    func testActivateAccountRejectsSnapshotBelongingToDifferentAccount() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.addAccount(authData: makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus"
        ))
        let secondAuthData = try makeAuthData(
            email: "second@example.com",
            userID: "user-2",
            accountID: "account-2",
            planType: "pro"
        )
        let second = try fixture.store.addAccount(authData: secondAuthData)
        let mismatchedAuthData = try makeAuthData(
            email: "third@example.com",
            userID: "user-3",
            accountID: "account-3",
            planType: "team"
        )
        try mismatchedAuthData.write(
            to: fixture.store.authFileURL(for: first.accountKey),
            options: .atomic
        )
        let registryBeforeActivation = try Data(contentsOf: fixture.store.registryFileURL)

        do {
            try fixture.store.activateAccount(accountKey: first.accountKey)
            #expect(Bool(false), "Expected authSnapshotAccountMismatch")
        } catch CodexUsageAccountStoreError.authSnapshotAccountMismatch(
            let expected,
            let actual
        ) {
            #expect(expected == first.accountKey)
            #expect(actual == "user-3::account-3")
        } catch {
            #expect(Bool(false), "Expected authSnapshotAccountMismatch, got \(error)")
        }

        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == secondAuthData)
        #expect(try Data(contentsOf: fixture.store.registryFileURL) == registryBeforeActivation)
        #expect(try fixture.store.loadSnapshot().activeAccountKey == second.accountKey)
    }

    @Test
    func testRemoveAccountRejectsActiveAccountBeforeDeletingFiles() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.addAccount(authData: makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus"
        ))
        let second = try fixture.store.addAccount(authData: makeAuthData(
            email: "second@example.com",
            userID: "user-2",
            accountID: "account-2",
            planType: "pro"
        ))

        #expect(try fixture.store.loadSnapshot().activeAccountKey == second.accountKey)
        do {
            _ = try fixture.store.removeAccount(accountKey: second.accountKey)
            #expect(Bool(false), "Expected activeAccountCannotBeRemoved")
        } catch CodexUsageAccountStoreError.activeAccountCannotBeRemoved {
        } catch {
            #expect(Bool(false), "Expected activeAccountCannotBeRemoved, got \(error)")
        }
        #expect(FileManager.default.fileExists(
            atPath: try fixture.store.authFileURL(for: second.accountKey).path
        ))

        let snapshot = try fixture.store.removeAccount(accountKey: first.accountKey)
        #expect(snapshot.accounts.map(\.accountKey) == [second.accountKey])
        #expect(!FileManager.default.fileExists(
            atPath: try fixture.store.authFileURL(for: first.accountKey).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: try fixture.store.authFileURL(for: second.accountKey).path
        ))
    }

    @Test
    func testRemoveAccountReconcilesStaleRegistryWithActualAuthBeforeRemoval() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let firstAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus"
        )
        let secondAuthData = try makeAuthData(
            email: "second@example.com",
            userID: "user-2",
            accountID: "account-2",
            planType: "pro"
        )
        let first = try fixture.store.addAccount(authData: firstAuthData)
        _ = try fixture.store.addAccount(authData: secondAuthData)
        try firstAuthData.write(to: fixture.store.activeAuthFileURL, options: .atomic)

        do {
            _ = try fixture.store.removeAccount(accountKey: first.accountKey)
            #expect(Bool(false), "Expected activeAccountCannotBeRemoved")
        } catch CodexUsageAccountStoreError.activeAccountCannotBeRemoved {
        } catch {
            #expect(Bool(false), "Expected activeAccountCannotBeRemoved, got \(error)")
        }

        #expect(FileManager.default.fileExists(
            atPath: try fixture.store.authFileURL(for: first.accountKey).path
        ))

        let snapshot = try fixture.store.removeAccount(accountKey: "user-2::account-2")
        #expect(snapshot.activeAccountKey == first.accountKey)
        #expect(snapshot.accounts.map(\.accountKey) == [first.accountKey])
        #expect(snapshot.accounts[0].isActive)
        #expect(!FileManager.default.fileExists(
            atPath: try fixture.store.authFileURL(for: "user-2::account-2").path
        ))
    }

    @Test
    func testLoadSnapshotDoesNotInferActiveAccountWhenRegistryHasNoActiveKey() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let accountsDirectory = fixture.store.accountsDirectoryURL
        try FileManager.default.createDirectory(
            at: accountsDirectory,
            withIntermediateDirectories: true
        )
        let registry: [String: Any] = [
            "schema_version": 1,
            "accounts": [
                [
                    "account_key": "user-1::account-1",
                    "chatgpt_account_id": "account-1",
                    "chatgpt_user_id": "user-1",
                    "email": "first@example.com",
                    "alias": "",
                    "plan": "plus",
                    "auth_mode": "chatgpt"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: registry, options: [.prettyPrinted])
        try data.write(to: fixture.store.registryFileURL, options: .atomic)

        let snapshot = try fixture.store.loadSnapshot()

        #expect(snapshot.activeAccountKey == nil)
        #expect(snapshot.accounts.count == 1)
        #expect(snapshot.accounts[0].isActive == false)
    }

    @Test
    func testRemoveAccountFailsWhenAuthSnapshotIsMissing() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        try writeRegistry(
            store: fixture.store,
            activeAccountKey: "user-1::account-1",
            accounts: [
                registryAccount(
                    accountKey: "user-1::account-1",
                    accountID: "account-1",
                    userID: "user-1",
                    email: "first@example.com"
                ),
                registryAccount(
                    accountKey: "user-2::account-2",
                    accountID: "account-2",
                    userID: "user-2",
                    email: "second@example.com"
                )
            ]
        )

        do {
            _ = try fixture.store.removeAccount(accountKey: "user-2::account-2")
            #expect(Bool(false), "Expected authSnapshotNotFound")
        } catch CodexUsageAccountStoreError.authSnapshotNotFound {
        } catch {
            #expect(Bool(false), "Expected authSnapshotNotFound, got \(error)")
        }

        let snapshot = try fixture.store.loadSnapshot()
        #expect(snapshot.accounts.map(\.accountKey) == ["user-1::account-1", "user-2::account-2"])
    }

    @Test
    func testArchiveExportImportRoundTripReplacesManagedAccountsWithoutChangingActiveAuth() throws {
        let source = try makeStoreFixture()
        defer { source.cleanup() }
        let firstAuthData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "access-first",
            refreshToken: "refresh-first"
        )
        let secondAuthData = try makeAuthData(
            email: "second@example.com",
            userID: "user-2",
            accountID: "account-2",
            planType: "pro",
            accessToken: "access-second",
            refreshToken: "refresh-second"
        )
        let first = try source.store.addAccount(authData: firstAuthData)
        let second = try source.store.addAccount(authData: secondAuthData)
        try source.store.activateAccount(accountKey: first.accountKey)
        let archive = try source.store.exportArchive()

        let destination = try makeStoreFixture()
        defer { destination.cleanup() }
        let replaced = try destination.store.addAccount(authData: makeAuthData(
            email: "replaced@example.com",
            userID: "user-replaced",
            accountID: "account-replaced",
            planType: "free",
            accessToken: "destination-active",
            refreshToken: "destination-refresh"
        ))
        let activeAuthBeforeImport = try Data(contentsOf: destination.store.activeAuthFileURL)
        let baseline = try destination.store.loadImportBaseline()

        let imported = try destination.store.importArchive(
            archive,
            replacingStorageRevision: baseline.storageRevision
        )

        #expect(imported.activeAccountKey == nil)
        #expect(Set(imported.accounts.map(\.accountKey)) == Set([first.accountKey, second.accountKey]))
        #expect(
            try Data(contentsOf: destination.store.authFileURL(for: first.accountKey))
                == firstAuthData
        )
        #expect(
            try Data(contentsOf: destination.store.authFileURL(for: second.accountKey))
                == secondAuthData
        )
        #expect(!FileManager.default.fileExists(
            atPath: try destination.store.authFileURL(for: replaced.accountKey).path
        ))
        #expect(try Data(contentsOf: destination.store.activeAuthFileURL) == activeAuthBeforeImport)
    }

    @Test
    func testArchiveImportPreservesLegacyAuthBackupWithOwnerOnlyPermissions() throws {
        let source = try makeStoreFixture()
        defer { source.cleanup() }
        _ = try source.store.addAccount(authData: makeAuthData(
            email: "source@example.com",
            userID: "source-user",
            accountID: "source-account",
            planType: "plus"
        ))
        let archive = try source.store.exportArchive()

        let destination = try makeStoreFixture()
        defer { destination.cleanup() }
        _ = try destination.store.addAccount(authData: makeAuthData(
            email: "destination@example.com",
            userID: "destination-user",
            accountID: "destination-account",
            planType: "pro"
        ))
        let legacyBackup = Data("unique-legacy-oauth-backup".utf8)
        let legacyBackupURL = destination.store.accountsDirectoryURL
            .appendingPathComponent("auth.json.bak")
        try legacyBackup.write(to: legacyBackupURL)
        let baseline = try destination.store.loadImportBaseline()

        _ = try destination.store.importArchive(
            archive,
            replacingStorageRevision: baseline.storageRevision
        )

        let attributes = try FileManager.default.attributesOfItem(
            atPath: legacyBackupURL.path
        )
        #expect(try Data(contentsOf: legacyBackupURL) == legacyBackup)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func testArchiveExportUsesLatestCurrentAuthWithoutMutatingStoredSnapshot() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let storedAuthData = try makeAuthData(
            email: "current@example.com",
            userID: "current-user",
            accountID: "current-account",
            planType: "plus",
            accessToken: "stored-access",
            refreshToken: "stored-refresh"
        )
        let currentAuthData = try makeAuthData(
            email: "current@example.com",
            userID: "current-user",
            accountID: "current-account",
            planType: "plus",
            accessToken: "latest-access",
            refreshToken: "latest-refresh"
        )
        let account = try fixture.store.addAccount(authData: storedAuthData)
        try currentAuthData.write(
            to: fixture.store.activeAuthFileURL,
            options: .atomic
        )

        let archive = try fixture.store.exportArchive()
        let exported = try #require(
            archive.authSnapshots.first { $0.accountKey == account.accountKey }
        )

        #expect(exported.authData == currentAuthData)
        #expect(
            try Data(contentsOf: fixture.store.authFileURL(for: account.accountKey))
                == storedAuthData
        )
    }

    @Test
    func testManagedCredentialRefreshCommitUsesExpectedAuthData() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.addAccount(authData: makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "old-access",
            refreshToken: "old-refresh"
        ))
        _ = try fixture.store.addAccount(authData: makeAuthData(
            email: "second@example.com",
            userID: "user-2",
            accountID: "account-2",
            planType: "pro"
        ))
        let snapshot = try fixture.store.loadManagedCredentialsForRefresh(
            accountKey: first.accountKey
        )
        var refreshed = snapshot.credentials
        refreshed.accessToken = "new-access"
        refreshed.refreshToken = "new-refresh"

        let committed = try fixture.store.commitRefreshedManagedCredentials(
            accountKey: first.accountKey,
            expectedAuthData: snapshot.authData,
            credentials: refreshed
        )
        let stored = try CodexOAuthCredentialsStore.load(from: committed)

        #expect(stored.accessToken == "new-access")
        #expect(stored.refreshToken == "new-refresh")
        #expect(
            try Data(contentsOf: fixture.store.authFileURL(for: first.accountKey))
                == committed
        )
    }

    @Test
    func testManagedCredentialRefreshCommitRejectsChangedSnapshot() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.addAccount(authData: makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "old-access",
            refreshToken: "old-refresh"
        ))
        _ = try fixture.store.addAccount(authData: makeAuthData(
            email: "second@example.com",
            userID: "user-2",
            accountID: "account-2",
            planType: "pro"
        ))
        let snapshot = try fixture.store.loadManagedCredentialsForRefresh(
            accountKey: first.accountKey
        )
        let replacementData = try makeAuthData(
            email: "first@example.com",
            userID: "user-1",
            accountID: "account-1",
            planType: "plus",
            accessToken: "replacement-access",
            refreshToken: "replacement-refresh"
        )
        try replacementData.write(
            to: fixture.store.authFileURL(for: first.accountKey),
            options: .atomic
        )
        var refreshed = snapshot.credentials
        refreshed.accessToken = "stale-refresh-access"

        #expect(throws: CodexUsageAccountStoreError.self) {
            _ = try fixture.store.commitRefreshedManagedCredentials(
                accountKey: first.accountKey,
                expectedAuthData: snapshot.authData,
                credentials: refreshed
            )
        }
        #expect(
            try Data(contentsOf: fixture.store.authFileURL(for: first.accountKey))
                == replacementData
        )
    }

    @Test
    func testImportRejectsWhenManagedStorageChangesAfterPreview() throws {
        let source = try makeStoreFixture()
        defer { source.cleanup() }
        _ = try source.store.addAccount(authData: makeAuthData(
            email: "source@example.com",
            userID: "source-user",
            accountID: "source-account",
            planType: "plus"
        ))
        let archive = try source.store.exportArchive()

        let destination = try makeStoreFixture()
        defer { destination.cleanup() }
        _ = try destination.store.addAccount(authData: makeAuthData(
            email: "first@example.com",
            userID: "first-user",
            accountID: "first-account",
            planType: "plus"
        ))
        let baseline = try destination.store.loadImportBaseline()
        _ = try destination.store.addAccount(authData: makeAuthData(
            email: "new@example.com",
            userID: "new-user",
            accountID: "new-account",
            planType: "pro"
        ))

        do {
            _ = try destination.store.importArchive(
                archive,
                replacingStorageRevision: baseline.storageRevision
            )
            #expect(Bool(false), "Expected storageChangedSinceImportPreview")
        } catch CodexUsageAccountStoreError.storageChangedSinceImportPreview {
        } catch {
            #expect(Bool(false), "Expected storageChangedSinceImportPreview, got \(error)")
        }
        #expect(try destination.store.loadSnapshot().accounts.count == 2)
    }

    @Test
    func testImportRejectsDuplicateAuthSnapshotsBeforeChangingStoredOrActiveAuth() throws {
        let source = try makeStoreFixture()
        defer { source.cleanup() }
        _ = try source.store.addAccount(authData: makeAuthData(
            email: "source@example.com",
            userID: "source-user",
            accountID: "source-account",
            planType: "plus"
        ))
        let exported = try source.store.exportArchive()
        let firstSnapshot = try #require(exported.authSnapshots.first)
        let duplicateArchive = CodexManagedAccountsArchive(
            schemaVersion: exported.schemaVersion,
            registryData: exported.registryData,
            authSnapshots: exported.authSnapshots + [firstSnapshot]
        )

        let destination = try makeStoreFixture()
        defer { destination.cleanup() }
        let destinationAccount = try destination.store.addAccount(authData: makeAuthData(
            email: "destination@example.com",
            userID: "destination-user",
            accountID: "destination-account",
            planType: "pro"
        ))

        try expectImportRejectedWithoutMutation(
            duplicateArchive,
            fixture: destination,
            expectedAccountKey: destinationAccount.accountKey,
            matchesExpectedError: {
                if case .archiveInvalid = $0 { return true }
                return false
            }
        )
    }

    @Test
    func testImportRejectsMismatchedAuthIdentityBeforeChangingStoredOrActiveAuth() throws {
        let source = try makeStoreFixture()
        defer { source.cleanup() }
        _ = try source.store.addAccount(authData: makeAuthData(
            email: "source@example.com",
            userID: "source-user",
            accountID: "source-account",
            planType: "plus"
        ))
        let exported = try source.store.exportArchive()
        let firstSnapshot = try #require(exported.authSnapshots.first)
        let mismatchedSnapshot = CodexManagedAuthArchive(
            accountKey: firstSnapshot.accountKey,
            authData: try makeAuthData(
                email: "different@example.com",
                userID: "different-user",
                accountID: "different-account",
                planType: "team"
            )
        )
        let mismatchedArchive = CodexManagedAccountsArchive(
            schemaVersion: exported.schemaVersion,
            registryData: exported.registryData,
            authSnapshots: [mismatchedSnapshot]
        )

        let destination = try makeStoreFixture()
        defer { destination.cleanup() }
        let destinationAccount = try destination.store.addAccount(authData: makeAuthData(
            email: "destination@example.com",
            userID: "destination-user",
            accountID: "destination-account",
            planType: "pro"
        ))

        try expectImportRejectedWithoutMutation(
            mismatchedArchive,
            fixture: destination,
            expectedAccountKey: destinationAccount.accountKey,
            matchesExpectedError: {
                if case .authSnapshotAccountMismatch = $0 { return true }
                return false
            }
        )
    }

    private func expectImportRejectedWithoutMutation(
        _ archive: CodexManagedAccountsArchive,
        fixture: StoreFixture,
        expectedAccountKey: String,
        matchesExpectedError: (CodexUsageAccountStoreError) -> Bool
    ) throws {
        let registryBeforeImport = try Data(contentsOf: fixture.store.registryFileURL)
        let activeAuthBeforeImport = try Data(contentsOf: fixture.store.activeAuthFileURL)
        let managedAuthBeforeImport = try Data(
            contentsOf: fixture.store.authFileURL(for: expectedAccountKey)
        )

        var rejection: CodexUsageAccountStoreError?
        do {
            let baseline = try fixture.store.loadImportBaseline()
            _ = try fixture.store.importArchive(
                archive,
                replacingStorageRevision: baseline.storageRevision
            )
        } catch let error as CodexUsageAccountStoreError {
            rejection = error
        } catch {
            #expect(Bool(false), "Expected account store rejection, got \(error)")
        }

        #expect(rejection.map(matchesExpectedError) == true)
        #expect(try Data(contentsOf: fixture.store.registryFileURL) == registryBeforeImport)
        #expect(try Data(contentsOf: fixture.store.activeAuthFileURL) == activeAuthBeforeImport)
        #expect(
            try Data(contentsOf: fixture.store.authFileURL(for: expectedAccountKey))
                == managedAuthBeforeImport
        )
        #expect(try fixture.store.loadSnapshot().accounts.map(\.accountKey) == [expectedAccountKey])
    }

    private func makeStoreFixture() throws -> StoreFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-usage-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CodexUsageAccountStore(
            applicationSupportURL: root.appendingPathComponent("app-support", isDirectory: true),
            codexHomeURL: root.appendingPathComponent("codex-home", isDirectory: true)
        )
        return StoreFixture(root: root, store: store)
    }

    private func makeAuthData(
        email: String,
        userID: String,
        accountID: String,
        planType: String,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        lastRefresh: String? = nil,
        includesTokenAccountID: Bool = true
    ) throws -> Data {
        let idToken = try makeJWT(payload: [
            "email": email,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_user_id": userID,
                "chatgpt_plan_type": planType
            ]
        ])
        var tokens: [String: Any] = [
            "access_token": accessToken ?? "access-\(userID)",
            "refresh_token": refreshToken ?? "refresh-\(userID)",
            "id_token": idToken
        ]
        if includesTokenAccountID {
            tokens["account_id"] = accountID
        }
        var json: [String: Any] = [
            "tokens": tokens
        ]
        if let lastRefresh {
            json["last_refresh"] = lastRefresh
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    }

    private func writeRegistry(
        store: CodexUsageAccountStore,
        activeAccountKey: String?,
        accounts: [[String: Any]]
    ) throws {
        try FileManager.default.createDirectory(
            at: store.accountsDirectoryURL,
            withIntermediateDirectories: true
        )
        var registry: [String: Any] = [
            "schema_version": 1,
            "accounts": accounts
        ]
        registry["active_account_key"] = activeAccountKey
        let data = try JSONSerialization.data(withJSONObject: registry, options: [.prettyPrinted])
        try data.write(to: store.registryFileURL, options: .atomic)
    }

    private func registryAccount(
        accountKey: String,
        accountID: String,
        userID: String,
        email: String
    ) -> [String: Any] {
        [
            "account_key": accountKey,
            "chatgpt_account_id": accountID,
            "chatgpt_user_id": userID,
            "email": email,
            "alias": "",
            "plan": "plus",
            "auth_mode": "chatgpt"
        ]
    }

    private func makeJWT(payload: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return [
            base64URLNoPadding(header),
            base64URLNoPadding(payloadData),
            "signature"
        ].joined(separator: ".")
    }

    private func base64URLNoPadding(_ value: String) -> String {
        base64URLNoPadding(Data(value.utf8))
    }

    private func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct StoreFixture {
    var root: URL
    var store: CodexUsageAccountStore

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

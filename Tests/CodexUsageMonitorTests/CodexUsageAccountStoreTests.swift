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
        planType: String
    ) throws -> Data {
        let idToken = try makeJWT(payload: [
            "email": email,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_user_id": userID,
                "chatgpt_plan_type": planType
            ]
        ])
        let json: [String: Any] = [
            "tokens": [
                "access_token": "access-\(userID)",
                "refresh_token": "refresh-\(userID)",
                "id_token": idToken,
                "account_id": accountID
            ]
        ]
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

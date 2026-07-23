import Foundation
import Testing
@testable import CodexUsageMonitor

struct CodexOAuthUsageClientTests {
    @Test
    func testAuthLoaderTrimsOAuthTokenAndAccountValues() throws {
        let data = try #require(
            """
            {
              "tokens": {
                "access_token": "  access-value  ",
                "refresh_token": "\\nrefresh-value\\t",
                "account_id": "  account-value  "
              }
            }
            """.data(using: .utf8)
        )

        let credentials = try CodexOAuthCredentialsStore.load(from: data)

        #expect(credentials.accessToken == "access-value")
        #expect(credentials.refreshToken == "refresh-value")
        #expect(credentials.accountID == "account-value")
    }

    @Test
    func testAuthLoaderRejectsWhitespaceOnlyAccessToken() throws {
        let data = try #require(
            #"{"tokens":{"access_token":"   ","refresh_token":"refresh"}}"#
                .data(using: .utf8)
        )

        do {
            _ = try CodexOAuthCredentialsStore.load(from: data)
            #expect(Bool(false), "Expected missingTokens")
        } catch CodexOAuthUsageError.missingTokens {
        } catch {
            #expect(Bool(false), "Expected missingTokens, got \(error)")
        }
    }

    @Test
    func testAuthFileLoaderRejectsFilesLargerThanTwoMiB() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-oauth-size-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let authURL = root.appendingPathComponent("auth.json")
        try Data(count: 2 * 1_024 * 1_024 + 1).write(to: authURL)

        do {
            _ = try CodexOAuthCredentialsStore.load(from: authURL)
            #expect(Bool(false), "Expected credentialsTooLarge")
        } catch CodexOAuthUsageError.credentialsTooLarge {
        } catch {
            #expect(Bool(false), "Expected credentialsTooLarge, got \(error)")
        }
    }

    @Test
    func testRefreshResponsePreservesOmittedOptionalTokens() throws {
        let previous = CodexOAuthCredentials(
            accessToken: "access-old",
            refreshToken: "refresh-old",
            idToken: "id-old",
            accountID: "account-1",
            lastRefresh: Date(timeIntervalSince1970: 1)
        )
        let data = try #require(#"{"access_token":"access-new"}"#.data(using: .utf8))

        let refreshed = try CodexOAuthTokenResponseParser.parse(
            data: data,
            previous: previous
        )

        #expect(refreshed.accessToken == "access-new")
        #expect(refreshed.refreshToken == "refresh-old")
        #expect(refreshed.idToken == "id-old")
        #expect(refreshed.accountID == "account-1")
        #expect(refreshed.lastRefresh != nil)
    }

    @Test
    func testRefreshResponseTrimsReturnedTokens() throws {
        let previous = CodexOAuthCredentials(
            accessToken: "access-old",
            refreshToken: "refresh-old",
            idToken: "id-old",
            accountID: "account-1",
            lastRefresh: nil
        )
        let data = try #require(
            """
            {
              "access_token": "  access-new  ",
              "refresh_token": "\\nrefresh-new\\t",
              "id_token": " id-new "
            }
            """.data(using: .utf8)
        )

        let refreshed = try CodexOAuthTokenResponseParser.parse(
            data: data,
            previous: previous
        )

        #expect(refreshed.accessToken == "access-new")
        #expect(refreshed.refreshToken == "refresh-new")
        #expect(refreshed.idToken == "id-new")
    }

    @Test
    func testRefreshResponseRejectsMissingOrEmptyTokens() throws {
        let previous = CodexOAuthCredentials(
            accessToken: "access-old",
            refreshToken: "refresh-old",
            idToken: "id-old",
            accountID: "account-1",
            lastRefresh: nil
        )
        let invalidResponses = [
            #"{broken"#,
            #"[]"#,
            #"{}"#,
            #"{"access_token":""}"#,
            #"{"access_token":"   "}"#,
            #"{"access_token":"access-new","refresh_token":""}"#,
            #"{"access_token":"access-new","id_token":"   "}"#
        ]

        for response in invalidResponses {
            let data = try #require(response.data(using: .utf8))
            do {
                _ = try CodexOAuthTokenResponseParser.parse(
                    data: data,
                    previous: previous
                )
                #expect(Bool(false), "Expected token response to be rejected: \(response)")
            } catch CodexOAuthUsageError.decodeFailed(_) {
            } catch {
                #expect(Bool(false), "Expected decodeFailed, got \(error)")
            }
        }
    }

    @Test
    func testUsageWindowDecoderRejectsNonFiniteAndOutOfRangeNumbers() throws {
        let data = try #require(
            #"{"used_percent":"NaN","reset_at":1e100,"limit_window_seconds":1e100}"#
                .data(using: .utf8)
        )

        let window = try JSONDecoder().decode(
            CodexOAuthUsageResponse.WindowSnapshot.self,
            from: data
        )

        #expect(window.usedPercent == nil)
        #expect(window.resetAt == nil)
        #expect(window.limitWindowSeconds == nil)
    }

    @Test
    func testUsageSnapshotAcceptsWindowWithoutResetTime() throws {
        let data = try #require(
            """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "limit_window_seconds": 18000
                }
              }
            }
            """.data(using: .utf8)
        )
        let response = try JSONDecoder().decode(CodexOAuthUsageResponse.self, from: data)
        let credentials = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "",
            idToken: nil,
            accountID: nil,
            lastRefresh: nil
        )

        let snapshot = try CodexOAuthUsageClient.makeSnapshot(
            response: response,
            credentials: credentials,
            managedAccount: nil
        )

        #expect(snapshot.sessionWindow?.usedPercent == 25)
        #expect(snapshot.sessionWindow?.resetsAt == nil)
    }
}

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

    @Test
    func testResetCreditsUseAuthoritativeCountAndOnlyFutureAvailableDetails() throws {
        let data = try #require(
            """
            {
              "available_count": 3,
              "credits": [
                {
                  "status": "available",
                  "expires_at": "2024-01-01T00:00:00.500Z"
                },
                {
                  "status": "available",
                  "expires_at": null
                },
                {
                  "status": "consumed",
                  "expires_at": "2025-01-01T00:00:00Z"
                },
                {
                  "status": "available",
                  "expires_at": "2023-01-01T00:00:00Z"
                },
                {
                  "status": "available",
                  "expires_at": "2500-01-01T00:00:00Z"
                }
              ]
            }
            """.data(using: .utf8)
        )

        let response = try JSONDecoder().decode(
            CodexOAuthResetCreditsResponse.self,
            from: data
        )
        let summary = response.summary(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(summary.availableCount == 3)
        #expect(summary.reportedAvailableCount == 2)
        #expect(summary.expirations.count == 1)
        #expect(summary.nearestExpiration?.timeIntervalSince1970 == 1_704_067_200.5)
        #expect(!summary.hasCompleteDetails)
    }

    @Test
    func testResetCreditsRejectInvalidAuthoritativeCounts() throws {
        let invalidResponses = [
            #"{"available_count":-1,"credits":[]}"#,
            #"{"available_count":10001,"credits":[]}"#,
            #"{"available_count":"NaN","credits":[]}"#
        ]

        for response in invalidResponses {
            let data = try #require(response.data(using: .utf8))
            do {
                _ = try JSONDecoder().decode(
                    CodexOAuthResetCreditsResponse.self,
                    from: data
                )
                #expect(Bool(false), "Expected invalid count to fail: \(response)")
            } catch DecodingError.dataCorrupted(_) {
            } catch {
                #expect(Bool(false), "Expected dataCorrupted, got \(error)")
            }
        }
    }

    @Test
    func testResetCreditsRequestIsReadOnlyAndAccountScoped() throws {
        let credentials = CodexOAuthCredentials(
            accessToken: "secret-access",
            refreshToken: "",
            idToken: nil,
            accountID: "account-123",
            lastRefresh: nil
        )

        let request = try CodexOAuthUsageClient.resetCreditsRequest(
            credentials: credentials,
            timeout: 4
        )

        #expect(
            request.url?.absoluteString
                == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
        )
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 4)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-access")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-123")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
        #expect(request.value(forHTTPHeaderField: "originator") == "Codex Desktop")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.httpBody == nil)
    }

    @Test
    func testBoundedResponseRejectsUnknownLengthBodyDuringStreaming() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try #require(
            URL(string: "https://example.test/reset-credits")
        )
        let request = URLRequest(url: url)

        do {
            _ = try await CodexOAuthUsageClient.boundedData(
                for: request,
                using: session,
                maximumByteCount: 32
            )
            #expect(Bool(false), "Expected the streamed response to exceed its limit.")
        } catch CodexOAuthUsageError.decodeFailed(let message) {
            #expect(message.contains("32-byte limit"))
        } catch {
            #expect(Bool(false), "Expected decodeFailed, got \(error)")
        }
    }

    @Test
    func testResetCreditsHTTPFailureDoesNotDiscardQuotaSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-oauth-partial-response-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let authURL = root.appendingPathComponent("auth.json")
        let authData = try #require(
            """
            {
              "tokens": {
                "access_token": "access-value",
                "account_id": "account-123"
              }
            }
            """.data(using: .utf8)
        )
        try authData.write(to: authURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageSucceedsResetFailsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let snapshot = try await CodexOAuthUsageClient(
            timeout: 1,
            session: session
        ).loadSnapshotReadOnly(authFileURL: authURL)

        #expect(snapshot.sessionWindow?.usedPercent == 25)
        #expect(snapshot.weeklyWindow?.usedPercent == 40)
        #expect(snapshot.resetCredits == nil)
    }
}

private final class OversizedStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(repeating: 0x61, count: 32)
        )
        client?.urlProtocol(self, didLoad: Data([0x62]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UsageSucceedsResetFailsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }

        let statusCode: Int
        let data: Data
        switch url.path {
        case "/backend-api/wham/usage":
            statusCode = 200
            data = Data(
                """
                {
                  "plan_type": "plus",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 25,
                      "reset_at": 1900000000,
                      "limit_window_seconds": 18000
                    },
                    "secondary_window": {
                      "used_percent": 40,
                      "reset_at": 1900000000,
                      "limit_window_seconds": 604800
                    }
                  }
                }
                """.utf8
            )
        case "/backend-api/wham/rate-limit-reset-credits":
            statusCode = 503
            data = Data(#"{"error":"temporarily unavailable"}"#.utf8)
        default:
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

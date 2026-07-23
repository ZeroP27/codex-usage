import Foundation
import Testing
@testable import CodexUsageMonitor

struct CodexAppServerClientTests {
    @Test
    func testChromeIncognitoOpenArgumentsUseNewInstanceBundleIDAndRawURLArgument() throws {
        let url = try #require(URL(string: "https://auth.openai.com/login?state=a%20b&next=https%3A%2F%2Fchatgpt.com"))

        let arguments = CodexAppServerClient.chromeIncognitoOpenArguments(for: url)

        #expect(arguments == [
            "-n",
            "-b",
            "com.google.Chrome",
            "--args",
            "--incognito",
            url.absoluteString
        ])
    }

    @Test
    func testBareExecutableNameDoesNotUseCodexAppCandidates() {
        let candidates = CodexExecutableResolver.candidates(named: "my-codex")

        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { $0.lastPathComponent == "my-codex" })
        #expect(!candidates.contains { $0.path.contains("/Codex.app/") })
    }

    @Test
    func testRateLimitDecoderRejectsNonFiniteAndOutOfRangeNumbers() throws {
        let data = try #require(
            #"{"usedPercent":"NaN","windowDurationMins":1e100,"resetsAt":"Infinity"}"#
                .data(using: .utf8)
        )

        let payload = try JSONDecoder().decode(RateLimitWindowPayload.self, from: data)

        #expect(payload.usedPercent == nil)
        #expect(payload.windowDurationMins == nil)
        #expect(payload.resetsAt == nil)
    }

    @Test
    func testRPCRequestFailsQuicklyWhenOutputReachesEOF() throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let connection = AppServerRPCConnection(
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading,
            error: errorPipe.fileHandleForReading
        )
        defer { connection.close() }
        try outputPipe.fileHandleForWriting.close()

        let startedAt = Date()
        do {
            let _: TestRPCResult = try connection.request(
                id: 1,
                method: "test",
                params: nil,
                timeout: 5
            )
            #expect(Bool(false), "Expected EOF to fail the request")
        } catch CodexAppServerError.requestFailed(let message) {
            #expect(message.contains("closed its output"))
        } catch {
            #expect(Bool(false), "Expected requestFailed, got \(error)")
        }
        #expect(Date().timeIntervalSince(startedAt) < 2)
    }
}

private struct TestRPCResult: Decodable {}

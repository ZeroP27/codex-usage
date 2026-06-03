import Foundation
import Testing
@testable import CodexUsageMonitor

struct CodexAppServerClientTests {
    @Test
    func testChromeIncognitoOpenArgumentsUseBundleIDAndRawURLArgument() throws {
        let url = try #require(URL(string: "https://auth.openai.com/login?state=a%20b&next=https%3A%2F%2Fchatgpt.com"))

        let arguments = CodexAppServerClient.chromeIncognitoOpenArguments(for: url)

        #expect(arguments == [
            "-b",
            "com.google.Chrome",
            "--args",
            "--incognito",
            url.absoluteString
        ])
    }
}

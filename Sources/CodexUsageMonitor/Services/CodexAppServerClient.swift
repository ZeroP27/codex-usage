import AppKit
import Foundation
import Darwin
import OSLog

struct CodexAppServerClient {
    var executablePath: String
    var timeout: TimeInterval = 15
    var loginTimeout: TimeInterval = 300
    private static let clientVersion = "0.3.1"
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "AppServer"
    )

    func loadSnapshot() throws -> UsageSnapshot {
        let executableURL = try CodexExecutableResolver.resolve(executablePath)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = Self.processEnvironment(for: executableURL)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        let rpc = AppServerRPCConnection(
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading,
            error: errorPipe.fileHandleForReading
        )

        defer {
            rpc.close()
            Self.stop(process)
        }

        let _: EmptyRPCResult = try rpc.request(
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_usage_monitor",
                    "title": "Codex Usage",
                    "version": Self.clientVersion
                ]
            ],
            timeout: timeout
        )
        try rpc.notify(method: "initialized", params: [:])

        let account: AccountReadResult = try rpc.request(
            id: 2,
            method: "account/read",
            params: ["refreshToken": false],
            timeout: timeout
        )

        let rateLimits: RateLimitsReadResult = try rpc.request(
            id: 3,
            method: "account/rateLimits/read",
            params: nil,
            timeout: timeout
        )

        return try Self.makeSnapshot(
            account: account.account,
            rateLimits: rateLimits,
            sourceDescription: CodexUsageDataSource.cliRPC.title
        )
    }

    func loginChatGPTAuthData() throws -> Data {
        let executableURL = try CodexExecutableResolver.resolve(executablePath)
        let tempRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-usage-login-\(UUID().uuidString)",
            isDirectory: true
        )
        let tempCodexHomeURL = tempRootURL.appendingPathComponent("codex-home", isDirectory: true)

        try FileManager.default.createDirectory(
            at: tempCodexHomeURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: tempRootURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: tempCodexHomeURL.path
        )
        try "cli_auth_credentials_store = \"file\"\n".write(
            to: tempCodexHomeURL.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        Self.logger.info("chatgpt login prepared executable=\(executableURL.path, privacy: .private) temp_codex_home=\(tempCodexHomeURL.path, privacy: .private)")

        defer {
            do {
                try FileManager.default.removeItem(at: tempRootURL)
            } catch {
                Self.logger.error("failed to remove temporary login directory error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            }
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = Self.processEnvironment(
            for: executableURL,
            codexHomeURL: tempCodexHomeURL
        )

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            Self.logger.info("chatgpt login app-server started pid=\(process.processIdentifier, privacy: .public)")
        } catch {
            Self.logger.error("chatgpt login app-server launch failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        let rpc = AppServerRPCConnection(
            input: inputPipe.fileHandleForWriting,
            output: outputPipe.fileHandleForReading,
            error: errorPipe.fileHandleForReading
        )

        defer {
            rpc.close()
            Self.stop(process)
        }

        let _: EmptyRPCResult = try rpc.request(
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_usage_monitor",
                    "title": "Codex Usage",
                    "version": Self.clientVersion
                ]
            ],
            timeout: timeout
        )
        try rpc.notify(method: "initialized", params: [:])

        let login: AccountLoginStartResult = try rpc.request(
            id: 2,
            method: "account/login/start",
            params: ["type": "chatgpt"],
            timeout: timeout
        )
        Self.logger.info("chatgpt login start returned login_id_present=\((login.loginId?.isEmpty == false), privacy: .public) auth_url_host=\(URL(string: login.authUrl ?? "")?.host ?? "missing", privacy: .public)")

        guard let loginID = login.loginId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !loginID.isEmpty
        else {
            throw CodexAppServerError.loginFailed("codex app-server did not return a login id.")
        }

        guard let authURLString = login.authUrl,
              let authURL = URL(string: authURLString)
        else {
            throw CodexAppServerError.loginFailed("codex app-server did not return a browser login URL.")
        }

        guard Self.isAllowedAuthenticationURL(authURL) else {
            Self.logger.error("chatgpt login rejected unexpected auth_url_host=\(authURL.host ?? "missing", privacy: .public)")
            throw CodexAppServerError.loginFailed("codex app-server returned an unexpected login URL host.")
        }

        guard Self.openAuthenticationURL(authURL) else {
            Self.logger.error("chatgpt login failed to open auth_url_host=\(authURL.host ?? "missing", privacy: .public)")
            throw CodexAppServerError.loginFailed("Could not open the ChatGPT login URL.")
        }
        Self.logger.info("chatgpt login opened auth_url_host=\(authURL.host ?? "missing", privacy: .public)")

        let completed = try rpc.waitForNotification(
            method: "account/login/completed",
            loginID: loginID,
            timeout: loginTimeout
        )
        let params = completed["params"] as? [String: Any]
        let success = params?["success"] as? Bool ?? false
        Self.logger.info("chatgpt login completed notification success=\(success, privacy: .public)")
        guard success else {
            let message = params?["error"] as? String ?? "ChatGPT login did not complete."
            throw CodexAppServerError.loginFailed(message)
        }

        let authFileURL = tempCodexHomeURL.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            Self.logger.error("chatgpt login completed without auth file path=\(authFileURL.path, privacy: .private)")
            throw CodexAppServerError.authFileMissing(authFileURL.path)
        }
        Self.logger.info("chatgpt login auth file ready path=\(authFileURL.path, privacy: .private)")

        return try Data(contentsOf: authFileURL)
    }

    private static func processEnvironment(for executableURL: URL, codexHomeURL: URL? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallbackPath = [
            executableURL.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")

        if let path = environment["PATH"], !path.isEmpty {
            environment["PATH"] = path + ":" + fallbackPath
        } else {
            environment["PATH"] = fallbackPath
        }
        if let codexHomeURL {
            environment["CODEX_HOME"] = codexHomeURL.path
        }
        return environment
    }

    private static func openAuthenticationURL(_ url: URL) -> Bool {
        if Thread.isMainThread {
            return NSWorkspace.shared.open(url)
        }

        var opened = false
        DispatchQueue.main.sync {
            opened = NSWorkspace.shared.open(url)
        }
        return opened
    }

    private static func isAllowedAuthenticationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }

        return host == "openai.com"
            || host.hasSuffix(".openai.com")
            || host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }

        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private static func makeSnapshot(
        account: AccountPayload?,
        rateLimits: RateLimitsReadResult,
        sourceDescription: String) throws -> UsageSnapshot
    {
        let selectedBucket = rateLimits.rateLimitsByLimitId?["codex"]
            ?? rateLimits.rateLimits

        guard let selectedBucket else {
            throw CodexAppServerError.missingRateLimitData
        }

        let windows = Self.windows(from: selectedBucket)
        guard !windows.isEmpty else {
            throw CodexAppServerError.missingRateLimitData
        }

        let session = windows.first {
            $0.windowDurationMins == CodexUsageConstants.sessionWindowMinutes
        }
        let weekly = windows.first {
            $0.windowDurationMins == CodexUsageConstants.weeklyWindowMinutes
        }
        guard session != nil || weekly != nil else {
            throw CodexAppServerError.missingRateLimitData
        }

        let accountSnapshot = account.map {
            CodexAccount(type: $0.type, email: $0.email, planType: $0.planType)
        }

        return UsageSnapshot(
            account: accountSnapshot,
            sessionWindow: session,
            weeklyWindow: weekly,
            updatedAt: Date(),
            sourceDescription: sourceDescription
        )
    }

    private static func windows(from snapshot: RateLimitSnapshot) -> [QuotaWindow] {
        [
            ("primary", snapshot.primary),
            ("secondary", snapshot.secondary)
        ].compactMap { role, window in
            guard let window else { return nil }
            guard let usedPercent = window.usedPercent else { return nil }
            guard let duration = window.windowDurationMins else { return nil }

            let limitID = snapshot.limitId ?? "codex"
            let resetDate = window.resetsAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }

            return QuotaWindow(
                id: "\(limitID)-\(role)-\(duration)",
                usedPercent: usedPercent,
                windowDurationMins: duration,
                resetsAt: resetDate
            )
        }
    }
}

enum CodexAppServerError: LocalizedError {
    case executableNotFound(String)
    case launchFailed(String)
    case requestFailed(String)
    case timedOut(String)
    case invalidResponse(String)
    case missingRateLimitData
    case loginFailed(String)
    case authFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let configured):
            return "Codex executable was not found. Set the path in Settings. Current value: \(configured)"
        case .launchFailed(let message):
            return "Could not start codex app-server: \(message)"
        case .requestFailed(let message):
            return message
        case .timedOut(let detail):
            return detail.isEmpty
                ? "Timed out waiting for codex app-server."
                : "Timed out waiting for codex app-server. \(detail)"
        case .invalidResponse(let message):
            return "Unexpected codex app-server response: \(message)"
        case .missingRateLimitData:
            return "Codex app-server did not return ChatGPT rate limit data. Sign in to Codex with a ChatGPT account, then refresh."
        case .loginFailed(let message):
            return "Codex ChatGPT login failed: \(message)"
        case .authFileMissing(let path):
            return "Codex ChatGPT login did not create auth.json at \(path)."
        }
    }
}

private enum CodexExecutableResolver {
    static func resolve(_ configuredPath: String) throws -> URL {
        let configured = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.contains("/") {
            return try validate(URL(fileURLWithPath: configured.expandingTildeInPath), configured: configuredPath)
        }

        let executableName = configured.isEmpty ? "codex" : configured
        for candidate in candidates(named: executableName) {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw CodexAppServerError.executableNotFound(configuredPath)
    }

    private static func validate(_ url: URL, configured: String) throws -> URL {
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw CodexAppServerError.executableNotFound(configured)
    }

    private static func candidates(named executableName: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [
            "/Applications/Codex.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
            "/usr/bin/\(executableName)"
        ]

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for entry in pathEntries {
            paths.append(URL(fileURLWithPath: entry).appendingPathComponent(executableName).path)
        }

        var seen: Set<String> = []
        return paths.compactMap { path in
            let standardized = URL(fileURLWithPath: path.expandingTildeInPath).standardizedFileURL
            guard !seen.contains(standardized.path) else { return nil }
            seen.insert(standardized.path)
            return standardized
        }
    }
}

private final class AppServerRPCConnection: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let error: FileHandle
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outputBuffer = Data()
    private var messages: [[String: Any]] = []
    private var errorBuffer = Data()
    private var closed = false

    init(input: FileHandle, output: FileHandle, error: FileHandle) {
        self.input = input
        self.output = output
        self.error = error

        self.output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.ingestOutput(data)
        }

        self.error.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.ingestError(data)
        }
    }

    func request<T: Decodable>(
        id: Int,
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval) throws -> T
    {
        try send(message: Self.requestMessage(id: id, method: method, params: params))
        let response = try waitForResponse(id: id, timeout: timeout)
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "codex app-server request failed."
            throw CodexAppServerError.requestFailed(message)
        }
        guard let result = response["result"] else {
            throw CodexAppServerError.invalidResponse("missing result for \(method)")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CodexAppServerError.invalidResponse(error.localizedDescription)
        }
    }

    func notify(method: String, params: [String: Any]) throws {
        try send(message: [
            "method": method,
            "params": params
        ])
    }

    func waitForNotification(
        method: String,
        loginID: String,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let notification = popNotification(method: method, loginID: loginID) {
                return notification
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw CodexAppServerError.timedOut(stderrText())
            }

            let waitMs = max(1, min(Int(remaining * 1000), 250))
            _ = semaphore.wait(timeout: .now() + .milliseconds(waitMs))
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        output.readabilityHandler = nil
        error.readabilityHandler = nil
        try? input.close()
        try? output.close()
        try? error.close()
    }

    private static func requestMessage(id: Int, method: String, params: [String: Any]?) -> [String: Any] {
        var message: [String: Any] = [
            "id": id,
            "method": method
        ]
        if let params {
            message["params"] = params
        }
        return message
    }

    private func send(message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        input.write(data)
    }

    private func waitForResponse(id: Int, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let response = popResponse(id: id) {
                return response
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                throw CodexAppServerError.timedOut(stderrText())
            }

            let waitMs = max(1, min(Int(remaining * 1000), 250))
            _ = semaphore.wait(timeout: .now() + .milliseconds(waitMs))
        }
    }

    private func popResponse(id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = messages.firstIndex(where: { message in
            if let number = message["id"] as? NSNumber {
                return number.intValue == id
            }
            return false
        }) else {
            return nil
        }
        return messages.remove(at: index)
    }

    private func popNotification(method: String, loginID: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = messages.firstIndex(where: { message in
            guard message["method"] as? String == method else { return false }
            let params = message["params"] as? [String: Any]
            return params?["loginId"] as? String == loginID
        }) else {
            return nil
        }
        return messages.remove(at: index)
    }

    private func ingestOutput(_ data: Data) {
        guard !data.isEmpty else {
            semaphore.signal()
            return
        }

        lock.lock()
        outputBuffer.append(data)

        while let newline = outputBuffer.firstRange(of: Data([0x0A])) {
            let line = outputBuffer.subdata(in: 0..<newline.lowerBound)
            outputBuffer.removeSubrange(0..<newline.upperBound)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            messages.append(message)
            semaphore.signal()
        }
        lock.unlock()
    }

    private func ingestError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        errorBuffer.append(data)
        if errorBuffer.count > 8_000 {
            errorBuffer.removeFirst(errorBuffer.count - 8_000)
        }
        lock.unlock()
    }

    private func stderrText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct EmptyRPCResult: Decodable {}

private struct AccountReadResult: Decodable {
    var account: AccountPayload?
}

private struct AccountPayload: Decodable {
    var type: String
    var email: String?
    var planType: String?
}

private struct AccountLoginStartResult: Decodable {
    var loginId: String?
    var authUrl: String?
}

private struct RateLimitsReadResult: Decodable {
    var rateLimits: RateLimitSnapshot?
    var rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

private struct RateLimitSnapshot: Decodable {
    var limitId: String?
    var primary: RateLimitWindowPayload?
    var secondary: RateLimitWindowPayload?
}

private struct RateLimitWindowPayload: Decodable {
    var usedPercent: Double?
    var windowDurationMins: Int?
    var resetsAt: Double?

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMins
        case resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = Self.decodeDouble(for: .usedPercent, in: container)
        windowDurationMins = Self.decodeInt(for: .windowDurationMins, in: container)
        resetsAt = Self.decodeDouble(for: .resetsAt, in: container)
    }

    private static func decodeDouble(
        for key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>) -> Double?
    {
        if let value = try? container.decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    private static func decodeInt(
        for key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>) -> Int?
    {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}

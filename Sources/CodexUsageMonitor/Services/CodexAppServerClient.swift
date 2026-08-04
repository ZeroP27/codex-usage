import AppKit
import Foundation
import Darwin
import OSLog

struct CodexAppServerClient {
    var executablePath: String
    var timeout: TimeInterval = 15
    var loginTimeout: TimeInterval = 300
    private static let clientVersion = "0.3.1"
    private static let chromeBundleIdentifier = "com.google.Chrome"
    private static let openToolURL = URL(fileURLWithPath: "/usr/bin/open")
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

        do {
            try openAuthenticationURL(authURL)
        } catch {
            Self.logger.error("chatgpt login failed to open chrome incognito auth_url_host=\(authURL.host ?? "missing", privacy: .public) error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            throw error
        }
        Self.logger.info("chatgpt login requested chrome incognito auth_url_host=\(authURL.host ?? "missing", privacy: .public)")

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

    private func openAuthenticationURL(_ url: URL) throws {
        guard Self.chromeApplicationURL() != nil else {
            throw CodexAppServerError.loginFailed("Google Chrome is required to open the ChatGPT login in an incognito window.")
        }
        guard FileManager.default.isExecutableFile(atPath: Self.openToolURL.path) else {
            throw CodexAppServerError.loginFailed("Could not find /usr/bin/open to launch Chrome.")
        }

        let process = Process()
        process.executableURL = Self.openToolURL
        process.arguments = Self.chromeIncognitoOpenArguments(for: url)
        Self.logger.info("requesting chrome incognito login requested_new_instance=true auth_url_host=\(url.host ?? "missing", privacy: .public)")

        let errorPipe = Pipe()
        process.standardError = errorPipe
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.loginFailed("Could not launch Chrome incognito login window: \(error.localizedDescription)")
        }
        guard terminated.wait(timeout: .now() + timeout) == .success else {
            Self.stop(process)
            throw CodexAppServerError.loginFailed("Timed out while asking macOS to open Chrome.")
        }
        Self.logger.info("chrome incognito open request completed status=\(process.terminationStatus, privacy: .public)")

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = errorText.map { " \($0)" } ?? ""
            throw CodexAppServerError.loginFailed("Could not launch Chrome incognito login window.\(detail)")
        }
    }

    static func chromeIncognitoOpenArguments(for url: URL) -> [String] {
        [
            "-n",
            "-b",
            chromeBundleIdentifier,
            "--args",
            "--incognito",
            url.absoluteString
        ]
    }

    private static func chromeApplicationURL() -> URL? {
        if Thread.isMainThread {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleIdentifier)
        }

        var applicationURL: URL?
        DispatchQueue.main.sync {
            applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleIdentifier)
        }
        return applicationURL
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

    static func makeSnapshot(
        account: AccountPayload?,
        rateLimits: RateLimitsReadResult,
        sourceDescription: String,
        now: Date = Date()) throws -> UsageSnapshot
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

        let resetCredits = rateLimits.rateLimitResetCredits?.summary(now: now)
        Self.logger.info("app-server reset credits decoded present=\((resetCredits != nil), privacy: .public) available_count=\(resetCredits?.availableCount ?? 0, privacy: .public) reported_count=\(resetCredits?.reportedAvailableCount ?? 0, privacy: .public) expiration_count=\(resetCredits?.expirations.count ?? 0, privacy: .public)")

        return UsageSnapshot(
            account: accountSnapshot,
            sessionWindow: session,
            weeklyWindow: weekly,
            resetCredits: resetCredits,
            updatedAt: now,
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
            guard let duration = window.windowDurationMins, duration > 0 else { return nil }

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

enum CodexExecutableResolver {
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

    static func candidates(named executableName: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [String] = []
        if executableName == "codex" {
            paths.append(contentsOf: [
                "/Applications/Codex.app/Contents/Resources/codex",
                home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path
            ])
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
            "/usr/bin/\(executableName)"
        ])

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

final class AppServerRPCConnection: @unchecked Sendable {
    private static let maximumOutputBufferByteCount = 1_024 * 1_024
    private static let maximumMessageByteCount = 256 * 1_024
    private static let maximumQueuedMessageCount = 128

    private let input: FileHandle
    private let output: FileHandle
    private let error: FileHandle
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outputBuffer = Data()
    private var messages: [[String: Any]] = []
    private var errorBuffer = Data()
    private var closed = false
    private var outputReachedEOF = false
    private var protocolFailureMessage: String?

    init(input: FileHandle, output: FileHandle, error: FileHandle) {
        self.input = input
        self.output = output
        self.error = error

        self.output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            self?.ingestOutput(data)
        }

        self.error.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
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
            try throwIfConnectionFailed()

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
        do {
            try input.write(contentsOf: data)
        } catch {
            throw CodexAppServerError.requestFailed(
                "Could not write to codex app-server: \(error.localizedDescription)"
            )
        }
    }

    private func waitForResponse(id: Int, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if let response = popResponse(id: id) {
                return response
            }
            try throwIfConnectionFailed()

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
            lock.lock()
            outputReachedEOF = true
            lock.unlock()
            semaphore.signal()
            return
        }

        lock.lock()
        guard protocolFailureMessage == nil else {
            lock.unlock()
            return
        }
        guard data.count <= Self.maximumOutputBufferByteCount - outputBuffer.count else {
            protocolFailureMessage = "codex app-server output exceeded the supported buffer limit."
            outputBuffer.removeAll(keepingCapacity: false)
            lock.unlock()
            semaphore.signal()
            return
        }
        outputBuffer.append(data)

        while let newline = outputBuffer.firstRange(of: Data([0x0A])) {
            let line = outputBuffer.subdata(in: 0..<newline.lowerBound)
            outputBuffer.removeSubrange(0..<newline.upperBound)
            guard !line.isEmpty else { continue }
            guard line.count <= Self.maximumMessageByteCount else {
                protocolFailureMessage = "codex app-server sent an oversized message."
                break
            }
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            guard messages.count < Self.maximumQueuedMessageCount else {
                protocolFailureMessage = "codex app-server sent too many unhandled messages."
                break
            }
            messages.append(message)
            semaphore.signal()
        }
        let didFailProtocol = protocolFailureMessage != nil
        lock.unlock()
        if didFailProtocol {
            semaphore.signal()
        }
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

    private func throwIfConnectionFailed() throws {
        lock.lock()
        let reachedEOF = outputReachedEOF
        let protocolFailureMessage = protocolFailureMessage
        let errorText = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.unlock()

        if let protocolFailureMessage {
            throw CodexAppServerError.requestFailed(protocolFailureMessage)
        }
        guard reachedEOF else { return }
        let detail = errorText.isEmpty ? "" : " \(errorText)"
        throw CodexAppServerError.requestFailed(
            "codex app-server closed its output before replying.\(detail)"
        )
    }
}

private struct EmptyRPCResult: Decodable {}

private struct AccountReadResult: Decodable {
    var account: AccountPayload?
}

struct AccountPayload: Decodable {
    var type: String
    var email: String?
    var planType: String?
}

private struct AccountLoginStartResult: Decodable {
    var loginId: String?
    var authUrl: String?
}

struct RateLimitsReadResult: Decodable {
    var rateLimits: RateLimitSnapshot?
    var rateLimitsByLimitId: [String: RateLimitSnapshot]?
    var rateLimitResetCredits: RateLimitResetCreditsPayload?

    private enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitId
        case rateLimitResetCredits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try? container.decodeIfPresent(
            RateLimitSnapshot.self,
            forKey: .rateLimits
        )
        rateLimitsByLimitId = try? container.decodeIfPresent(
            [String: RateLimitSnapshot].self,
            forKey: .rateLimitsByLimitId
        )
        rateLimitResetCredits = try? container.decodeIfPresent(
            RateLimitResetCreditsPayload.self,
            forKey: .rateLimitResetCredits
        )
    }
}

struct RateLimitSnapshot: Decodable {
    var limitId: String?
    var primary: RateLimitWindowPayload?
    var secondary: RateLimitWindowPayload?
}

struct RateLimitResetCreditsPayload: Decodable {
    var availableCount: Int
    var credits: [Credit]

    private enum CodingKeys: String, CodingKey {
        case availableCount
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCount: Int?
        if let value = try? container.decode(Int.self, forKey: .availableCount) {
            rawCount = value
        } else if let value = try? container.decode(Double.self, forKey: .availableCount) {
            rawCount = SafeNumericConversions.exactInt(value)
        } else if let value = try? container.decode(String.self, forKey: .availableCount) {
            rawCount = Int(value)
        } else {
            rawCount = nil
        }

        guard let rawCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .availableCount,
                in: container,
                debugDescription: "Reset credit count is missing or invalid."
            )
        }
        availableCount = try ResetCreditsNormalizer.validateAvailableCount(
            rawCount,
            codingPath: container.codingPath + [CodingKeys.availableCount]
        )
        credits = (try? container.decodeIfPresent([Credit].self, forKey: .credits)) ?? []
    }

    func summary(now: Date) -> ResetCreditsSummary {
        ResetCreditsNormalizer.summary(
            availableCount: availableCount,
            details: credits.map {
                ResetCreditDetail(status: $0.status, expiresAt: $0.expiresAt)
            },
            now: now
        )
    }

    struct Credit: Decodable {
        var status: String?
        var expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case status
            case expiresAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            expiresAt = Self.decodeDate(for: .expiresAt, in: container)
        }

        private static func decodeDate(
            for key: CodingKeys,
            in container: KeyedDecodingContainer<CodingKeys>
        ) -> Date? {
            if let value = try? container.decode(Double.self, forKey: key),
               let seconds = SafeNumericConversions.finiteDouble(value)
            {
                return Date(timeIntervalSince1970: seconds)
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return Date(timeIntervalSince1970: TimeInterval(value))
            }
            if let value = try? container.decode(String.self, forKey: key),
               let seconds = Double(value).flatMap(SafeNumericConversions.finiteDouble)
            {
                return Date(timeIntervalSince1970: seconds)
            }
            return nil
        }
    }
}

struct RateLimitWindowPayload: Decodable {
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
            return SafeNumericConversions.finiteDouble(value)
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Double(value).flatMap(SafeNumericConversions.finiteDouble)
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
            return SafeNumericConversions.exactInt(value)
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

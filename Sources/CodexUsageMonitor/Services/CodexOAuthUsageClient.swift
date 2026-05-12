import Foundation
import OSLog

struct CodexOAuthUsageClient {
    var timeout: TimeInterval = 30
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "OAuthUsage"
    )

    func loadSnapshot(
        authFileURL: URL? = nil,
        registryAccount: CodexManagedAccount? = nil,
        activeAuthFileURL: URL? = nil
    ) async throws -> UsageSnapshot {
        let authFileURL = authFileURL ?? CodexOAuthCredentialsStore.authFileURL
        var credentials = try CodexOAuthCredentialsStore.load(
            from: authFileURL,
            fallbackAccountID: registryAccount?.chatgptAccountID
        )

        if credentials.shouldRefreshBeforeUse {
            credentials = try await CodexOAuthTokenRefresher.refresh(credentials, timeout: timeout)
            try CodexOAuthCredentialsStore.save(credentials, to: authFileURL)
            try syncActiveAuthIfNeeded(
                authFileURL: authFileURL,
                registryAccount: registryAccount,
                activeAuthFileURL: activeAuthFileURL
            )
            Self.logger.info("refreshed token before usage key=\(registryAccount?.accountKey ?? "active", privacy: .private)")
        }

        do {
            let response = try await fetchUsage(credentials: credentials)
            return try Self.makeSnapshot(
                response: response,
                credentials: credentials,
                registryAccount: registryAccount
            )
        } catch CodexOAuthUsageError.unauthorized where !credentials.refreshToken.isEmpty {
            credentials = try await CodexOAuthTokenRefresher.refresh(credentials, timeout: timeout)
            try CodexOAuthCredentialsStore.save(credentials, to: authFileURL)
            try syncActiveAuthIfNeeded(
                authFileURL: authFileURL,
                registryAccount: registryAccount,
                activeAuthFileURL: activeAuthFileURL
            )
            Self.logger.info("refreshed token after unauthorized key=\(registryAccount?.accountKey ?? "active", privacy: .private)")
            let response = try await fetchUsage(credentials: credentials)
            return try Self.makeSnapshot(
                response: response,
                credentials: credentials,
                registryAccount: registryAccount
            )
        }
    }

    private func fetchUsage(credentials: CodexOAuthCredentials) async throws -> CodexOAuthUsageResponse {
        var request = URLRequest(url: Self.usageURL())
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Usage", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexOAuthUsageError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200...299:
                do {
                    return try JSONDecoder().decode(CodexOAuthUsageResponse.self, from: data)
                } catch {
                    throw CodexOAuthUsageError.decodeFailed(error.localizedDescription)
                }
            case 401, 403:
                throw CodexOAuthUsageError.unauthorized
            default:
                throw CodexOAuthUsageError.serverError(
                    httpResponse.statusCode,
                    Self.errorBody(from: data)
                )
            }
        } catch let error as CodexOAuthUsageError {
            throw error
        } catch {
            throw CodexOAuthUsageError.networkError(error)
        }
    }

    private static func usageURL() -> URL {
        URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    }

    private static func errorBody(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                return message.truncatedForDisplay
            }
            if let error = json["error"] as? String {
                return error.truncatedForDisplay
            }
        }
        return String(data: data, encoding: .utf8)?.truncatedForDisplay
    }

    private static func makeSnapshot(
        response: CodexOAuthUsageResponse,
        credentials: CodexOAuthCredentials,
        registryAccount: CodexManagedAccount?) throws -> UsageSnapshot
    {
        let windows = [
            ("primary", response.rateLimit?.primaryWindow),
            ("secondary", response.rateLimit?.secondaryWindow)
        ].compactMap { role, window -> QuotaWindow? in
            guard let window,
                  let usedPercent = window.usedPercent,
                  let resetAt = window.resetAt,
                  let windowSeconds = window.limitWindowSeconds
            else {
                return nil
            }

            let duration = windowSeconds / 60
            return QuotaWindow(
                id: "oauth-\(role)-\(duration)",
                usedPercent: usedPercent,
                windowDurationMins: duration,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(resetAt))
            )
        }

        let session = windows.first {
            $0.windowDurationMins == CodexUsageConstants.sessionWindowMinutes
        }
        let weekly = windows.first {
            $0.windowDurationMins == CodexUsageConstants.weeklyWindowMinutes
        }

        guard session != nil || weekly != nil else {
            throw CodexOAuthUsageError.missingRateLimitData
        }

        let tokenPayload = credentials.idToken.flatMap(Self.parseJWT)
        let email = Self.email(from: tokenPayload) ?? registryAccount?.email
        let plan = response.planType ?? Self.planType(from: tokenPayload) ?? registryAccount?.planType

        return UsageSnapshot(
            account: CodexAccount(
                type: registryAccount?.authMode ?? "chatgpt",
                email: email,
                planType: plan
            ),
            sessionWindow: session,
            weeklyWindow: weekly,
            updatedAt: Date(),
            sourceDescription: CodexUsageDataSource.oauthAPI.title
        )
    }

    private func syncActiveAuthIfNeeded(
        authFileURL: URL,
        registryAccount: CodexManagedAccount?,
        activeAuthFileURL: URL?
    ) throws {
        guard let registryAccount, let activeAuthFileURL else { return }
        let registryStore = CodexAccountsRegistryStore(
            codexHomeURL: activeAuthFileURL.deletingLastPathComponent()
        )
        try registryStore.syncActiveAuthIfAccountIsActive(
            accountKey: registryAccount.accountKey,
            authFileURL: authFileURL
        )
    }

    private static func email(from payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        return ((payload["email"] as? String) ?? (profile?["email"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func planType(from payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        return ((auth?["chatgpt_plan_type"] as? String) ?? (payload["chatgpt_plan_type"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }
}

private struct CodexOAuthCredentials {
    private static let accessTokenRefreshLeeway: TimeInterval = 5 * 60

    var accessToken: String
    var refreshToken: String
    var idToken: String?
    var accountID: String?
    var lastRefresh: Date?

    var shouldRefreshBeforeUse: Bool {
        guard !refreshToken.isEmpty else { return false }
        if let expiresAt = accessTokenExpiresAt {
            return expiresAt.timeIntervalSinceNow <= Self.accessTokenRefreshLeeway
        }
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
    }

    private var accessTokenExpiresAt: Date? {
        Self.jwtExpirationDate(accessToken)
    }

    private static func jwtExpirationDate(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = Self.timeIntervalValue(json["exp"])
        else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private static func timeIntervalValue(_ value: Any?) -> TimeInterval? {
        if let value = value as? TimeInterval { return value }
        if let value = value as? Int { return TimeInterval(value) }
        if let value = value as? String { return TimeInterval(value) }
        return nil
    }
}

private enum CodexOAuthCredentialsStore {
    static var codexHomeURL: URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            return URL(fileURLWithPath: configured.expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var authFileURL: URL {
        codexHomeURL.appendingPathComponent("auth.json")
    }

    static func load(
        from authFileURL: URL = Self.authFileURL,
        fallbackAccountID: String? = nil
    ) throws -> CodexOAuthCredentials {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw CodexOAuthUsageError.credentialsNotFound
        }

        let data = try Data(contentsOf: authFileURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthUsageError.decodeFailed("Invalid auth.json")
        }

        guard let tokens = json["tokens"] as? [String: Any] else {
            throw CodexOAuthUsageError.missingTokens
        }
        guard let accessToken = Self.stringValue(
            in: tokens,
            snakeCaseKey: "access_token",
            camelCaseKey: "accessToken"),
            !accessToken.isEmpty
        else {
            throw CodexOAuthUsageError.missingTokens
        }

        let refreshToken = Self.stringValue(
            in: tokens,
            snakeCaseKey: "refresh_token",
            camelCaseKey: "refreshToken") ?? ""
        let idToken = Self.stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken")
        let accountID = Self.stringValue(
            in: tokens,
            snakeCaseKey: "account_id",
            camelCaseKey: "accountId"
        ) ?? fallbackAccountID

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            lastRefresh: Self.parseLastRefresh(from: json["last_refresh"])
        )
    }

    static func save(
        _ credentials: CodexOAuthCredentials,
        to authFileURL: URL = Self.authFileURL
    ) throws {
        let existingData = try Data(contentsOf: authFileURL)
        guard var json = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            throw CodexOAuthUsageError.decodeFailed("Invalid auth.json")
        }

        guard var tokens = json["tokens"] as? [String: Any] else {
            throw CodexOAuthUsageError.missingTokens
        }
        tokens["access_token"] = credentials.accessToken
        tokens["refresh_token"] = credentials.refreshToken
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountID = credentials.accountID {
            tokens["account_id"] = accountID
        }

        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: authFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.hardenManagedAccountsDirectoryIfNeeded(for: authFileURL)
        try data.write(to: authFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: authFileURL.path
        )
    }

    private static func hardenManagedAccountsDirectoryIfNeeded(for authFileURL: URL) throws {
        let directoryURL = authFileURL.deletingLastPathComponent()
        guard directoryURL.lastPathComponent == "accounts" else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private static func parseLastRefresh(from raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func stringValue(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String) -> String?
    {
        if let value = dictionary[snakeCaseKey] as? String, !value.isEmpty {
            return value
        }
        if let value = dictionary[camelCaseKey] as? String, !value.isEmpty {
            return value
        }
        return nil
    }
}

private enum CodexOAuthTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func refresh(_ credentials: CodexOAuthCredentials, timeout: TimeInterval) async throws -> CodexOAuthCredentials {
        guard !credentials.refreshToken.isEmpty else {
            return credentials
        }

        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email"
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexOAuthUsageError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw CodexOAuthUsageError.serverError(
                    httpResponse.statusCode,
                    Self.errorBody(from: data)
                )
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexOAuthUsageError.decodeFailed("Invalid refresh response")
            }

            return CodexOAuthCredentials(
                accessToken: json["access_token"] as? String ?? credentials.accessToken,
                refreshToken: json["refresh_token"] as? String ?? credentials.refreshToken,
                idToken: json["id_token"] as? String ?? credentials.idToken,
                accountID: credentials.accountID,
                lastRefresh: Date()
            )
        } catch let error as CodexOAuthUsageError {
            throw error
        } catch {
            throw CodexOAuthUsageError.networkError(error)
        }
    }

    private static func errorBody(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                return message.truncatedForDisplay
            }
            if let error = json["error"] as? String {
                return error.truncatedForDisplay
            }
        }
        return String(data: data, encoding: .utf8)?.truncatedForDisplay
    }
}

private struct CodexOAuthUsageResponse: Decodable {
    var planType: String?
    var rateLimit: RateLimitDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimit)
    }

    struct RateLimitDetails: Decodable {
        var primaryWindow: WindowSnapshot?
        var secondaryWindow: WindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primaryWindow = try? container.decodeIfPresent(WindowSnapshot.self, forKey: .primaryWindow)
            secondaryWindow = try? container.decodeIfPresent(WindowSnapshot.self, forKey: .secondaryWindow)
        }
    }

    struct WindowSnapshot: Decodable {
        var usedPercent: Double?
        var resetAt: Int?
        var limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = Self.decodeDouble(for: .usedPercent, in: container)
            resetAt = Self.decodeInt(for: .resetAt, in: container)
            limitWindowSeconds = Self.decodeInt(for: .limitWindowSeconds, in: container)
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
}

enum CodexOAuthUsageError: LocalizedError {
    case credentialsNotFound
    case missingTokens
    case unauthorized
    case invalidResponse
    case decodeFailed(String)
    case serverError(Int, String?)
    case networkError(Error)
    case missingRateLimitData

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Codex OAuth credentials were not found. Sign in with Codex, or switch Settings to CLI RPC."
        case .missingTokens:
            return "Codex auth.json does not contain ChatGPT OAuth tokens. Sign in with Codex, or switch Settings to CLI RPC."
        case .unauthorized:
            return "Codex OAuth token expired or was rejected. Sign in with Codex again, or switch Settings to CLI RPC."
        case .invalidResponse:
            return "Invalid response from the Codex OAuth usage API."
        case .decodeFailed(let message):
            return "Could not decode Codex OAuth usage data: \(message)"
        case .serverError(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Codex OAuth API error \(statusCode): \(message)"
            }
            return "Codex OAuth API error \(statusCode)."
        case .networkError(let error):
            return "Network error while reading Codex OAuth usage: \(error.localizedDescription)"
        case .missingRateLimitData:
            return "Codex OAuth API did not return rate limit data."
        }
    }
}

private extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }

    var truncatedForDisplay: String {
        let limit = 1_000
        guard count > limit else { return self }
        return String(prefix(limit)) + "..."
    }
}

import CryptoKit
import Foundation

enum LogFingerprint {
    static func account(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "missing" }
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

enum LogErrorSummary {
    static func category(_ error: Error) -> String {
        if let error = error as? CodexOAuthUsageError {
            return oauthCategory(error)
        }
        if let error = error as? CodexUsageAccountStoreError {
            return accountStoreCategory(error)
        }
        if let error = error as? CodexAppServerError {
            return appServerCategory(error)
        }
        if let error = error as? CodexUsageConfigurationError {
            return configurationCategory(error)
        }
        if error is CodexUsagePreferencesError {
            return "preferences_invalid"
        }

        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }

    private static func oauthCategory(_ error: CodexOAuthUsageError) -> String {
        switch error {
        case .credentialsNotFound:
            return "oauth_credentials_not_found"
        case .credentialsTooLarge:
            return "oauth_credentials_too_large"
        case .missingTokens:
            return "oauth_missing_tokens"
        case .missingAccountInfo:
            return "oauth_missing_account_info"
        case .unauthorized:
            return "oauth_unauthorized"
        case .invalidResponse:
            return "oauth_invalid_response"
        case .decodeFailed:
            return "oauth_decode_failed"
        case .serverError(let statusCode, _):
            return "oauth_server_\(statusCode)"
        case .networkError(let error):
            let nsError = error as NSError
            return "oauth_network_\(nsError.domain)#\(nsError.code)"
        case .missingRateLimitData:
            return "oauth_missing_rate_limit_data"
        case .accountMismatch:
            return "oauth_account_mismatch"
        }
    }

    private static func accountStoreCategory(_ error: CodexUsageAccountStoreError) -> String {
        switch error {
        case .authSnapshotNotFound:
            return "account_store_auth_snapshot_not_found"
        case .authSnapshotAccountMismatch:
            return "account_store_auth_snapshot_account_mismatch"
        case .unsupportedSchema:
            return "account_store_unsupported_schema"
        case .decodeFailed:
            return "account_store_decode_failed"
        case .accountNotFound:
            return "account_store_account_not_found"
        case .noManagedAccounts:
            return "account_store_no_managed_accounts"
        case .activeAccountCannotBeRemoved:
            return "account_store_active_account_cannot_be_removed"
        case .activeAuthRestoreFailed:
            return "account_store_active_auth_restore_failed"
        case .authSnapshotRestoreFailed:
            return "account_store_auth_snapshot_restore_failed"
        case .lockFailed:
            return "account_store_lock_failed"
        case .archiveInvalid:
            return "account_store_archive_invalid"
        case .archiveTooLarge:
            return "account_store_archive_too_large"
        case .importCommitFailed:
            return "account_store_import_commit_failed"
        case .activeAuthCannotBeReplaced:
            return "account_store_active_auth_cannot_be_replaced"
        case .managedAuthRefreshConflict:
            return "account_store_managed_auth_refresh_conflict"
        case .storageChangedSinceImportPreview:
            return "account_store_import_storage_changed"
        }
    }

    private static func appServerCategory(_ error: CodexAppServerError) -> String {
        switch error {
        case .executableNotFound:
            return "app_server_executable_not_found"
        case .launchFailed:
            return "app_server_launch_failed"
        case .requestFailed:
            return "app_server_request_failed"
        case .timedOut:
            return "app_server_timed_out"
        case .invalidResponse:
            return "app_server_invalid_response"
        case .missingRateLimitData:
            return "app_server_missing_rate_limit_data"
        case .loginFailed:
            return "app_server_login_failed"
        case .authFileMissing:
            return "app_server_auth_file_missing"
        }
    }

    private static func configurationCategory(
        _ error: CodexUsageConfigurationError
    ) -> String {
        switch error {
        case .weakPassphrase:
            return "configuration_weak_passphrase"
        case .passphraseTooLong:
            return "configuration_passphrase_too_long"
        case .fileTooLarge:
            return "configuration_file_too_large"
        case .payloadTooLarge:
            return "configuration_payload_too_large"
        case .unsupportedFormat:
            return "configuration_unsupported_format"
        case .unsupportedSchema:
            return "configuration_unsupported_schema"
        case .unsupportedKeyDerivationParameters:
            return "configuration_unsupported_kdf_parameters"
        case .invalidPayload:
            return "configuration_invalid_payload"
        case .invalidEncryptedConfiguration:
            return "configuration_invalid_encrypted_data"
        case .encryptionFailed:
            return "configuration_encryption_failed"
        case .randomGenerationFailed:
            return "configuration_random_generation_failed"
        }
    }
}

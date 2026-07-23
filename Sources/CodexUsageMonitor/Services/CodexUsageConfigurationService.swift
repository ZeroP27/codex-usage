import CryptoKit
import Foundation
import Security

struct CodexUsageConfigurationPayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var createdAt: Date
    var preferences: CodexUsagePreferences
    var launchAtLoginEnabled: Bool
    var managedAccounts: CodexManagedAccountsArchive

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        createdAt: Date = Date(),
        preferences: CodexUsagePreferences,
        launchAtLoginEnabled: Bool,
        managedAccounts: CodexManagedAccountsArchive
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.preferences = preferences
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.managedAccounts = managedAccounts
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case preferences
        case launchAtLoginEnabled = "launch_at_login_enabled"
        case managedAccounts = "managed_accounts"
    }
}

struct CodexUsageConfigurationPreview: Equatable, Sendable {
    var createdAt: Date
    var managedAccountCount: Int
    var preferences: CodexUsagePreferences
    var launchAtLoginEnabled: Bool
}

struct CodexUsageEncryptedConfigurationEnvelope: Codable, Equatable, Sendable {
    var format: String
    var schemaVersion: Int
    var keyDerivation: String
    var iterationCount: Int
    var salt: Data
    var cipher: String
    var sealedData: Data

    enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion = "schema_version"
        case keyDerivation = "key_derivation"
        case iterationCount = "iteration_count"
        case salt
        case cipher
        case sealedData = "sealed_data"
    }
}

struct CodexUsageConfigurationService: Sendable {
    static let encryptedConfigurationFormat =
        "dev.idea-space.codex-usage.encrypted-configuration"
    static let envelopeSchemaVersion = 1
    static let keyDerivationIdentifier = "pbkdf2-hmac-sha256"
    static let cipherIdentifier = "aes-256-gcm"
    static let defaultIterationCount = 600_000
    static let minimumIterationCount = 100_000
    static let maximumIterationCount = 2_000_000
    static let minimumPassphraseCharacterCount = 12
    static let maximumPassphraseByteCount = 4_096
    static let saltByteCount = 32
    static let maximumEncryptedFileSize = 32 * 1_024 * 1_024
    static let maximumPlaintextSize = 20 * 1_024 * 1_024
    static let maximumRegistrySize = 4 * 1_024 * 1_024
    static let maximumAuthSnapshotSize = 2 * 1_024 * 1_024
    static let maximumManagedAccountCount = 100

    private static let additionalAuthenticatedData = Data(
        "Codex Usage encrypted configuration v1".utf8
    )

    var iterationCount: Int

    init(iterationCount: Int = Self.defaultIterationCount) {
        self.iterationCount = iterationCount
    }

    func exportData(
        _ payload: CodexUsageConfigurationPayload,
        passphrase: String
    ) throws -> Data {
        try validateExportPassphrase(passphrase)
        try validateIterationCount(iterationCount)
        let validatedPayload = try validatePayload(payload)
        let plaintext = try Self.payloadEncoder.encode(validatedPayload)
        guard plaintext.count <= Self.maximumPlaintextSize else {
            throw CodexUsageConfigurationError.payloadTooLarge(
                maximumBytes: Self.maximumPlaintextSize
            )
        }

        let salt = try Self.randomSalt()
        let keyData = try PBKDF2HMACSHA256.deriveKey(
            password: Data(passphrase.utf8),
            salt: salt,
            iterationCount: iterationCount,
            outputByteCount: 32
        )
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            authenticating: Self.additionalAuthenticatedData
        )
        guard let combined = sealedBox.combined else {
            throw CodexUsageConfigurationError.encryptionFailed
        }

        let envelope = CodexUsageEncryptedConfigurationEnvelope(
            format: Self.encryptedConfigurationFormat,
            schemaVersion: Self.envelopeSchemaVersion,
            keyDerivation: Self.keyDerivationIdentifier,
            iterationCount: iterationCount,
            salt: salt,
            cipher: Self.cipherIdentifier,
            sealedData: combined
        )
        let encryptedData = try Self.envelopeEncoder.encode(envelope)
        guard encryptedData.count <= Self.maximumEncryptedFileSize else {
            throw CodexUsageConfigurationError.fileTooLarge(
                maximumBytes: Self.maximumEncryptedFileSize
            )
        }
        return encryptedData
    }

    func importPayload(
        from encryptedData: Data,
        passphrase: String
    ) throws -> CodexUsageConfigurationPayload {
        guard !encryptedData.isEmpty else {
            throw CodexUsageConfigurationError.invalidEncryptedConfiguration
        }
        guard encryptedData.count <= Self.maximumEncryptedFileSize else {
            throw CodexUsageConfigurationError.fileTooLarge(
                maximumBytes: Self.maximumEncryptedFileSize
            )
        }
        guard !passphrase.isEmpty,
              passphrase.utf8.count <= Self.maximumPassphraseByteCount
        else {
            throw CodexUsageConfigurationError.invalidEncryptedConfiguration
        }

        let envelope: CodexUsageEncryptedConfigurationEnvelope
        do {
            envelope = try Self.envelopeDecoder.decode(
                CodexUsageEncryptedConfigurationEnvelope.self,
                from: encryptedData
            )
        } catch {
            throw CodexUsageConfigurationError.invalidEncryptedConfiguration
        }

        guard envelope.format == Self.encryptedConfigurationFormat else {
            throw CodexUsageConfigurationError.unsupportedFormat
        }
        guard envelope.schemaVersion == Self.envelopeSchemaVersion else {
            throw CodexUsageConfigurationError.unsupportedSchema(
                envelope.schemaVersion
            )
        }
        guard envelope.keyDerivation == Self.keyDerivationIdentifier,
              envelope.cipher == Self.cipherIdentifier
        else {
            throw CodexUsageConfigurationError.unsupportedFormat
        }
        guard envelope.salt.count == Self.saltByteCount else {
            throw CodexUsageConfigurationError.invalidEncryptedConfiguration
        }
        try validateIterationCount(envelope.iterationCount)

        do {
            let keyData = try PBKDF2HMACSHA256.deriveKey(
                password: Data(passphrase.utf8),
                salt: envelope.salt,
                iterationCount: envelope.iterationCount,
                outputByteCount: 32
            )
            let sealedBox = try AES.GCM.SealedBox(combined: envelope.sealedData)
            let plaintext = try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: keyData),
                authenticating: Self.additionalAuthenticatedData
            )
            guard plaintext.count <= Self.maximumPlaintextSize else {
                throw CodexUsageConfigurationError.invalidEncryptedConfiguration
            }
            let payload = try Self.payloadDecoder.decode(
                CodexUsageConfigurationPayload.self,
                from: plaintext
            )
            return try validatePayload(payload)
        } catch let error as CodexUsageConfigurationError {
            switch error {
            case .unsupportedSchema:
                throw error
            default:
                throw CodexUsageConfigurationError.invalidEncryptedConfiguration
            }
        } catch {
            throw CodexUsageConfigurationError.invalidEncryptedConfiguration
        }
    }

    func write(
        _ payload: CodexUsageConfigurationPayload,
        passphrase: String,
        to destinationURL: URL
    ) throws {
        let data = try exportData(payload, passphrase: passphrase)
        try OwnerOnlyFileWriter.write(data, to: destinationURL)
    }

    func read(
        from sourceURL: URL,
        passphrase: String
    ) throws -> CodexUsageConfigurationPayload {
        let data = try Self.readSizeLimitedFile(at: sourceURL)
        return try importPayload(from: data, passphrase: passphrase)
    }

    func preview(
        for payload: CodexUsageConfigurationPayload
    ) -> CodexUsageConfigurationPreview {
        CodexUsageConfigurationPreview(
            createdAt: payload.createdAt,
            managedAccountCount: payload.managedAccounts.authSnapshots.count,
            preferences: payload.preferences,
            launchAtLoginEnabled: payload.launchAtLoginEnabled
        )
    }

    private func validateExportPassphrase(_ passphrase: String) throws {
        guard passphrase.count >= Self.minimumPassphraseCharacterCount else {
            throw CodexUsageConfigurationError.weakPassphrase(
                minimumCharacters: Self.minimumPassphraseCharacterCount
            )
        }
        guard passphrase.utf8.count <= Self.maximumPassphraseByteCount else {
            throw CodexUsageConfigurationError.passphraseTooLong(
                maximumBytes: Self.maximumPassphraseByteCount
            )
        }
    }

    private func validateIterationCount(_ count: Int) throws {
        guard count >= Self.minimumIterationCount,
              count <= Self.maximumIterationCount
        else {
            throw CodexUsageConfigurationError.unsupportedKeyDerivationParameters
        }
    }

    private func validatePayload(
        _ payload: CodexUsageConfigurationPayload
    ) throws -> CodexUsageConfigurationPayload {
        guard payload.schemaVersion == CodexUsageConfigurationPayload.currentSchemaVersion else {
            throw CodexUsageConfigurationError.unsupportedSchema(
                payload.schemaVersion
            )
        }
        guard payload.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw CodexUsageConfigurationError.invalidPayload
        }

        let validatedPreferences: CodexUsagePreferences
        do {
            validatedPreferences = try payload.preferences.validated()
        } catch {
            throw CodexUsageConfigurationError.invalidPayload
        }

        let archive = payload.managedAccounts
        guard archive.schemaVersion == 1 else {
            throw CodexUsageConfigurationError.unsupportedSchema(
                archive.schemaVersion
            )
        }
        guard !archive.registryData.isEmpty,
              archive.registryData.count <= Self.maximumRegistrySize,
              archive.authSnapshots.count <= Self.maximumManagedAccountCount
        else {
            throw CodexUsageConfigurationError.invalidPayload
        }

        var totalBytes = archive.registryData.count
        var accountKeys = Set<String>()
        for snapshot in archive.authSnapshots {
            guard !snapshot.accountKey.isEmpty,
                  snapshot.accountKey.utf8.count <= 512,
                  !snapshot.authData.isEmpty,
                  snapshot.authData.count <= Self.maximumAuthSnapshotSize,
                  accountKeys.insert(snapshot.accountKey).inserted,
                  totalBytes <= Self.maximumPlaintextSize - snapshot.authData.count
            else {
                throw CodexUsageConfigurationError.invalidPayload
            }
            totalBytes += snapshot.authData.count
        }

        return CodexUsageConfigurationPayload(
            schemaVersion: payload.schemaVersion,
            createdAt: payload.createdAt,
            preferences: validatedPreferences,
            launchAtLoginEnabled: payload.launchAtLoginEnabled,
            managedAccounts: archive
        )
    }

    private static func randomSalt() throws -> Data {
        var salt = Data(count: saltByteCount)
        let status = salt.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(
                kSecRandomDefault,
                saltByteCount,
                baseAddress
            )
        }
        guard status == errSecSuccess else {
            throw CodexUsageConfigurationError.randomGenerationFailed
        }
        return salt
    }

    private static func readSizeLimitedFile(at sourceURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        var result = Data()
        let chunkSize = 64 * 1_024
        while result.count <= maximumEncryptedFileSize {
            let remaining = maximumEncryptedFileSize + 1 - result.count
            let chunk = try handle.read(
                upToCount: min(chunkSize, remaining)
            ) ?? Data()
            if chunk.isEmpty {
                return result
            }
            result.append(chunk)
        }

        throw CodexUsageConfigurationError.fileTooLarge(
            maximumBytes: maximumEncryptedFileSize
        )
    }

    private static var envelopeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var envelopeDecoder: JSONDecoder {
        JSONDecoder()
    }

    private static var payloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var payloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum CodexUsageConfigurationError: LocalizedError, Equatable {
    case weakPassphrase(minimumCharacters: Int)
    case passphraseTooLong(maximumBytes: Int)
    case fileTooLarge(maximumBytes: Int)
    case payloadTooLarge(maximumBytes: Int)
    case unsupportedFormat
    case unsupportedSchema(Int)
    case unsupportedKeyDerivationParameters
    case invalidPayload
    case invalidEncryptedConfiguration
    case encryptionFailed
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .weakPassphrase(let minimumCharacters):
            return "Configuration backup passwords must contain at least \(minimumCharacters) characters."
        case .passphraseTooLong(let maximumBytes):
            return "Configuration backup passwords must not exceed \(maximumBytes) UTF-8 bytes."
        case .fileTooLarge(let maximumBytes):
            return "The configuration backup exceeds the \(maximumBytes)-byte file size limit."
        case .payloadTooLarge(let maximumBytes):
            return "The configuration data exceeds the \(maximumBytes)-byte export size limit."
        case .unsupportedFormat:
            return "This is not a supported Codex Usage encrypted configuration backup."
        case .unsupportedSchema(let version):
            return "Codex Usage configuration schema \(version) is not supported."
        case .unsupportedKeyDerivationParameters:
            return "The configuration backup uses unsupported password-protection parameters."
        case .invalidPayload:
            return "The Codex Usage configuration data is invalid."
        case .invalidEncryptedConfiguration:
            return "The configuration backup could not be opened. The password may be incorrect, or the file may be damaged."
        case .encryptionFailed:
            return "The configuration backup could not be encrypted."
        case .randomGenerationFailed:
            return "Secure random data could not be generated for the configuration backup."
        }
    }
}

enum PBKDF2HMACSHA256 {
    static func deriveKey(
        password: Data,
        salt: Data,
        iterationCount: Int,
        outputByteCount: Int
    ) throws -> Data {
        guard iterationCount > 0,
              outputByteCount > 0,
              outputByteCount <= 1_024
        else {
            throw CodexUsageConfigurationError.unsupportedKeyDerivationParameters
        }

        let hmacKey = SymmetricKey(data: password)
        let digestByteCount = SHA256.byteCount
        let blockCount = (outputByteCount + digestByteCount - 1) / digestByteCount
        guard blockCount <= Int(UInt32.max) else {
            throw CodexUsageConfigurationError.unsupportedKeyDerivationParameters
        }

        var derivedKey = Data()
        derivedKey.reserveCapacity(blockCount * digestByteCount)

        for blockNumber in 1...blockCount {
            var blockIndex = UInt32(blockNumber).bigEndian
            var input = salt
            Swift.withUnsafeBytes(of: &blockIndex) { bytes in
                input.append(contentsOf: bytes)
            }

            var previous = Data(
                HMAC<SHA256>.authenticationCode(
                    for: input,
                    using: hmacKey
                )
            )
            var accumulated = previous

            if iterationCount > 1 {
                for _ in 2...iterationCount {
                    previous = Data(
                        HMAC<SHA256>.authenticationCode(
                            for: previous,
                            using: hmacKey
                        )
                    )
                    for index in accumulated.indices {
                        accumulated[index] ^= previous[index]
                    }
                }
            }
            derivedKey.append(accumulated)
        }

        return derivedKey.prefix(outputByteCount)
    }
}

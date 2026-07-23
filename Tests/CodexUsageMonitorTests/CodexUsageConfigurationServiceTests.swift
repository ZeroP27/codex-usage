import Foundation
import Testing
@testable import CodexUsageMonitor

struct CodexUsageConfigurationServiceTests {
    @Test
    func testPBKDF2HMACSHA256MatchesStandardVectors() throws {
        let password = Data("password".utf8)
        let salt = Data("salt".utf8)

        let oneIteration = try PBKDF2HMACSHA256.deriveKey(
            password: password,
            salt: salt,
            iterationCount: 1,
            outputByteCount: 32
        )
        let twoIterations = try PBKDF2HMACSHA256.deriveKey(
            password: password,
            salt: salt,
            iterationCount: 2,
            outputByteCount: 32
        )
        let fourThousandNinetySixIterations = try PBKDF2HMACSHA256.deriveKey(
            password: password,
            salt: salt,
            iterationCount: 4_096,
            outputByteCount: 32
        )

        #expect(
            oneIteration.hexString
                == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        )
        #expect(
            twoIterations.hexString
                == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
        )
        #expect(
            fourThousandNinetySixIterations.hexString
                == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"
        )
    }

    @Test
    func testEncryptedConfigurationRoundTripsThroughOwnerOnlyFile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = CodexUsageConfigurationService(
            iterationCount: CodexUsageConfigurationService.minimumIterationCount
        )
        let payload = try makePayload()
        let password = "correct horse battery staple"

        try service.write(
            payload,
            passphrase: password,
            to: fixture.configurationURL
        )
        let restored = try service.read(
            from: fixture.configurationURL,
            passphrase: password
        )
        let preview = service.preview(for: restored)
        let validatedAccounts = try CodexUsageAccountStore(
            applicationSupportURL: fixture.root.appendingPathComponent("app-support"),
            codexHomeURL: fixture.root.appendingPathComponent("codex-home")
        ).validateArchive(restored.managedAccounts)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.configurationURL.path
        )

        #expect(restored == payload)
        #expect(preview.createdAt == payload.createdAt)
        #expect(preview.managedAccountCount == 1)
        #expect(preview.preferences == payload.preferences)
        #expect(preview.launchAtLoginEnabled)
        #expect(validatedAccounts.accounts.count == 1)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func testEnvelopeUsesRequiredAlgorithmsIterationsAndRandomSalt() throws {
        #expect(
            CodexUsageConfigurationService().iterationCount
                == CodexUsageConfigurationService.defaultIterationCount
        )
        #expect(
            CodexUsageConfigurationService.defaultIterationCount == 600_000
        )
        let service = CodexUsageConfigurationService(
            iterationCount: CodexUsageConfigurationService.minimumIterationCount
        )
        let payload = try makePayload()
        let password = "a sufficiently long password"

        let firstData = try service.exportData(payload, passphrase: password)
        let secondData = try service.exportData(payload, passphrase: password)
        let firstEnvelope = try JSONDecoder().decode(
            CodexUsageEncryptedConfigurationEnvelope.self,
            from: firstData
        )
        let secondEnvelope = try JSONDecoder().decode(
            CodexUsageEncryptedConfigurationEnvelope.self,
            from: secondData
        )

        #expect(
            firstEnvelope.format
                == CodexUsageConfigurationService.encryptedConfigurationFormat
        )
        #expect(
            firstEnvelope.schemaVersion
                == CodexUsageConfigurationService.envelopeSchemaVersion
        )
        #expect(
            firstEnvelope.keyDerivation
                == CodexUsageConfigurationService.keyDerivationIdentifier
        )
        #expect(
            firstEnvelope.iterationCount
                == CodexUsageConfigurationService.minimumIterationCount
        )
        #expect(
            firstEnvelope.cipher
                == CodexUsageConfigurationService.cipherIdentifier
        )
        #expect(
            firstEnvelope.salt.count
                == CodexUsageConfigurationService.saltByteCount
        )
        #expect(firstEnvelope.salt != secondEnvelope.salt)
        #expect(firstEnvelope.sealedData != secondEnvelope.sealedData)
    }

    @Test
    func testWrongPasswordAndTamperedCiphertextUseSameImportError() throws {
        let service = CodexUsageConfigurationService(
            iterationCount: CodexUsageConfigurationService.minimumIterationCount
        )
        let payload = try makePayload()
        let password = "correct horse battery staple"
        let encryptedData = try service.exportData(
            payload,
            passphrase: password
        )

        try expectConfigurationError(.invalidEncryptedConfiguration) {
            _ = try service.importPayload(
                from: encryptedData,
                passphrase: "this is the wrong password"
            )
        }

        var envelope = try JSONDecoder().decode(
            CodexUsageEncryptedConfigurationEnvelope.self,
            from: encryptedData
        )
        let lastIndex = try #require(envelope.sealedData.indices.last)
        envelope.sealedData[lastIndex] ^= 0x01
        let tamperedData = try JSONEncoder().encode(envelope)

        try expectConfigurationError(.invalidEncryptedConfiguration) {
            _ = try service.importPayload(
                from: tamperedData,
                passphrase: password
            )
        }
    }

    @Test
    func testExportRejectsWeakPassphrase() throws {
        let service = CodexUsageConfigurationService(
            iterationCount: CodexUsageConfigurationService.minimumIterationCount
        )

        try expectConfigurationError(
            .weakPassphrase(
                minimumCharacters:
                    CodexUsageConfigurationService.minimumPassphraseCharacterCount
            )
        ) {
            _ = try service.exportData(
                try makePayload(),
                passphrase: "too short"
            )
        }
    }

    @Test
    func testImportRejectsOversizedFileBeforeDecoding() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let service = CodexUsageConfigurationService(
            iterationCount: CodexUsageConfigurationService.minimumIterationCount
        )
        let oversized = Data(
            count: CodexUsageConfigurationService.maximumEncryptedFileSize + 1
        )
        try oversized.write(to: fixture.configurationURL)

        try expectConfigurationError(
            .fileTooLarge(
                maximumBytes:
                    CodexUsageConfigurationService.maximumEncryptedFileSize
            )
        ) {
            _ = try service.read(
                from: fixture.configurationURL,
                passphrase: "a sufficiently long password"
            )
        }
    }

    @Test
    func testImportRejectsUnsupportedEnvelopeSchema() throws {
        let service = CodexUsageConfigurationService(
            iterationCount: CodexUsageConfigurationService.minimumIterationCount
        )
        let encryptedData = try service.exportData(
            try makePayload(),
            passphrase: "a sufficiently long password"
        )
        var envelope = try JSONDecoder().decode(
            CodexUsageEncryptedConfigurationEnvelope.self,
            from: encryptedData
        )
        envelope.schemaVersion += 1

        try expectConfigurationError(
            .unsupportedSchema(envelope.schemaVersion)
        ) {
            _ = try service.importPayload(
                from: JSONEncoder().encode(envelope),
                passphrase: "a sufficiently long password"
            )
        }
    }

    @Test
    func testIterationCountMustStayInsideAcceptedBounds() throws {
        let tooWeakService = CodexUsageConfigurationService(
            iterationCount:
                CodexUsageConfigurationService.minimumIterationCount - 1
        )
        try expectConfigurationError(.unsupportedKeyDerivationParameters) {
            _ = try tooWeakService.exportData(
                try makePayload(),
                passphrase: "a sufficiently long password"
            )
        }

        let service = CodexUsageConfigurationService(
            iterationCount: CodexUsageConfigurationService.minimumIterationCount
        )
        let encryptedData = try service.exportData(
            try makePayload(),
            passphrase: "a sufficiently long password"
        )
        var envelope = try JSONDecoder().decode(
            CodexUsageEncryptedConfigurationEnvelope.self,
            from: encryptedData
        )
        envelope.iterationCount =
            CodexUsageConfigurationService.maximumIterationCount + 1

        try expectConfigurationError(.unsupportedKeyDerivationParameters) {
            _ = try service.importPayload(
                from: JSONEncoder().encode(envelope),
                passphrase: "a sufficiently long password"
            )
        }
    }

    private func makePayload() throws -> CodexUsageConfigurationPayload {
        let idToken = try makeJWT(payload: [
            "email": "user@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account",
                "chatgpt_user_id": "user",
                "chatgpt_plan_type": "plus"
            ]
        ])
        let registryData = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "active_account_key": "user::account",
            "accounts": [[
                "account_key": "user::account",
                "chatgpt_account_id": "account",
                "chatgpt_user_id": "user",
                "email": "user@example.com",
                "alias": "",
                "plan": "plus",
                "auth_mode": "chatgpt"
            ]]
        ])
        let authData = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": "secret-access",
                "refresh_token": "secret-refresh",
                "id_token": idToken,
                "account_id": "account"
            ]
        ])

        return CodexUsageConfigurationPayload(
            createdAt: Date(timeIntervalSince1970: 1_787_040_000),
            preferences: CodexUsagePreferences(
                usageDataSource: .cliRPC,
                refreshInterval: .fifteenMinutes,
                codexExecutablePath: "/usr/local/bin/codex"
            ),
            launchAtLoginEnabled: true,
            managedAccounts: CodexManagedAccountsArchive(
                schemaVersion: 1,
                registryData: registryData,
                authSnapshots: [
                    CodexManagedAuthArchive(
                        accountKey: "user::account",
                        authData: authData
                    )
                ]
            )
        )
    }

    private func makeJWT(payload: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: [
            "alg": "none",
            "typ": "JWT"
        ])
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return "\(base64URLNoPadding(header)).\(base64URLNoPadding(payloadData)).signature"
    }

    private func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func expectConfigurationError(
        _ expected: CodexUsageConfigurationError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            #expect(Bool(false), "Expected \(expected)")
        } catch let error as CodexUsageConfigurationError {
            #expect(error == expected)
        } catch {
            #expect(Bool(false), "Expected \(expected), got \(error)")
        }
    }

    private func makeFixture() throws -> ConfigurationFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codex-usage-configuration-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return ConfigurationFixture(
            root: root,
            configurationURL: root.appendingPathComponent(
                "Codex Usage Configuration.codexusage"
            )
        )
    }
}

private struct ConfigurationFixture {
    var root: URL
    var configurationURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

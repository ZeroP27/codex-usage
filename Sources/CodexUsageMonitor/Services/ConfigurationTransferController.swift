import AppKit
import Combine
import Foundation
import OSLog
import UniformTypeIdentifiers

enum ConfigurationPassphrasePrompt: Identifiable, Equatable {
    case export(URL)
    case importFile(URL)

    var id: String {
        switch self {
        case .export(let url):
            return "export:\(url.path)"
        case .importFile(let url):
            return "import:\(url.path)"
        }
    }

    var isExport: Bool {
        if case .export = self {
            return true
        }
        return false
    }
}

struct CodexUsageConfigurationImportComparison: Equatable, Sendable {
    var existingManagedAccountCount: Int
    var existingStorageRevision: String
    var imported: CodexUsageConfigurationPreview
}

@MainActor
final class ConfigurationTransferController: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var passphrasePrompt: ConfigurationPassphrasePrompt?
    @Published private(set) var promptErrorMessage: String?
    @Published private(set) var pendingImportComparison: CodexUsageConfigurationImportComparison?
    @Published private(set) var errorMessage: String?
    @Published private(set) var successMessage: String?

    private let service: CodexUsageConfigurationService
    private let accountStore: CodexUsageAccountStore
    private var pendingImportPayload: CodexUsageConfigurationPayload?
    private weak var suspendedStore: CodexUsageStore?
    private let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "ConfigurationTransfer"
    )

    init(
        service: CodexUsageConfigurationService = CodexUsageConfigurationService(),
        accountStore: CodexUsageAccountStore = CodexUsageAccountStore()
    ) {
        self.service = service
        self.accountStore = accountStore
    }

    deinit {
        if let suspendedStore {
            Task { @MainActor in
                suspendedStore.endConfigurationTransfer()
            }
        }
    }

    var isBusy: Bool {
        isWorking || passphrasePrompt != nil || pendingImportPayload != nil
    }

    func requestExport() {
        guard !isBusy else {
            logger.info("configuration export ignored reason=transfer_busy")
            return
        }
        resetMessages()
        logger.info("configuration export file selection requested")

        let panel = NSSavePanel()
        panel.title = "Export Encrypted Configuration"
        panel.message = "Choose where to save the encrypted Codex Usage backup."
        panel.prompt = "Choose"
        panel.nameFieldStringValue = "Codex Usage Configuration.codexusage"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [Self.configurationContentType]

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            logger.info("configuration export file selection cancelled")
            return
        }

        passphrasePrompt = .export(destinationURL)
        promptErrorMessage = nil
        logger.info("configuration export destination selected path=\(destinationURL.path, privacy: .private)")
    }

    func requestImport(store: CodexUsageStore) {
        guard !isBusy else {
            logger.info("configuration import ignored reason=transfer_busy")
            return
        }
        guard store.beginConfigurationTransfer() else {
            errorMessage = "Wait for the current account operation or quota refresh to finish before importing a configuration."
            logger.info("configuration import blocked reason=store_busy")
            return
        }
        suspendedStore = store
        resetMessages()
        logger.info("configuration import file selection requested")

        let panel = NSOpenPanel()
        panel.title = "Import Encrypted Configuration"
        panel.message = "Choose a Codex Usage encrypted configuration backup."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.configurationContentType]

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let sourceURL = panel.url else {
            logger.info("configuration import file selection cancelled")
            finishImportSession()
            return
        }

        passphrasePrompt = .importFile(sourceURL)
        promptErrorMessage = nil
        logger.info("configuration import source selected path=\(sourceURL.path, privacy: .private)")
    }

    @discardableResult
    func submitExport(
        passphrase: String,
        confirmation: String,
        preferences: CodexUsagePreferences,
        launchAtLoginEnabled: Bool
    ) -> Bool {
        guard case .export(let destinationURL) = passphrasePrompt, !isWorking else {
            logger.info("configuration export password submission ignored reason=no_export_prompt_or_busy")
            return false
        }
        guard passphrase == confirmation else {
            promptErrorMessage = "The passwords do not match."
            logger.info("configuration export password rejected reason=confirmation_mismatch")
            return false
        }
        let minimumCharacterCount =
            CodexUsageConfigurationService.minimumPassphraseCharacterCount
        guard passphrase.count >= minimumCharacterCount else {
            promptErrorMessage = "Use a password with at least \(minimumCharacterCount) characters."
            logger.info("configuration export password rejected reason=too_short length=\(passphrase.count, privacy: .public)")
            return false
        }

        promptErrorMessage = nil
        isWorking = true
        logger.info("configuration export started launch_at_login=\(launchAtLoginEnabled, privacy: .public) destination=\(destinationURL.path, privacy: .private)")

        let service = self.service
        let accountStore = self.accountStore
        Task {
            do {
                let exportedAccountCount = try await Task.detached(priority: .userInitiated) {
                    let archive = try accountStore.exportArchive()
                    let payload = CodexUsageConfigurationPayload(
                        preferences: preferences,
                        launchAtLoginEnabled: launchAtLoginEnabled,
                        managedAccounts: archive
                    )
                    try service.write(payload, passphrase: passphrase, to: destinationURL)
                    return archive.authSnapshots.count
                }.value

                successMessage = "Encrypted configuration exported with \(exportedAccountCount) managed \(Self.accountWord(exportedAccountCount))."
                errorMessage = nil
                passphrasePrompt = nil
                logger.info("configuration export completed managed_account_count=\(exportedAccountCount, privacy: .public) destination=\(destinationURL.path, privacy: .private)")
            } catch {
                promptErrorMessage = error.localizedDescription
                errorMessage = nil
                logger.error("configuration export failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private) destination=\(destinationURL.path, privacy: .private)")
            }
            isWorking = false
        }
        return true
    }

    @discardableResult
    func submitImport(passphrase: String) -> Bool {
        guard case .importFile(let sourceURL) = passphrasePrompt, !isWorking else {
            logger.info("configuration import password submission ignored reason=no_import_prompt_or_busy")
            return false
        }
        guard !passphrase.isEmpty else {
            promptErrorMessage = "Enter the backup password."
            logger.info("configuration import password rejected reason=empty")
            return false
        }

        promptErrorMessage = nil
        isWorking = true
        logger.info("configuration import validation started source=\(sourceURL.path, privacy: .private)")

        let service = self.service
        let accountStore = self.accountStore
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let payload = try service.read(from: sourceURL, passphrase: passphrase)
                    let validatedArchive = try accountStore.validateArchive(payload.managedAccounts)
                    let baseline = try accountStore.loadImportBaseline()
                    let preview = service.preview(for: payload)
                    guard preview.managedAccountCount == validatedArchive.accounts.count else {
                        throw ConfigurationTransferControllerError.accountCountMismatch
                    }
                    return (
                        payload,
                        CodexUsageConfigurationImportComparison(
                            existingManagedAccountCount: baseline.snapshot.accounts.count,
                            existingStorageRevision: baseline.storageRevision,
                            imported: preview
                        )
                    )
                }.value

                pendingImportPayload = prepared.0
                pendingImportComparison = prepared.1
                passphrasePrompt = nil
                errorMessage = nil
                logger.info("configuration import validated existing_account_count=\(prepared.1.existingManagedAccountCount, privacy: .public) imported_account_count=\(prepared.1.imported.managedAccountCount, privacy: .public) imported_source=\(prepared.1.imported.preferences.usageDataSource.rawValue, privacy: .public) imported_launch_at_login=\(prepared.1.imported.launchAtLoginEnabled, privacy: .public)")
            } catch {
                promptErrorMessage = error.localizedDescription
                errorMessage = nil
                logger.error("configuration import validation failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private) source=\(sourceURL.path, privacy: .private)")
            }
            isWorking = false
        }
        return true
    }

    func commitImport(
        store: CodexUsageStore,
        launchAtLogin: LaunchAtLoginController
    ) {
        guard !isWorking,
              let payload = pendingImportPayload,
              let comparison = pendingImportComparison
        else {
            logger.info("configuration import commit ignored reason=no_validated_payload_or_busy")
            return
        }

        pendingImportPayload = nil
        pendingImportComparison = nil
        isWorking = true
        resetMessages()
        logger.info("configuration import replacement confirmed existing_account_count=\(comparison.existingManagedAccountCount, privacy: .public) imported_account_count=\(comparison.imported.managedAccountCount, privacy: .public)")

        let accountStore = self.accountStore
        Task {
            defer {
                isWorking = false
                finishImportSession()
            }
            do {
                let importedSnapshot = try await Task.detached(priority: .userInitiated) {
                    try accountStore.importArchive(
                        payload.managedAccounts,
                        replacingStorageRevision: comparison.existingStorageRevision
                    )
                }.value
                logger.info("configuration import managed accounts committed account_count=\(importedSnapshot.accounts.count, privacy: .public) active_account_present=\((importedSnapshot.activeAccountKey != nil), privacy: .public)")

                do {
                    try store.applyImportedConfiguration(
                        payload.preferences,
                        accountsSnapshot: importedSnapshot
                    )
                } catch {
                    errorMessage = "Managed accounts were replaced, but imported preferences could not be applied: \(error.localizedDescription)"
                    logger.error("configuration import partially completed phase=preferences error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                    return
                }

                do {
                    try launchAtLogin.applyImportedSetting(payload.launchAtLoginEnabled)
                    successMessage = "Configuration imported with \(importedSnapshot.accounts.count) managed \(Self.accountWord(importedSnapshot.accounts.count)). No quota refresh was run, and the current Codex auth was not changed."
                    logger.info("configuration import completed account_count=\(importedSnapshot.accounts.count, privacy: .public) launch_at_login=\(payload.launchAtLoginEnabled, privacy: .public)")
                } catch {
                    launchAtLogin.refreshStatus()
                    errorMessage = "Configuration was imported, but the login item setting could not be applied: \(error.localizedDescription)"
                    successMessage = "Managed accounts and app preferences were imported."
                    logger.error("configuration import partially completed phase=launch_at_login error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                }
            } catch {
                errorMessage = error.localizedDescription
                logger.error("configuration import commit failed error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func cancelPassphrasePrompt() {
        guard !isWorking else { return }
        let wasImport: Bool
        if case .importFile = passphrasePrompt {
            wasImport = true
        } else {
            wasImport = false
        }
        if let passphrasePrompt {
            logger.info("configuration password prompt cancelled operation=\(passphrasePrompt.isExport ? "export" : "import", privacy: .public)")
        }
        passphrasePrompt = nil
        promptErrorMessage = nil
        if wasImport {
            finishImportSession()
        }
    }

    func cancelPendingImport() {
        guard !isWorking else { return }
        if let pendingImportComparison {
            logger.info("configuration import replacement cancelled existing_account_count=\(pendingImportComparison.existingManagedAccountCount, privacy: .public) imported_account_count=\(pendingImportComparison.imported.managedAccountCount, privacy: .public)")
        }
        pendingImportPayload = nil
        pendingImportComparison = nil
        finishImportSession()
    }

    private func finishImportSession() {
        guard let suspendedStore else { return }
        self.suspendedStore = nil
        suspendedStore.endConfigurationTransfer()
        logger.info("configuration import store suspension released")
    }

    private func resetMessages() {
        errorMessage = nil
        successMessage = nil
        promptErrorMessage = nil
    }

    private static var configurationContentType: UTType {
        UTType(filenameExtension: "codexusage") ?? .data
    }

    private static func accountWord(_ count: Int) -> String {
        count == 1 ? "account" : "accounts"
    }
}

private enum ConfigurationTransferControllerError: LocalizedError {
    case accountCountMismatch

    var errorDescription: String? {
        switch self {
        case .accountCountMismatch:
            return "The validated managed account count does not match the encrypted configuration."
        }
    }
}

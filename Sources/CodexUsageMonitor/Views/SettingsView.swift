import OSLog
import SwiftUI

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: CodexUsageStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @StateObject private var configurationTransfer = ConfigurationTransferController()
    @State private var draftExecutablePath = ""
    @State private var removalCandidate: AccountUsageRow?
    @State private var isShowingRemovalConfirmation = false
    @State private var isShowingImportReview = false
    @State private var isReviewingImportedExecutable = false
    @State private var transferPassphrase = ""
    @State private var transferPassphraseConfirmation = ""
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "Settings"
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex Usage")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("Keep quota status current from the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("Refresh") {
                    Picker("Interval", selection: refreshIntervalBinding) {
                        ForEach(CodexRefreshInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(configurationTransfer.isBusy)

                    Text("Manual refresh is available from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Data Source") {
                    Picker("Source", selection: usageDataSourceBinding) {
                        ForEach(CodexUsageDataSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(storeOperationIsBusy || configurationTransfer.isBusy)

                    Text(store.usageDataSource.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if store.usageDataSource == .oauthAPI {
                        Text("Managed accounts are stored by Codex Usage. Adding an account opens Chrome incognito; adding or switching syncs that account to ~/.codex/auth.json; quota refreshes do not.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if store.usageDataSource == .oauthAPI {
                    Section("Accounts") {
                        if store.accountRows.isEmpty {
                            Text("No accounts added.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.accountRows) { row in
                                ManagedAccountSettingsRow(
                                    row: row,
                                    isBusy: storeOperationIsBusy || configurationTransfer.isBusy,
                                    remove: {
                                        Self.logger.info("remove account requested from settings key_fp=\(LogFingerprint.account(row.id), privacy: .public) key=\(row.id, privacy: .private) is_active=\(row.isActive, privacy: .public)")
                                        removalCandidate = row
                                        isShowingRemovalConfirmation = true
                                    }
                                )
                            }
                        }

                        HStack {
                            Button {
                                Self.logger.info("add account clicked")
                                store.addAccount()
                            } label: {
                                if store.isAddingAccount {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Add Account", systemImage: "plus")
                                }
                            }
                            .disabled(storeOperationIsBusy || configurationTransfer.isBusy)

                            Spacer()
                        }

                        Text("Login opens ChatGPT in your browser through codex app-server. Removed accounts are deleted from Codex Usage managed storage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if store.usageDataSource == .cliRPC {
                    Section("CLI RPC") {
                        TextField("Codex executable", text: $draftExecutablePath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(storeOperationIsBusy || configurationTransfer.isBusy)

                        HStack {
                            Button("Apply") {
                                Self.logger.info("codex executable path apply clicked path=\(draftExecutablePath, privacy: .private)")
                                store.updateCodexExecutablePath(draftExecutablePath)
                            }

                            Button("Use Default") {
                                Self.logger.info("codex executable path reset clicked")
                                store.resetCodexExecutablePath()
                                draftExecutablePath = store.codexExecutablePath
                            }

                            Spacer()
                        }
                        .disabled(storeOperationIsBusy || configurationTransfer.isBusy)

                        Text("Default search checks Codex.app, Homebrew, and PATH. CLI RPC starts a local stdio app-server for each refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Startup") {
                    Toggle("Open at Login", isOn: launchAtLoginBinding)
                        .disabled(configurationTransfer.isBusy)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: launchAtLoginStatusIcon)
                            .foregroundStyle(launchAtLoginStatusColor)
                            .frame(width: 16)

                        Text(launchAtLoginStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if launchAtLogin.status == .requiresApproval
                        || launchAtLogin.status == .unavailable
                    {
                        Button("Open Login Items Settings") {
                            Self.logger.info("open login items settings clicked status=\(launchAtLoginStatusLogLabel, privacy: .public)")
                            launchAtLogin.openSystemSettings()
                        }
                        .disabled(configurationTransfer.isBusy)
                    }

                    if let error = launchAtLogin.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Configuration Backup") {
                    HStack(spacing: 10) {
                        Button {
                            Self.logger.info("configuration export clicked")
                            configurationTransfer.requestExport()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(configurationActionsAreDisabled)

                        Button {
                            Self.logger.info("configuration import clicked")
                            configurationTransfer.requestImport(store: store)
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .disabled(configurationActionsAreDisabled)

                        Spacer()

                        if configurationTransfer.isWorking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Working...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Label {
                        Text("The encrypted backup includes app preferences and managed-account OAuth credentials. Keep its password and file private; the password cannot be recovered.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let success = configurationTransfer.successMessage {
                        Label(success, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error = configurationTransfer.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error = store.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            draftExecutablePath = store.codexExecutablePath
            launchAtLogin.refreshStatus()
        }
        .onChange(of: store.codexExecutablePath) { _, newValue in
            draftExecutablePath = newValue
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Self.logger.info("settings became active; refreshing launch at login status")
                launchAtLogin.refreshStatus()
            }
        }
        .sheet(item: passphrasePromptBinding, onDismiss: {
            clearTransferPassphrases()
            if configurationTransfer.pendingImportComparison != nil {
                Self.logger.info("configuration import replacement summary presented")
                isReviewingImportedExecutable = false
                isShowingImportReview = true
            }
        }) { prompt in
            ConfigurationPassphraseSheet(
                prompt: prompt,
                passphrase: $transferPassphrase,
                confirmation: $transferPassphraseConfirmation,
                isWorking: configurationTransfer.isWorking,
                errorMessage: configurationTransfer.promptErrorMessage,
                cancel: {
                    Self.logger.info("configuration password sheet cancel clicked operation=\(prompt.isExport ? "export" : "import", privacy: .public)")
                    configurationTransfer.cancelPassphrasePrompt()
                    clearTransferPassphrases()
                },
                submit: {
                    submitTransferPassphrase(for: prompt)
                }
            )
        }
        .confirmationDialog(
            "Remove account?",
            isPresented: $isShowingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            if let row = removalCandidate {
                Button("Remove \(row.account.displayName)", role: .destructive) {
                    Self.logger.info("remove account confirmed key_fp=\(LogFingerprint.account(row.id), privacy: .public) key=\(row.id, privacy: .private)")
                    store.removeAccount(row.id)
                    removalCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) {
                if let removalCandidate {
                    Self.logger.info("remove account cancelled key_fp=\(LogFingerprint.account(removalCandidate.id), privacy: .public) key=\(removalCandidate.id, privacy: .private)")
                }
                removalCandidate = nil
            }
        } message: {
            Text("This removes the account from Codex Usage managed storage. It does not touch Codex CLI legacy account folders.")
        }
        .sheet(isPresented: $isShowingImportReview, onDismiss: {
            if configurationTransfer.pendingImportComparison != nil,
               !configurationTransfer.isWorking
            {
                Self.logger.info("configuration import review dismissed from settings")
                configurationTransfer.cancelPendingImport()
            }
            isReviewingImportedExecutable = false
        }) {
            if let comparison = configurationTransfer.pendingImportComparison {
                ConfigurationImportReviewSheet(
                    summaryMessage: importConfirmationMessage(comparison),
                    executableApprovalMessage: importedExecutableApprovalMessage(
                        comparison
                    ),
                    requiresExecutableApproval: requiresImportedExecutableApproval(
                        comparison
                    ),
                    isReviewingExecutable: $isReviewingImportedExecutable,
                    reviewExecutable: {
                        Self.logger.info("configuration import executable review requested path=\(comparison.imported.preferences.codexExecutablePath, privacy: .private)")
                        isReviewingImportedExecutable = true
                    },
                    cancel: cancelConfigurationImportReview,
                    commit: {
                        if requiresImportedExecutableApproval(comparison) {
                            Self.logger.info("configuration import custom executable explicitly approved path=\(comparison.imported.preferences.codexExecutablePath, privacy: .private)")
                        }
                        commitConfigurationImport(comparison)
                    }
                )
            }
        }
    }

    private var storeOperationIsBusy: Bool {
        store.isRefreshing
            || store.isAddingAccount
            || store.isActivatingAccount
            || store.isRemovingAccount
    }

    private var configurationActionsAreDisabled: Bool {
        storeOperationIsBusy || configurationTransfer.isBusy
    }

    private var refreshIntervalBinding: Binding<CodexRefreshInterval> {
        Binding(
            get: { store.refreshInterval },
            set: { interval in
                Self.logger.info("refresh interval selected seconds=\(interval.rawValue, privacy: .public)")
                store.updateRefreshInterval(interval)
            }
        )
    }

    private var usageDataSourceBinding: Binding<CodexUsageDataSource> {
        Binding(
            get: { store.usageDataSource },
            set: { source in
                Self.logger.info("data source selected source=\(source.rawValue, privacy: .public)")
                store.updateUsageDataSource(source)
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isRegistered },
            set: { isEnabled in
                Self.logger.info("open at login toggle changed enabled=\(isEnabled, privacy: .public)")
                launchAtLogin.setEnabled(isEnabled)
            }
        )
    }

    private var passphrasePromptBinding: Binding<ConfigurationPassphrasePrompt?> {
        Binding(
            get: { configurationTransfer.passphrasePrompt },
            set: { prompt in
                if prompt == nil {
                    configurationTransfer.cancelPassphrasePrompt()
                    clearTransferPassphrases()
                }
            }
        )
    }

    private var launchAtLoginStatusMessage: String {
        switch launchAtLogin.status {
        case .disabled:
            return "Codex Usage will not open automatically when you sign in."
        case .enabled:
            return "Codex Usage will open automatically when you sign in."
        case .requiresApproval:
            return "Registered, but macOS requires approval in Login Items."
        case .unavailable:
            return "The login item is unavailable. Run a signed app from Applications and try again."
        }
    }

    private var launchAtLoginStatusIcon: String {
        switch launchAtLogin.status {
        case .enabled:
            return "checkmark.circle.fill"
        case .disabled:
            return "circle"
        case .requiresApproval:
            return "exclamationmark.circle.fill"
        case .unavailable:
            return "xmark.circle.fill"
        }
    }

    private var launchAtLoginStatusColor: Color {
        switch launchAtLogin.status {
        case .enabled:
            return .green
        case .disabled:
            return .secondary
        case .requiresApproval:
            return .orange
        case .unavailable:
            return .red
        }
    }

    private var launchAtLoginStatusLogLabel: String {
        switch launchAtLogin.status {
        case .enabled:
            return "enabled"
        case .disabled:
            return "disabled"
        case .requiresApproval:
            return "requires_approval"
        case .unavailable:
            return "unavailable"
        }
    }

    private func submitTransferPassphrase(for prompt: ConfigurationPassphrasePrompt) {
        let accepted: Bool
        switch prompt {
        case .export:
            Self.logger.info("configuration export password submitted length=\(transferPassphrase.count, privacy: .public)")
            accepted = configurationTransfer.submitExport(
                passphrase: transferPassphrase,
                confirmation: transferPassphraseConfirmation,
                preferences: store.preferences,
                launchAtLoginEnabled: launchAtLogin.isRegistered
            )
        case .importFile:
            Self.logger.info("configuration import password submitted length=\(transferPassphrase.count, privacy: .public)")
            accepted = configurationTransfer.submitImport(passphrase: transferPassphrase)
        }
        if accepted {
            clearTransferPassphrases()
        }
    }

    private func clearTransferPassphrases() {
        transferPassphrase = ""
        transferPassphraseConfirmation = ""
    }

    private func importConfirmationMessage(
        _ comparison: CodexUsageConfigurationImportComparison
    ) -> String {
        let imported = comparison.imported
        let startup = imported.launchAtLoginEnabled ? "On" : "Off"
        var message = """
        Managed accounts: \(comparison.existingManagedAccountCount) current, \(imported.managedAccountCount) from backup.
        Data source: \(imported.preferences.usageDataSource.title). Refresh: \(imported.preferences.refreshInterval.title). Open at Login: \(startup).
        """
        message += "\nCodex executable setting: \(imported.preferences.codexExecutablePath)\n"
        message += """

        This replaces Codex Usage managed accounts and preferences. It does not run a quota refresh during import. The current ~/.codex/auth.json file will not be changed; select a restored account explicitly if you want to switch Codex.
        """
        return message
    }

    private func requiresImportedExecutableApproval(
        _ comparison: CodexUsageConfigurationImportComparison
    ) -> Bool {
        comparison.imported.preferences.codexExecutablePath != "codex"
    }

    private func importedExecutableApprovalMessage(
        _ comparison: CodexUsageConfigurationImportComparison
    ) -> String {
        """
        The backup selects this executable:

        \(comparison.imported.preferences.codexExecutablePath)

        Codex Usage will not launch it during import. It will be launched with app-server --listen stdio:// on a later manual or automatic CLI refresh. Approve only if you trust this exact path.
        """
    }

    private func commitConfigurationImport(
        _ comparison: CodexUsageConfigurationImportComparison
    ) {
        Self.logger.info("configuration import replacement confirmed from settings existing_account_count=\(comparison.existingManagedAccountCount, privacy: .public) imported_account_count=\(comparison.imported.managedAccountCount, privacy: .public)")
        isShowingImportReview = false
        configurationTransfer.commitImport(
            store: store,
            launchAtLogin: launchAtLogin
        )
    }

    private func cancelConfigurationImportReview() {
        Self.logger.info("configuration import replacement cancelled from settings")
        configurationTransfer.cancelPendingImport()
        isShowingImportReview = false
    }
}

private struct ConfigurationImportReviewSheet: View {
    var summaryMessage: String
    var executableApprovalMessage: String
    var requiresExecutableApproval: Bool
    @Binding var isReviewingExecutable: Bool
    var reviewExecutable: () -> Void
    var cancel: () -> Void
    var commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(
                isReviewingExecutable
                    ? "Allow Imported Executable"
                    : "Replace Current Configuration?"
            )
            .font(.title3.weight(.semibold))

            ScrollView {
                Text(
                    isReviewingExecutable
                        ? executableApprovalMessage
                        : summaryMessage
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)

                if requiresExecutableApproval && !isReviewingExecutable {
                    Button("Review Executable", action: reviewExecutable)
                } else {
                    Button(
                        isReviewingExecutable
                            ? "Allow Executable and Import"
                            : "Replace and Import",
                        role: .destructive,
                        action: commit
                    )
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct ConfigurationPassphraseSheet: View {
    var prompt: ConfigurationPassphrasePrompt
    @Binding var passphrase: String
    @Binding var confirmation: String
    var isWorking: Bool
    var errorMessage: String?
    var cancel: () -> Void
    var submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(prompt.isExport ? "Encrypt Configuration Backup" : "Unlock Configuration Backup")
                    .font(.title3.weight(.semibold))

                Text(promptDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                SecureField(
                    prompt.isExport
                        ? "Password (at least \(CodexUsageConfigurationService.minimumPassphraseCharacterCount) characters)"
                        : "Backup password",
                    text: $passphrase
                )
                .textFieldStyle(.roundedBorder)
                .privacySensitive()
                .onSubmit {
                    if !prompt.isExport {
                        submit()
                    }
                }

                if prompt.isExport {
                    SecureField("Confirm password", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .privacySensitive()
                        .onSubmit {
                            submit()
                        }
                }
            }
            .disabled(isWorking)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(prompt.isExport ? "Encrypting..." : "Decrypting and validating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)

                Button(prompt.isExport ? "Export" : "Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitIsDisabled)
            }
        }
        .padding(22)
        .frame(width: 440)
        .interactiveDismissDisabled(isWorking)
    }

    private var promptDescription: String {
        switch prompt {
        case .export(let destinationURL):
            return "This backup contains managed-account OAuth credentials. Protect it with a unique password that cannot be recovered.\n\nFile: \(destinationURL.lastPathComponent)"
        case .importFile(let sourceURL):
            return "Enter the password used to encrypt this backup. Codex Usage will validate every account before showing the replacement summary.\n\nFile: \(sourceURL.lastPathComponent)"
        }
    }

    private var submitIsDisabled: Bool {
        isWorking
            || passphrase.isEmpty
            || (prompt.isExport && confirmation.isEmpty)
    }
}

private struct ManagedAccountSettingsRow: View {
    var row: AccountUsageRow
    var isBusy: Bool
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.isActive ? "person.crop.circle.fill" : "person.crop.circle")
                .foregroundStyle(row.isActive ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.account.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    Text(row.planLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(accountDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(role: .destructive) {
                remove()
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .disabled(row.isActive || isBusy)
            .help(row.isActive ? "Current account cannot be removed" : "Remove account")
        }
        .padding(.vertical, 4)
    }

    private var accountDetail: String {
        let updated = "Updated \(UsageFormatters.updatedAt(row.snapshot.updatedAt))"
        return row.isActive ? "Current - \(updated)" : updated
    }
}

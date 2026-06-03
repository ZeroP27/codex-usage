import OSLog
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: CodexUsageStore
    @State private var draftExecutablePath = ""
    @State private var removalCandidate: AccountUsageRow?
    @State private var isShowingRemovalConfirmation = false
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
                    Picker("Interval", selection: $store.refreshInterval) {
                        ForEach(CodexRefreshInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Manual refresh is available from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Data Source") {
                    Picker("Source", selection: $store.usageDataSource) {
                        ForEach(CodexUsageDataSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

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
                                    isBusy: store.isRefreshing
                                        || store.isAddingAccount
                                        || store.isActivatingAccount
                                        || store.isRemovingAccount,
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
                            .disabled(store.isAddingAccount || store.isRefreshing || store.isActivatingAccount || store.isRemovingAccount)

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

                        HStack {
                            Button("Apply") {
                                store.updateCodexExecutablePath(draftExecutablePath)
                            }

                            Button("Use Default") {
                                store.resetCodexExecutablePath()
                                draftExecutablePath = store.codexExecutablePath
                            }

                            Spacer()
                        }

                        Text("Default search checks Codex.app, Homebrew, and PATH. CLI RPC starts a local stdio app-server for each refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        }
        .onChange(of: store.codexExecutablePath) { _, newValue in
            draftExecutablePath = newValue
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

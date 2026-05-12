import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: CodexUsageStore
    @State private var draftExecutablePath = ""

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

                    Text("Manual refresh is always available from the menu bar.")
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
                        Text("OAuth API reads codex-auth accounts from ~/.codex/accounts. Token refresh writes only the account snapshot being refreshed, and syncs ~/.codex/auth.json only for the active account.")
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

                Section("Current") {
                    SettingsInfoRow(title: "Source", value: store.snapshot.sourceDescription)
                    SettingsInfoRow(title: "Updated", value: UsageFormatters.updatedAt(store.snapshot.updatedAt))
                    SettingsInfoRow(title: "Account", value: currentAccountName)
                    SettingsInfoRow(title: "Plan", value: currentPlanLabel)

                    if let error = store.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()

                Button {
                    store.refreshCurrentAccount()
                } label: {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Refresh Current")
                    }
                }
                .disabled(store.isRefreshing || store.activeUsageRow == nil)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            draftExecutablePath = store.codexExecutablePath
        }
        .onChange(of: store.codexExecutablePath) { _, newValue in
            draftExecutablePath = newValue
        }
    }

    private var currentAccountName: String {
        store.activeUsageRow?.account.displayName
            ?? store.snapshot.account?.displayName
            ?? "--"
    }

    private var currentPlanLabel: String {
        store.activeUsageRow?.planLabel
            ?? store.snapshot.account?.planLabel
            ?? "--"
    }
}

private struct SettingsInfoRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
        .font(.caption)
    }
}

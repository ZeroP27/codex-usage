import AppKit
import SwiftUI

struct MenuBarUsageView: View {
    @ObservedObject var store: CodexUsageStore
    @Environment(\.openSettings) private var openSettings
    @State private var activePanel = MenuPanel.summary

    var body: some View {
        Group {
            switch activePanel {
            case .summary:
                summaryPanel
            case .accounts:
                AccountsPanel(
                    rows: store.accountRows,
                    isRefreshingAll: store.isRefreshingAll,
                    isActivatingAccount: store.isActivatingAccount,
                    activate: store.activateAccount,
                    refreshAccount: store.refreshAccountUsage,
                    refresh: store.refresh,
                    back: { activePanel = .summary }
                )
            }
        }
        .padding(14)
        .frame(width: MenuLayout.panelWidth)
        .onAppear {
            store.refreshIfStale()
        }
        .onChange(of: store.accountRows.count) { _, count in
            if count <= 1 {
                activePanel = .summary
            }
        }
    }

    private func openSettingsWindow() {
        openSettings()
        SettingsWindowFocus.bringToFront()
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuHeaderView(isRefreshing: store.isRefreshing)

            if let row = store.activeUsageRow {
                VStack(spacing: 8) {
                    MenuQuotaCard(title: "5H", window: row.snapshot.sessionWindow)
                    MenuQuotaCard(title: "Weekly", window: row.snapshot.weeklyWindow)

                    CompactInfoRow(title: "Account", value: row.account.displayName)
                    CompactInfoRow(title: "Plan", value: row.planLabel)
                    CompactInfoRow(
                        title: "Updated",
                        value: UsageFormatters.updatedAt(row.snapshot.updatedAt)
                    )
                }
            } else if store.isRefreshing {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }

            if store.accountRows.count > 1 {
                Divider()

                SecondaryNavigationRow(
                    title: "Accounts",
                    value: accountSummaryText
                ) {
                    openAccountsPanel()
                }
            }

            if let error = store.errorMessage {
                ErrorMenuRow(message: error)
            }

            Divider()

            HStack {
                Button("Settings") {
                    openSettingsWindow()
                }
                .keyboardShortcut(.defaultAction)

                Button("Refresh") {
                    store.refreshCurrentAccount()
                }
                .disabled(store.isRefreshing || store.activeUsageRow == nil)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var accountSummaryText: String {
        "\(store.accountRows.count) accounts"
    }

    private func openAccountsPanel() {
        activePanel = .accounts
        store.refresh()
    }
}

private enum MenuPanel {
    case summary
    case accounts
}

private enum MenuLayout {
    static let panelWidth: CGFloat = 352
    static let accountRowMinHeight: CGFloat = 70
    static let accountRowSpacing: CGFloat = 6
    static let visibleAccountRows = 5

    static var accountsListMaxHeight: CGFloat {
        accountRowMinHeight * CGFloat(visibleAccountRows)
            + accountRowSpacing * CGFloat(visibleAccountRows - 1)
    }
}

@MainActor
private enum SettingsWindowFocus {
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        focusAfterDelay(0.12)
        focusAfterDelay(0.35)
    }

    private static func focusAfterDelay(_ delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            focusBestWindow()
        }
    }

    private static func focusBestWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let candidates = NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }
        let settingsWindow = candidates.first {
            $0.title.localizedCaseInsensitiveContains("settings")
                || $0.title.localizedCaseInsensitiveContains("preferences")
        } ?? candidates.first { !($0 is NSPanel) } ?? candidates.first

        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
}

private struct MenuHeaderView: View {
    var isRefreshing: Bool

    var body: some View {
        HStack {
            Text("Codex Usage")
                .font(.headline)

            Spacer()

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct AccountsPanel: View {
    var rows: [AccountUsageRow]
    var isRefreshingAll: Bool
    var isActivatingAccount: Bool
    var activate: (String) -> Void
    var refreshAccount: (String) -> Void
    var refresh: () -> Void
    var back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Back")

                Text("Accounts")
                    .font(.headline)

                Spacer()

                if isRefreshingAll {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            accountsList

            Divider()

            HStack {
                Button("Refresh All") {
                    refresh()
                }
                .disabled(isRefreshingAll)

                Spacer()

                Button("Done") {
                    back()
                }
            }
        }
    }

    @ViewBuilder
    private var accountsList: some View {
        if rows.count <= MenuLayout.visibleAccountRows {
            accountRows
        } else {
            ScrollView {
                accountRows
            }
            .frame(height: MenuLayout.accountsListMaxHeight)
        }
    }

    private var accountRows: some View {
        VStack(spacing: MenuLayout.accountRowSpacing) {
            ForEach(rows) { row in
                AccountMenuRow(
                    row: row,
                    isRefreshingAll: isRefreshingAll,
                    isActivatingAccount: isActivatingAccount,
                    activate: activate,
                    refreshAccount: refreshAccount
                )
            }
        }
    }
}

private struct SecondaryNavigationRow: View {
    var title: String
    var value: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show managed accounts")
    }
}

private struct AccountMenuRow: View {
    var row: AccountUsageRow
    var isRefreshingAll: Bool
    var isActivatingAccount: Bool
    var activate: (String) -> Void
    var refreshAccount: (String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                activate(row.id)
            } label: {
                Image(systemName: switchSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(switchColor)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(row.isActive || isActivatingAccount)
            .help(row.isActive ? "Active account" : "Switch Codex to this account")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(row.account.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(row.planLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let error = row.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    VStack(spacing: 5) {
                        AccountQuotaLine(title: "5H", window: row.snapshot.sessionWindow)
                        AccountQuotaLine(title: "Weekly", window: row.snapshot.weeklyWindow)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                refreshAccount(row.id)
            } label: {
                if row.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                }
            }
            .buttonStyle(.borderless)
            .disabled(row.isRefreshing || isRefreshingAll)
            .help("Refresh this account quota")
        }
        .padding(9)
        .frame(minHeight: MenuLayout.accountRowMinHeight)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(rowBorderColor, lineWidth: rowBorderWidth)
        )
    }

    private var rowBorderColor: Color {
        if row.isActive {
            return Color.accentColor.opacity(0.55)
        }
        return Color(nsColor: .separatorColor).opacity(0.16)
    }

    private var rowBorderWidth: CGFloat {
        row.isActive ? 1 : 0.5
    }

    private var switchSymbol: String {
        row.isActive ? "checkmark.circle.fill" : "circle"
    }

    private var switchColor: Color {
        row.isActive ? .accentColor : .secondary
    }
}

private struct AccountQuotaLine: View {
    var title: String
    var window: QuotaWindow?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            if let window {
                MenuProgressBar(window: window)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: .separatorColor).opacity(0.22))
                    .frame(height: 6)
            }

            Text(valueText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var valueText: String {
        guard let window else { return "--" }
        return UsageFormatters.percent(window.remainingPercent)
    }
}

private struct MenuQuotaCard: View {
    var title: String
    var window: QuotaWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.secondary)
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(valueText)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            if let window {
                MenuProgressBar(window: window)
            }
        }
        .font(.caption)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var valueText: String {
        guard let window else { return "--" }
        return UsageFormatters.percent(window.remainingPercent)
    }

    private var resetText: String {
        guard let window else { return "Not reported" }
        return "Resets \(UsageFormatters.resetTime(window.resetsAt))"
    }
}

private struct CompactInfoRow: View {
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
        .padding(.horizontal, 2)
    }
}

private struct MenuProgressBar: View {
    var window: QuotaWindow

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: .separatorColor).opacity(0.22))

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: progressWidth(in: proxy.size.width))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Remaining \(UsageFormatters.percent(window.remainingPercent))")
    }

    private func progressWidth(in availableWidth: CGFloat) -> CGFloat {
        let width = availableWidth * window.remainingFraction
        return window.remainingFraction > 0 ? max(width, 3) : 0
    }
}

private struct ErrorMenuRow: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(3)
            .padding(10)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

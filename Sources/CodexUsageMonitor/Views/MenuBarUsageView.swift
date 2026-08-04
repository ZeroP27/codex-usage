import AppKit
import OSLog
import SwiftUI

struct MenuBarUsageView: View {
    @ObservedObject var store: CodexUsageStore
    @Environment(\.openSettings) private var openSettings
    @State private var activePanel = MenuPanel.summary
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "MenuBar"
    )

    var body: some View {
        Group {
            switch activePanel {
            case .summary:
                summaryPanel
            case .accounts:
                AccountsPanel(
                    rows: store.accountRows,
                    isRefreshing: store.isRefreshing,
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
        .frame(width: panelWidth)
        .onAppear {
            store.refreshIfStale()
        }
        .onChange(of: store.accountRows.count) { _, count in
            if count <= 1 {
                activePanel = .summary
            }
        }
    }

    private var panelWidth: CGFloat {
        switch activePanel {
        case .summary:
            return MenuLayout.summaryPanelWidth
        case .accounts:
            return MenuLayout.accountsPanelWidth
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
                    ResetCreditsSummaryInfoRow(
                        summary: row.snapshot.resetCredits
                    )
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

            if shouldShowAccountsNavigation {
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
                    Self.logger.info("settings opened from menu bar")
                    openSettingsWindow()
                }
                .keyboardShortcut(.defaultAction)

                Button("Refresh") {
                    Self.logger.info("summary refresh clicked active_present=\((store.activeUsageRow != nil), privacy: .public)")
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
        store.accountRows.count == 1
            ? "1 account"
            : "\(store.accountRows.count) accounts"
    }

    private var shouldShowAccountsNavigation: Bool {
        store.accountRows.count > 1
            || (store.activeUsageRow == nil && !store.accountRows.isEmpty)
    }

    private func openAccountsPanel() {
        Self.logger.info("accounts panel opened row_count=\(store.accountRows.count, privacy: .public) active_present=\((store.activeUsageRow != nil), privacy: .public)")
        activePanel = .accounts
    }
}

private enum MenuPanel {
    case summary
    case accounts
}

private enum MenuLayout {
    static let summaryPanelWidth: CGFloat = 352
    static let accountsPanelWidth: CGFloat = 400
    static let accountRowMinHeight: CGFloat = 88
    static let accountResetMetadataWidth: CGFloat = 176
    static let visibleAccountRows = 5

    static var accountsListMaxHeight: CGFloat {
        accountRowMinHeight * CGFloat(visibleAccountRows)
            + CGFloat(visibleAccountRows - 1)
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
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "MenuBar"
    )
    var rows: [AccountUsageRow]
    var isRefreshing: Bool
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
                    Self.logger.info("accounts panel refresh all clicked row_count=\(rows.count, privacy: .public)")
                    refresh()
                }
                .disabled(isRefreshing || rows.isEmpty)

                Spacer()

                Button("Done") {
                    Self.logger.info("accounts panel done clicked")
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
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                AccountMenuRow(
                    row: row,
                    isRefreshing: isRefreshing,
                    isRefreshingAll: isRefreshingAll,
                    isActivatingAccount: isActivatingAccount,
                    activate: activate,
                    refreshAccount: refreshAccount
                )

                if index < rows.count - 1 {
                    Divider()
                        .padding(.leading, 38)
                }
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
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "MenuBar"
    )
    var row: AccountUsageRow
    var isRefreshing: Bool
    var isRefreshingAll: Bool
    var isActivatingAccount: Bool
    var activate: (String) -> Void
    var refreshAccount: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    Self.logger.info("account switch clicked key_fp=\(LogFingerprint.account(row.id), privacy: .public) key=\(row.id, privacy: .private) is_active=\(row.isActive, privacy: .public)")
                    activate(row.id)
                } label: {
                    Image(systemName: switchSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(switchColor)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(row.isActive || isActivatingAccount || isRefreshing)
                .help(row.isActive ? "Active account" : "Switch Codex to this account")

                Text(row.account.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)

                Text(row.planLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    Self.logger.info("account row refresh clicked key_fp=\(LogFingerprint.account(row.id), privacy: .public) key=\(row.id, privacy: .private)")
                    refreshAccount(row.id)
                } label: {
                    if row.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24, height: 22)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .frame(width: 24, height: 22)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(
                    row.isRefreshing
                        || isRefreshing
                        || isRefreshingAll
                        || isActivatingAccount
                )
                .help("Refresh this account quota")
            }

            AccountQuotaColumns {
                AccountQuotaMetric(
                    title: "5H",
                    window: row.snapshot.sessionWindow
                )
            } trailing: {
                AccountQuotaMetric(
                    title: "Weekly",
                    window: row.snapshot.weeklyWindow
                )
            }
            .padding(.leading, 28)

            if let error = row.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
                    .padding(.leading, 28)
            } else {
                HStack(spacing: 0) {
                    AccountMetadataLabel(systemImage: "calendar") {
                        Text(
                            "Weekly · \(UsageFormatters.weeklyResetTime(row.snapshot.weeklyWindow?.resetsAt))"
                        )
                        .lineLimit(1)
                        .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ResetCreditsDisclosure(
                        summary: row.snapshot.resetCredits,
                        style: .account
                    )
                    .frame(
                        width: MenuLayout.accountResetMetadataWidth,
                        alignment: .leading
                    )
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(minHeight: MenuLayout.accountRowMinHeight)
        .background(
            rowBackground,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    private var rowBackground: Color {
        row.isActive ? Color.accentColor.opacity(0.08) : .clear
    }

    private var switchSymbol: String {
        row.isActive ? "checkmark.circle.fill" : "circle"
    }

    private var switchColor: Color {
        row.isActive ? .accentColor : .secondary
    }
}

private struct AccountQuotaColumns<Leading: View, Trailing: View>: View {
    var leading: Leading
    var trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(width: 1, height: 14)

            trailing
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AccountMetadataLabel<Content: View>: View {
    var systemImage: String
    var content: Content

    init(
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2)
                .frame(width: 16, height: 14)

            content
        }
    }
}

private struct AccountQuotaMetric: View {
    var title: String
    var window: QuotaWindow?

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

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
                .frame(width: 34, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var valueText: String {
        guard let window else { return "--" }
        return UsageFormatters.percent(window.remainingPercent)
    }
}

private enum ResetCreditsDisclosureStyle: String {
    case summary
    case account
}

private struct ResetCreditsDisclosure: View {
    private static let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "MenuBar"
    )
    var summary: ResetCreditsSummary?
    var style: ResetCreditsDisclosureStyle
    @State private var isShowingDetails = false
    @State private var detailsReferenceDate = Date()

    @ViewBuilder
    var body: some View {
        if let summary, summary.availableCount > 0 {
            Button {
                detailsReferenceDate = Date()
                isShowingDetails = true
                Self.logger.info("reset credit details opened placement=\(style.rawValue, privacy: .public) available_count=\(summary.availableCount, privacy: .public) reported_count=\(summary.reportedAvailableCount, privacy: .public)")
            } label: {
                disclosureLabel
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
                ResetCreditsDetailsPopover(
                    summary: summary,
                    referenceDate: detailsReferenceDate
                )
            }
            .help("Show all reported reset credit expiration details")
            .accessibilityLabel(
                ResetCreditsPresentation.accessibilityText(summary)
            )
            .accessibilityHint(
                "Shows every reported expiration time."
            )
        } else {
            disclosureLabel
                .help(ResetCreditsPresentation.helpText(summary))
                .accessibilityLabel(
                    ResetCreditsPresentation.accessibilityText(summary)
                )
        }
    }

    @ViewBuilder
    private var disclosureLabel: some View {
        switch style {
        case .summary:
            summaryValueText
                .lineLimit(1)
                .monospacedDigit()
        case .account:
            AccountMetadataLabel(
                systemImage: ResetCreditsPresentation.symbolName
            ) {
                accountValueText
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
    }

    private var summaryValueText: Text {
        let value = Text(
            ResetCreditsPresentation.summaryValue(summary)
        )
        guard summary?.availableCount ?? 0 > 0 else {
            return value
        }
        return value
            + Text(" ")
            + Text(Image(systemName: "info.circle"))
                .font(.caption2)
                .foregroundColor(Color.secondary.opacity(0.6))
    }

    private var accountValueText: Text {
        guard let summary else {
            return Text("Reset unavailable")
                .foregroundColor(.secondary)
        }
        guard summary.availableCount > 0 else {
            return Text("No resets")
                .foregroundColor(.secondary)
        }

        let count = Text(
            UsageFormatters.resetCreditCount(summary.availableCount)
        )
        .foregroundColor(.secondary)

        guard let expiration = ResetCreditsPresentation.nearestFutureExpiration(
            summary
        ) else {
            return count
                + Text(" · expiration unknown")
                    .foregroundColor(.secondary)
        }

        let expirationColor: Color = UsageFormatters.isImminentExpiry(expiration)
            ? .orange
            : .secondary
        return count
            + Text(" · expires ")
                .foregroundColor(.secondary)
            + Text(UsageFormatters.compactDeadlineTime(expiration))
                .foregroundColor(expirationColor)
    }
}

private struct ResetCreditsDetailsPopover: View {
    var summary: ResetCreditsSummary
    var referenceDate: Date

    var body: some View {
        let expirations = summary.expirations.sorted()

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        "Reset credits",
                        systemImage: ResetCreditsPresentation.symbolName
                    )
                    .font(.headline)

                    Text(detailCoverageText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(summary.availableCount)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .accessibilityLabel(
                        UsageFormatters.resetCreditCount(
                            summary.availableCount
                        )
                    )
            }

            if expirations.contains(where: { $0 <= referenceDate }) {
                Label(
                    "This snapshot contains an expired detail. Refresh the account to update the available count.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if expirations.isEmpty {
                Label(
                    "The service did not report an expiration time.",
                    systemImage: "calendar.badge.exclamationmark"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(expirations.indices, id: \.self) { index in
                            ResetCreditExpirationDetailRow(
                                number: index + 1,
                                expiration: expirations[index],
                                referenceDate: referenceDate
                            )

                            if index < expirations.count - 1 {
                                Divider()
                                    .padding(.leading, 32)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            if missingExpirationCount > 0 || unreportedDetailCount > 0 {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    if missingExpirationCount > 0 {
                        Text(
                            "\(missingExpirationCount) reported \(missingExpirationCount == 1 ? "credit has" : "credits have") no expiration time."
                        )
                    }
                    if unreportedDetailCount > 0 {
                        Text(
                            "The service did not provide details for \(unreportedDetailCount) \(unreportedDetailCount == 1 ? "credit" : "credits")."
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var missingExpirationCount: Int {
        max(summary.reportedAvailableCount - summary.expirations.count, 0)
    }

    private var unreportedDetailCount: Int {
        max(summary.availableCount - summary.reportedAvailableCount, 0)
    }

    private var detailCoverageText: String {
        if summary.reportedAvailableCount >= summary.availableCount {
            return "All reported details"
        }
        return "\(summary.reportedAvailableCount) of \(summary.availableCount) details reported"
    }
}

private struct ResetCreditExpirationDetailRow: View {
    var number: Int
    var expiration: Date
    var referenceDate: Date

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            Image(systemName: statusSymbol)
                .font(.caption)
                .foregroundStyle(statusColor)
                .frame(width: 12)

            Text(UsageFormatters.dateTime.string(from: expiration))
                .font(.caption.monospacedDigit())
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Reset \(number), expires \(UsageFormatters.dateTime.string(from: expiration)), \(statusText)"
        )
    }

    private var hasExpired: Bool {
        expiration <= referenceDate
    }

    private var expiresSoon: Bool {
        UsageFormatters.isImminentExpiry(
            expiration,
            relativeTo: referenceDate
        )
    }

    private var statusText: String {
        if hasExpired {
            return "Expired"
        }
        if expiresSoon {
            return "Soon"
        }
        return "Available"
    }

    private var statusSymbol: String {
        if hasExpired {
            return "xmark.circle.fill"
        }
        if expiresSoon {
            return "exclamationmark.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if hasExpired {
            return .red
        }
        if expiresSoon {
            return .orange
        }
        return .secondary
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
                        .monospacedDigit()
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
        return "Reset \(UsageFormatters.resetTime(window.resetsAt))"
    }
}

@MainActor
private enum ResetCreditsPresentation {
    static let symbolName = "ticket"

    static func nearestFutureExpiration(
        _ summary: ResetCreditsSummary,
        now: Date = Date()
    ) -> Date? {
        summary.expirations.filter { $0 > now }.min()
    }

    static func summaryValue(
        _ summary: ResetCreditsSummary?,
        now: Date = Date()
    ) -> String {
        guard let summary else { return "Unavailable" }
        guard summary.availableCount > 0 else { return "None" }

        let count = UsageFormatters.resetCreditCount(summary.availableCount)
        guard let expiration = nearestFutureExpiration(summary, now: now) else {
            return "\(count) · expiration unknown"
        }
        let deadline = UsageFormatters.compactDeadlineTime(
            expiration,
            relativeTo: now
        )
        return "\(count) · expires \(deadline)"
    }

    static func helpText(
        _ summary: ResetCreditsSummary?,
        now: Date = Date()
    ) -> String {
        guard let summary else {
            return "Reset credit information is unavailable."
        }
        guard summary.availableCount > 0 else {
            return "No reset credits are available."
        }

        var lines = [
            "\(UsageFormatters.resetCreditCount(summary.availableCount)) available."
        ]
        if summary.reportedAvailableCount < summary.availableCount {
            lines.append(
                "The service reported details for \(summary.reportedAvailableCount) of \(summary.availableCount) credits."
            )
        }

        let expirations = summary.expirations.filter { $0 > now }.sorted()
        if let nearest = expirations.first {
            lines.append(
                "Nearest reported expiration: \(UsageFormatters.dateTime.string(from: nearest))."
            )
        } else {
            lines.append("No future expiration time was reported.")
        }
        return lines.joined(separator: " ")
    }

    static func accessibilityText(
        _ summary: ResetCreditsSummary?,
        now: Date = Date()
    ) -> String {
        let text = helpText(summary, now: now)
        guard summary?.availableCount ?? 0 > 0 else {
            return text
        }
        return "\(text) Activate to show every reported expiration."
    }
}

private struct ResetCreditsSummaryInfoRow: View {
    var summary: ResetCreditsSummary?

    var body: some View {
        CompactInfoRowLayout(title: "Reset credits") {
            ResetCreditsDisclosure(
                summary: summary,
                style: .summary
            )
        }
    }
}

private struct CompactInfoRow: View {
    var title: String
    var value: String
    var helpText: String? = nil

    var body: some View {
        CompactInfoRowLayout(title: title) {
            Text(value)
                .lineLimit(1)
        }
        .help(helpText ?? "\(title): \(value)")
    }
}

private struct CompactInfoRowLayout<Trailing: View>: View {
    var title: String
    var trailing: Trailing

    init(
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            trailing
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

import AppKit
import SwiftUI

struct MenuBarUsageView: View {
    @ObservedObject var store: CodexUsageStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuHeaderView(isRefreshing: store.isRefreshing)

            VStack(spacing: 8) {
                MenuQuotaCard(title: "5-hour", window: store.snapshot.sessionWindow)
                MenuQuotaCard(title: "Weekly", window: store.snapshot.weeklyWindow)

                if let account = store.snapshot.account {
                    CompactInfoRow(title: "Account", value: account.displayName)
                }

                CompactInfoRow(
                    title: "Updated",
                    value: UsageFormatters.updatedAt(store.snapshot.updatedAt)
                )
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
                    store.refresh()
                }
                .disabled(store.isRefreshing)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 310)
        .onAppear {
            store.refreshIfStale()
        }
    }

    private func openSettingsWindow() {
        openSettings()
        SettingsWindowFocus.bringToFront()
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

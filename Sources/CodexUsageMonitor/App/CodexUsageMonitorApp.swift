import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIconFactory.appIcon
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct CodexUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = CodexUsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarUsageView(store: store)
        } label: {
            Image(nsImage: AppIconFactory.menuBarIcon(
                session: store.snapshot.sessionWindow,
                weekly: store.snapshot.weeklyWindow
            ))
            .help(menuBarHelpText)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }

    private var menuBarHelpText: String {
        let sessionText = store.snapshot.sessionWindow.map {
            "5h \($0.remainingPercent.formatted(.number.precision(.fractionLength(0))))%"
        } ?? "5h --"
        let weeklyText = store.snapshot.weeklyWindow.map {
            "Weekly \($0.remainingPercent.formatted(.number.precision(.fractionLength(0))))%"
        } ?? "Weekly --"
        return "\(sessionText) remaining, \(weeklyText) remaining"
    }
}

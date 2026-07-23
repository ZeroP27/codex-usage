import Combine
import OSLog
import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var errorMessage: String?

    private let service: LaunchAtLoginServicing
    private let logger = Logger(
        subsystem: "dev.idea-space.CodexUsageMonitor",
        category: "LaunchAtLogin"
    )

    init(service: LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
        status = service.status
        logger.info("launch at login initialized status=\(Self.logLabel(self.status), privacy: .public)")
    }

    var isRegistered: Bool {
        status.isRegistered
    }

    func refreshStatus() {
        let previousStatus = status
        status = service.status
        if status != previousStatus || status == .enabled || status == .disabled {
            errorMessage = nil
        }
        logger.info("launch at login status refreshed status=\(Self.logLabel(self.status), privacy: .public)")
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try changeEnabledState(enabled, source: "settings")
        } catch {
            // The published error state is updated by changeEnabledState.
        }
    }

    func applyImportedSetting(_ enabled: Bool) throws {
        try changeEnabledState(enabled, source: "configuration_import")
    }

    func openSystemSettings() {
        logger.info("login items system settings opened")
        service.openSystemSettings()
    }

    private func changeEnabledState(_ enabled: Bool, source: String) throws {
        let currentStatus = service.status
        logger.info("launch at login change requested source=\(source, privacy: .public) enabled=\(enabled, privacy: .public) current_status=\(Self.logLabel(currentStatus), privacy: .public)")

        do {
            if enabled {
                if !currentStatus.isRegistered {
                    try service.register()
                }
            } else if currentStatus.isRegistered {
                try service.unregister()
            }

            status = service.status
            errorMessage = nil
            logger.info("launch at login change completed source=\(source, privacy: .public) requested_enabled=\(enabled, privacy: .public) status=\(Self.logLabel(self.status), privacy: .public)")
        } catch {
            status = service.status
            errorMessage = error.localizedDescription
            logger.error("launch at login change failed source=\(source, privacy: .public) requested_enabled=\(enabled, privacy: .public) status=\(Self.logLabel(self.status), privacy: .public) error_type=\(LogErrorSummary.category(error), privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    private static func logLabel(_ status: LaunchAtLoginStatus) -> String {
        switch status {
        case .disabled:
            return "disabled"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires_approval"
        case .unavailable:
            return "unavailable"
        }
    }
}

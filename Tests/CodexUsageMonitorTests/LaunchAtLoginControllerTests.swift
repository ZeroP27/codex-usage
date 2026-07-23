import Foundation
import Testing
@testable import CodexUsageMonitor

@MainActor
struct LaunchAtLoginControllerTests {
    @Test
    func enablingRegistersAndRefreshesPublishedStatus() {
        let service = LaunchAtLoginFakeService(
            status: .disabled,
            statusAfterRegister: .enabled
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        #expect(service.registerCallCount == 1)
        #expect(service.unregisterCallCount == 0)
        #expect(controller.status == .enabled)
        #expect(controller.isRegistered)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func disablingUnregistersAndRefreshesPublishedStatus() {
        let service = LaunchAtLoginFakeService(
            status: .enabled,
            statusAfterUnregister: .disabled
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 1)
        #expect(controller.status == .disabled)
        #expect(!controller.isRegistered)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func approvalRequiredIsRegisteredAndEnableIsIdempotent() {
        let service = LaunchAtLoginFakeService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 0)
        #expect(controller.status == .requiresApproval)
        #expect(controller.isRegistered)
    }

    @Test
    func disablingApprovalRequiredRegistrationUnregistersIt() {
        let service = LaunchAtLoginFakeService(
            status: .requiresApproval,
            statusAfterUnregister: .disabled
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        #expect(service.unregisterCallCount == 1)
        #expect(controller.status == .disabled)
    }

    @Test
    func disabledStateMakesDisableIdempotent() {
        let service = LaunchAtLoginFakeService(status: .disabled)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        #expect(service.registerCallCount == 0)
        #expect(service.unregisterCallCount == 0)
        #expect(controller.status == .disabled)
    }

    @Test
    func failedSettingsChangePublishesFailureAndLatestServiceStatus() {
        let service = LaunchAtLoginFakeService(
            status: .disabled,
            registerError: LaunchAtLoginTestError.registrationFailed,
            statusOnRegisterError: .requiresApproval
        )
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        #expect(service.registerCallCount == 1)
        #expect(controller.status == .requiresApproval)
        #expect(
            controller.errorMessage
                == LaunchAtLoginTestError.registrationFailed.localizedDescription
        )
    }

    @Test
    func refreshClearsResolvedErrorAfterSystemApproval() {
        let service = LaunchAtLoginFakeService(
            status: .disabled,
            registerError: LaunchAtLoginTestError.registrationFailed,
            statusOnRegisterError: .requiresApproval
        )
        let controller = LaunchAtLoginController(service: service)
        controller.setEnabled(true)
        #expect(controller.errorMessage != nil)

        service.status = .enabled
        controller.refreshStatus()

        #expect(controller.status == .enabled)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func importedSettingUsesSameMutationPath() throws {
        let service = LaunchAtLoginFakeService(
            status: .disabled,
            statusAfterRegister: .requiresApproval
        )
        let controller = LaunchAtLoginController(service: service)

        try controller.applyImportedSetting(true)

        #expect(service.registerCallCount == 1)
        #expect(controller.status == .requiresApproval)
        #expect(controller.isRegistered)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func failedImportedSettingPublishesFailureAndRethrows() {
        let service = LaunchAtLoginFakeService(
            status: .enabled,
            unregisterError: LaunchAtLoginTestError.unregistrationFailed,
            statusOnUnregisterError: .disabled
        )
        let controller = LaunchAtLoginController(service: service)

        #expect(throws: LaunchAtLoginTestError.unregistrationFailed) {
            try controller.applyImportedSetting(false)
        }
        #expect(service.unregisterCallCount == 1)
        #expect(controller.status == .disabled)
        #expect(
            controller.errorMessage
                == LaunchAtLoginTestError.unregistrationFailed.localizedDescription
        )
    }
}

@MainActor
private final class LaunchAtLoginFakeService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var statusAfterRegister: LaunchAtLoginStatus
    var statusAfterUnregister: LaunchAtLoginStatus
    var registerError: Error?
    var unregisterError: Error?
    var statusOnRegisterError: LaunchAtLoginStatus?
    var statusOnUnregisterError: LaunchAtLoginStatus?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSystemSettingsCallCount = 0

    init(
        status: LaunchAtLoginStatus,
        statusAfterRegister: LaunchAtLoginStatus = .enabled,
        statusAfterUnregister: LaunchAtLoginStatus = .disabled,
        registerError: Error? = nil,
        unregisterError: Error? = nil,
        statusOnRegisterError: LaunchAtLoginStatus? = nil,
        statusOnUnregisterError: LaunchAtLoginStatus? = nil
    ) {
        self.status = status
        self.statusAfterRegister = statusAfterRegister
        self.statusAfterUnregister = statusAfterUnregister
        self.registerError = registerError
        self.unregisterError = unregisterError
        self.statusOnRegisterError = statusOnRegisterError
        self.statusOnUnregisterError = statusOnUnregisterError
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            if let statusOnRegisterError {
                status = statusOnRegisterError
            }
            throw registerError
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            if let statusOnUnregisterError {
                status = statusOnUnregisterError
            }
            throw unregisterError
        }
        status = statusAfterUnregister
    }

    func openSystemSettings() {
        openSystemSettingsCallCount += 1
    }
}

private enum LaunchAtLoginTestError: LocalizedError, Equatable {
    case registrationFailed
    case unregistrationFailed

    var errorDescription: String? {
        switch self {
        case .registrationFailed:
            return "Registration failed for testing."
        case .unregistrationFailed:
            return "Unregistration failed for testing."
        }
    }
}

import Foundation
import ServiceManagement

struct LoginItemTests {
    private final class Service {
        var status: SMAppService.Status
        var registrationResult: SMAppService.Status = .enabled
        var unregistrationResult: SMAppService.Status = .notRegistered
        var failure: Error?
        var registrations = 0
        var unregistrations = 0
        var settingsOpened = 0

        init(_ status: SMAppService.Status) { self.status = status }

        var manager: LoginItemManager {
            LoginItemManager(readStatus: { self.status }, register: {
                self.registrations += 1
                if let failure = self.failure { throw failure }
                self.status = self.registrationResult
            }, unregister: {
                self.unregistrations += 1
                if let failure = self.failure { throw failure }
                self.status = self.unregistrationResult
            }, openSettings: { self.settingsOpened += 1 })
        }
    }

    func test_statusComesFromMacOSWithoutOptingIn() throws {
        let service = Service(.notRegistered)
        let manager = service.manager
        try expectEqual(manager.status, .notRegistered, "reading status does not opt in")
        service.status = .enabled
        try expectEqual(manager.status, .enabled, "external changes are read again, not cached as a preference")
        try expectEqual(service.registrations + service.unregistrations, 0, "status reads never change login settings")

        let state = AppUIState()
        let cases: [(SMAppService.Status, String, Bool, String)] = [
            (.notRegistered, "Disattivato", true, "Attiva avvio al login"),
            (.enabled, "Attivo", true, "Disattiva avvio al login"),
            (.requiresApproval, "Da consentire", true, "Apri Elementi login…"),
            (.notFound, "Da configurare", true, "Riprova attivazione"),
        ]
        for (status, label, canSet, actionTitle) in cases {
            state.loginItemStatus = status
            try expectEqual(state.loginItemLabel, label, "pending approval is never presented as active")
            try expectEqual(state.canSetLoginItem, canSet, "a failed lookup still offers explicit registration recovery")
            try expectEqual(state.loginItemActionTitle, actionTitle, "the next action matches the real OS state")
        }
        try expectNil(state.schedule, "login startup does not install a backup schedule")
        try expectNil(state.config, "login startup does not generate or rewrite a backup config")
    }

    func test_primaryActionActivatesInAppBeforeAnySettingsHandoff() throws {
        let state = AppUIState()
        var choices: [Bool] = []
        var settingsOpened = 0
        state.onSetLoginItem = { choices.append($0) }
        state.onRequestLoginItemSettings = { settingsOpened += 1 }

        state.requestLoginItemPrimaryAction()
        try expectEqual(choices, [true], "an off app offers activation, not an unexplained settings page")
        try expectEqual(settingsOpened, 0, "no system-settings handoff before registration")

        state.loginItemStatus = .requiresApproval
        state.requestLoginItemPrimaryAction()
        try expectEqual(choices, [true], "a pending request is not toggled off by the main action")
        try expectEqual(settingsOpened, 1, "only the explicit approval action opens settings")

        state.loginItemStatus = .enabled
        state.requestLoginItemPrimaryAction()
        try expectEqual(choices, [true, false], "an enabled app can be disabled in-app")
        try expectEqual(settingsOpened, 1, "disabling does not require a settings-page visit")

        state.loginItemStatus = .notFound
        state.requestLoginItemPrimaryAction()
        try expectEqual(choices, [true, false, true], "a failed lookup must not block an explicit registration retry")
        try expectNil(state.loginItemError, "do not invent a missing-app failure before calling macOS")
    }

    func test_failedLookupCanRetryRegistrationWithoutHidingTheState() throws {
        for result: SMAppService.Status in [.enabled, .requiresApproval] {
            let service = Service(.notFound)
            service.registrationResult = result
            let state = AppUIState()
            state.onSetLoginItem = { [weak state] enabled in
                do {
                    state?.updateLoginItemStatus(try service.manager.setEnabled(enabled))
                } catch {
                    state?.loginItemError = error.localizedDescription
                }
            }
            state.updateLoginItemStatus(service.manager.status)
            try expectEqual(state.loginItemStatus, .notFound, "a failed lookup is not silently relabelled as off or active")
            try expect(state.canSetLoginItem, "the installed app must not leave activation disabled")
            try expectEqual(service.registrations, 0, "reading the failed lookup never opts in or repairs automatically")

            state.requestLoginItemPrimaryAction()
            try expectEqual(service.registrations, 1, "the recovery button reaches the real registration boundary")
            try expectEqual(state.loginItemStatus, result, "only the observed result determines whether approval is still needed")
            try expectNil(state.loginItemError, "successful registration clears the dead end without inventing an error")
            try expectEqual(service.settingsOpened, 0, "a registration retry never opens settings automatically")
        }
    }

    func test_settingsOnlyOpenForAnActualPendingRegistration() throws {
        let service = Service(.notRegistered)
        let manager = service.manager
        for status: SMAppService.Status in [.notRegistered, .enabled, .notFound] {
            service.status = status
            try expectEqual(manager.openApprovalSettingsIfNeeded(), status, "refresh stale state instead of opening the wrong page")
            try expectEqual(service.settingsOpened, 0, "never send an unregistered or already enabled app to settings")
        }
        service.status = .requiresApproval
        try expectEqual(manager.openApprovalSettingsIfNeeded(), .requiresApproval, "opening settings is not approval")
        try expectEqual(service.settingsOpened, 1, "a registered pending item has an explicit settings action")
        try expectEqual(service.registrations + service.unregistrations, 0, "guidance never changes the user's choice")
        let state = AppUIState()
        state.updateLoginItemStatus(.requiresApproval)
        state.loginItemError = "The earlier activation was denied"
        service.status = .enabled
        state.updateLoginItemStatus(manager.openApprovalSettingsIfNeeded())
        try expectEqual(state.loginItemLabel, "Attivo", "external approval is observed without another write")
        try expectNil(state.loginItemError, "a successful external approval clears the stale failure message")
        try expectEqual(service.settingsOpened, 1, "a stale approval button no longer opens settings after consent")
    }

    func test_enableDisableAndApprovalAreIdempotent() throws {
        let cases: [(SMAppService.Status, Bool, SMAppService.Status, Int, Int)] = [
            (.notRegistered, true, .enabled, 1, 0),
            (.notRegistered, false, .notRegistered, 0, 0),
            (.enabled, true, .enabled, 0, 0),
            (.enabled, false, .notRegistered, 0, 1),
            (.requiresApproval, true, .requiresApproval, 0, 0),
            (.requiresApproval, false, .notRegistered, 0, 1),
            (.notRegistered, true, .requiresApproval, 1, 0),
            (.notFound, true, .enabled, 1, 0),
            (.notFound, true, .requiresApproval, 1, 0),
        ]
        for (initial, enabled, expected, registrations, unregistrations) in cases {
            let service = Service(initial)
            if enabled { service.registrationResult = expected }
            let manager = service.manager
            try expectEqual(try manager.setEnabled(enabled), expected, "the result is the OS state, including pending approval")
            try expectEqual(try manager.setEnabled(enabled), expected, "a repeated choice is harmless")
            try expectEqual(service.registrations, registrations, "never register twice or re-register a denied item")
            try expectEqual(service.unregistrations, unregistrations, "pending approval can also be disabled")
        }
    }

    func test_nativeErrorsAreNotReportedAsSuccess() throws {
        for initial: SMAppService.Status in [.notRegistered, .enabled, .requiresApproval, .notFound] {
            let service = Service(initial)
            let failure = NSError(domain: "LoginItemTests", code: 42,
                                  userInfo: [NSLocalizedDescriptionKey: "Registration denied"])
            service.failure = failure
            do {
                _ = try service.manager.setEnabled(initial == .notRegistered || initial == .notFound)
                try fail("a native error must reach the app's visible error handler")
            } catch let error as NSError {
                try expectEqual(error.domain, failure.domain, "preserve the original error")
                try expectEqual(error.code, failure.code, "preserve the native failure code")
            }
            try expectEqual(service.manager.status, initial, "a failed change does not invent the requested state")
        }
    }

    func test_unavailableAndUnchangedStatesFailLoudly() throws {
        let missing = Service(.notFound)
        do {
            _ = try missing.manager.setEnabled(false)
            try fail("a failed lookup cannot prove that login startup was disabled")
        } catch LoginItemManager.Failure.notFound {}
        try expectEqual(missing.registrations + missing.unregistrations, 0, "disabling after a failed lookup must not register the app")

        for initial: SMAppService.Status in [.notRegistered, .enabled, .notFound] {
            let service = Service(initial)
            service.registrationResult = initial
            service.unregistrationResult = initial
            do {
                _ = try service.manager.setEnabled(initial != .enabled)
                try fail("an API returning without applying the change is not success")
            } catch LoginItemManager.Failure.notApplied {}
        }
    }
}

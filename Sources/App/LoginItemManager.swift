import Foundation
import ServiceManagement

struct LoginItemManager {
    var readStatus: () -> SMAppService.Status = { SMAppService.mainApp.status }
    var register: () throws -> Void = { try SMAppService.mainApp.register() }
    var unregister: () throws -> Void = { try SMAppService.mainApp.unregister() }
    var openSettings: () -> Void = { SMAppService.openSystemSettingsLoginItems() }

    var status: SMAppService.Status { readStatus() }

    func setEnabled(_ enabled: Bool) throws -> SMAppService.Status {
        switch status {
        case .notRegistered:
            if enabled { try register() }
        case .enabled, .requiresApproval:
            // Re-registering an enabled or denied item is not an approval request.
            if !enabled { try unregister() }
        case .notFound:
            guard enabled else { throw Failure.notFound }
            // A failed status lookup must not block an explicit registration retry.
            try register()
        @unknown default:
            throw Failure.unknownStatus
        }

        let updated = status
        guard enabled ? (updated == .enabled || updated == .requiresApproval) : updated == .notRegistered else {
            throw Failure.notApplied
        }
        return updated
    }

    func openApprovalSettingsIfNeeded() -> SMAppService.Status {
        let current = status
        if current == .requiresApproval { openSettings() }
        return current
    }

    enum Failure: LocalizedError {
        case notFound, unknownStatus, notApplied

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "macOS non riesce a riconoscere l'avvio al login di questa app. Puoi riprovare la configurazione da questa finestra."
            case .unknownStatus:
                return "macOS restituisce uno stato di avvio al login non riconosciuto."
            case .notApplied:
                return "macOS non ha applicato la modifica. Premi Ricontrolla e riprova da questa finestra."
            }
        }
    }
}

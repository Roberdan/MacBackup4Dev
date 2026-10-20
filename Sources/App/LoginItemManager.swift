import Foundation
import ServiceManagement

struct LoginItemManager {
    var readStatus: () -> SMAppService.Status = { SMAppService.mainApp.status }
    var register: () throws -> Void = { try SMAppService.mainApp.register() }
    var unregister: () throws -> Void = { try SMAppService.mainApp.unregister() }

    var status: SMAppService.Status { readStatus() }

    func setEnabled(_ enabled: Bool) throws -> SMAppService.Status {
        switch status {
        case .notRegistered:
            if enabled { try register() }
        case .enabled, .requiresApproval:
            // Re-registering an enabled or denied item is not an approval request.
            if !enabled { try unregister() }
        case .notFound:
            throw Failure.notFound
        @unknown default:
            throw Failure.unknownStatus
        }

        let updated = status
        guard enabled ? (updated == .enabled || updated == .requiresApproval) : updated == .notRegistered else {
            throw Failure.notApplied
        }
        return updated
    }

    enum Failure: LocalizedError {
        case notFound, unknownStatus, notApplied

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "macOS non trova questa app. Avviala dalla cartella Applicazioni e riprova."
            case .unknownStatus:
                return "macOS restituisce uno stato di avvio al login non riconosciuto."
            case .notApplied:
                return "macOS non ha applicato la modifica. Controlla gli Elementi login nelle Impostazioni di Sistema."
            }
        }
    }
}

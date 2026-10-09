import Foundation

enum EjectionPhase: Equatable {
    case closingStore, ejecting, succeeded, failed(String)

    var isBusy: Bool {
        switch self {
        case .closingStore, .ejecting: return true
        case .succeeded, .failed: return false
        }
    }
}

struct EjectionFeedback {
    let disk: URL
    var phase: EjectionPhase

    var title: String {
        switch phase {
        case .closingStore: return "Chiusura del backup cifrato…"
        case .ejecting: return "Espulsione del disco…"
        case .succeeded: return "Disco espulso"
        case .failed: return "Disco non espulso"
        }
    }

    var detail: String {
        switch phase {
        case .closingStore, .ejecting: return "\(disk.lastPathComponent) · Non scollegare il disco."
        case .succeeded: return "\(disk.lastPathComponent) · Puoi scollegare il disco."
        case .failed(let reason): return reason
        }
    }
}

/// The command boundary is injectable so tests never eject a user's disk.
enum DiskEjection {
    static func run(
        disk: URL,
        store: EncryptedStore.Setup?,
        closeStore: (EncryptedStore.Setup, Bool) -> EncryptedStore.CloseResult = { EncryptedStore.closeReporting($0, force: $1) },
        isStoreOpen: (EncryptedStore.Setup) -> Bool = { EncryptedStore.isOpen($0) },
        diskutil: ([String]) -> Bool,
        processesUsing: (String) -> String,
        isMounted: (String) -> Bool = BackupEngine.isVolumeReallyMounted,
        progress: (EjectionPhase) -> Void
    ) -> EjectionPhase {
        let indexers: Set<String> = ["mds", "mds_stores", "mdworker_shared", "fseventsd",
                                     "wdavdaemon", "wdavdaemon_enterprise", "wdavdaemon_unprivileged"]
        func onlyIndexers(_ holders: String) -> Bool {
            let names = holders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return !names.isEmpty && names.allSatisfy { indexers.contains($0) }
        }
        if let store {
            progress(.closingStore)
            var result = closeStore(store, false)
            if !result.isClosed {
                let holders = processesUsing(store.mountPoint)
                if onlyIndexers(holders) { result = closeStore(store, true) }
                if isStoreOpen(store) {
                    let reason: String
                    if case .failed(let error) = result { reason = error }
                    else { reason = "Il volume risulta ancora montato." }
                    let owners = holders.isEmpty ? "Nessun processo identificato." : "Processi rilevati: \(holders)."
                    return .failed("Non riesco a chiudere il volume cifrato.\n\(reason)\n\(owners) Non scollegare il disco.")
                }
            }
        }
        progress(.ejecting)
        var success = diskutil(["eject", disk.path])
        var holders = ""
        if !success {
            holders = processesUsing(disk.path)
            if onlyIndexers(holders) { success = diskutil(["unmount", "force", disk.path]) }
        }
        if success && !isMounted(disk.path) { return .succeeded }
        return .failed(holders.isEmpty
                       ? "\(disk.lastPathComponent) è ancora collegato o in uso. Chiudi le finestre del Finder e riprova."
                       : "\(disk.lastPathComponent) è in uso da: \(holders). Chiudili e riprova.")
    }
}

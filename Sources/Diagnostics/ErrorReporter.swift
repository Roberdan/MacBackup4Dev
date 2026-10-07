import Foundation
import Darwin

enum ErrorReporter {
    /// Categories for intentional rights-protection skips and unsuccessful inspection.
    /// Kept distinct from `permission_denied`: the operator can act on a permission problem,
    /// but no local setting fixes a Purview policy, and telling him to check Full Disk Access
    /// would send him chasing a fix that does not exist.
    static let dlpSkippedCategory = "dlp_skipped"
    static let protectionSkippedCategory = "rights_managed_skipped"
    static let protectionInspectionCategory = "protection_inspection_failed"

    static func categorizeErrors(_ errors: [(path: String, error: Error)],
                                 skips: [(path: String, reason: String)] = []) -> BackupErrorFile {
        var categories: [String: (count: Int, files: [String])] = [
            "permission_denied": (0, []),
            "not_found": (0, []),
            "io_error": (0, []),
            "other": (0, []),
            protectionSkippedCategory: (0, []),
            protectionInspectionCategory: (0, [])
        ]

        for (path, error) in errors {
            let nsError = error as NSError
            let category: String

            switch nsError.code {
            case Int(EACCES), Int(EPERM):
                category = "permission_denied"
            case Int(ENOENT):
                category = "not_found"
            case Int(EIO), Int(EROFS), Int(ENOSPC):
                category = "io_error"
            default:
                if nsError.domain == NSCocoaErrorDomain {
                    switch nsError.code {
                    case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                        category = "permission_denied"
                    case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                        category = "not_found"
                    default:
                        category = "other"
                    }
                } else {
                    category = "other"
                }
            }

            var cat = categories[category]!
            cat.count += 1
            if cat.files.count < 50 {
                cat.files.append(path)
            }
            categories[category] = cat
        }

        var catInfos: [String: ErrorCategoryInfo] = [:]
        for (key, value) in categories {
            catInfos[key] = ErrorCategoryInfo(count: value.count, files: value.files)
        }

        for (category, matchingSkips) in Dictionary(grouping: skips, by: {
            $0.reason.hasPrefix("Protection inspection failed")
                ? protectionInspectionCategory : protectionSkippedCategory
        }) {
            catInfos[category] = ErrorCategoryInfo(
                count: matchingSkips.count, files: Array(matchingSkips.prefix(50).map(\.path)))
        }

        return BackupErrorFile(
            total: errors.count,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            categories: catInfos
        )
    }

    static func localizedTitle(for category: String) -> String {
        switch category {
        case "permission_denied": return "Permesso negato"
        case "not_found":         return "File non trovato"
        case "no_space":          return "Disco pieno"
        case "io_error":          return "Errore di lettura/scrittura"
        case dlpSkippedCategory:  return "Esclusi dal precedente filtro DLP"
        case protectionSkippedCategory: return "File protetti esclusi (Rights Management)"
        case protectionInspectionCategory: return "Protezione non verificabile"
        default:                  return "Errore generico"
        }
    }

    static func suggestedAction(for category: String) -> String {
        switch category {
        case "permission_denied":
            return "Apri Impostazioni → Privacy → Accesso completo al disco e verifica che MacBackup4Dev sia abilitato."
        case "not_found":
            return "Alcuni file sono stati spostati o eliminati durante il backup."
        case "no_space":
            return "Libera spazio sul disco di backup o aumenta lo spazio disponibile."
        case "io_error":
            return "Controlla la salute del disco di backup con Utility Disco."
        case dlpSkippedCategory:
            return "Esclusioni registrate dal precedente filtro Office. Il nuovo filtro distingue la protezione Rights Management dalle regole aziendali sulla copia."
        case protectionSkippedCategory:
            return "Per includerli attiva Includi file protetti (Rights Management) nella selezione del backup. Le protezioni aziendali restano attive e possono bloccare la copia."
        case protectionInspectionCategory:
            return "Impossibile verificare la protezione di alcuni file: non sono stati copiati. Controlla accessibilità e integrità dei file indicati."
        default:
            return "Apri il log per i dettagli."
        }
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/macbackup4dev/backup.log")
    }

    static func formatActionableMessage(error: BackupErrorFile) -> String {
        let dlpSkips = error.categories[dlpSkippedCategory]?.count ?? 0
        let protectionSkips = error.categories[protectionSkippedCategory]?.count ?? 0
        let inspectionSkips = error.categories[protectionInspectionCategory]?.count ?? 0
        if error.total == 0 && dlpSkips == 0 && protectionSkips == 0 && inspectionSkips == 0 {
            return "Nessun errore durante il backup."
        }

        var lines: [String] = []
        if error.total > 0 {
            lines.append("⚠ \(error.total) errori durante il backup:")
        }
        if let perm = error.categories["permission_denied"], perm.count > 0 {
            lines.append("  🔒 \(perm.count) file senza permesso — Verifica Full Disk Access in Impostazioni → Privacy")
        }
        if let notFound = error.categories["not_found"], notFound.count > 0 {
            lines.append("  ❓ \(notFound.count) file non trovati — File spostati o eliminati durante il backup")
        }
        if let io = error.categories["io_error"], io.count > 0 {
            lines.append("  💾 \(io.count) errori di lettura/scrittura — Controlla la salute del disco")
        }
        if let other = error.categories["other"], other.count > 0 {
            lines.append("  ⚙ \(other.count) altri errori")
        }
        if dlpSkips > 0 {
            lines.append("  🏢 \(dlpSkips) file esclusi dal precedente filtro DLP")
        }
        if protectionSkips > 0 {
            lines.append("  🔒 \(protectionSkips) file protetti esclusi dalle impostazioni (Rights Management)")
        }
        if inspectionSkips > 0 {
            lines.append("  ⚠ \(inspectionSkips) file non copiati: protezione non verificabile")
        }
        return lines.joined(separator: "\n")
    }
}

import Foundation

/// The one question the menu answers first: "am I protected, and since when?"
/// Built from the snapshot manifests, outside the view layer (disk I/O never happens
/// while SwiftUI renders).
struct ProtectionSummary: Equatable {
    enum Level: Equatable { case protected, attention, unprotected }
    enum DayMark: Equatable { case complete, incomplete, none }

    var level: Level
    var headline: String
    var detail: String
    var lastComplete: String?          // snapshot name
    var lastCompleteDate: Date?
    var latestIsIncomplete: Bool
    var latestReasons: [String]
    var looksLikeNewMac: Bool
    var days: [DayMark]                // oldest → newest, 14 entries
    var reposWithSavedCommits: Int
    var databasesSaved: Int

    static func build(destination: URL, now: Date = Date(), staleAfter: TimeInterval = 36 * 3600) -> ProtectionSummary {
        let all = SnapshotCatalog.list(at: destination)
        let complete = all.first { $0.state == .complete }
        let latest = all.first
        let cal = Calendar.current

        var days: [DayMark] = []
        for offset in (0..<14).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let same = all.filter { cal.isDate($0.timestamp, inSameDayAs: day) }
            if same.contains(where: { $0.state == .complete }) { days.append(.complete) }
            else if same.contains(where: { $0.state == .incomplete }) { days.append(.incomplete) }
            else if same.contains(where: { $0.state == .unverified }) { days.append(.complete) }
            else { days.append(.none) }
        }

        var s = ProtectionSummary(level: .unprotected, headline: "", detail: "", lastComplete: complete?.name,
                                  lastCompleteDate: complete?.timestamp,
                                  latestIsIncomplete: latest?.state == .incomplete,
                                  latestReasons: latest?.manifest?.incompleteReasons ?? [],
                                  looksLikeNewMac: latest?.manifest?.shrinkWarning != nil,
                                  days: days,
                                  reposWithSavedCommits: complete?.manifest?.git.filter { $0.bundle != nil }.count ?? 0,
                                  databasesSaved: complete?.manifest?.databases.filter { $0.file != nil }.count ?? 0)

        if s.looksLikeNewMac {
            s.level = .unprotected
            s.headline = "Questo Mac sembra nuovo"
            s.detail = "Ha molti meno file dell'ultimo backup completo. Pulizia in pausa: niente viene cancellato."
            return s
        }
        if let complete {
            let age = now.timeIntervalSince(complete.timestamp)
            let files = complete.manifest.map { "\($0.filesProcessed) file" } ?? ""
            s.detail = [Self.dateLabel(complete.timestamp), files, "0 errori"].filter { !$0.isEmpty }.joined(separator: " · ")
            if s.latestIsIncomplete {
                s.level = .attention
                s.headline = "Attenzione · ultimo completo \(Self.ago(age))"
                s.detail = "L'ultimo backup è incompleto: " + (s.latestReasons.first ?? "vedi i dettagli")
            } else if age > staleAfter {
                s.level = .attention
                s.headline = "Ultimo completo \(Self.ago(age))"
            } else {
                s.level = .protected
                s.headline = "Protetto · ultimo completo \(Self.ago(age))"
            }
            return s
        }
        if let unverified = all.first(where: { $0.state == .unverified }) {
            s.level = .attention
            s.headline = "Ultimo backup \(Self.ago(now.timeIntervalSince(unverified.timestamp))), non verificato"
            s.detail = "Creato da una versione precedente: non so se è completo. Il prossimo backup lo verifica."
            return s
        }
        s.headline = all.isEmpty ? "Nessun backup" : "Nessun backup completo"
        s.detail = all.isEmpty ? "Avvia il primo backup." : (s.latestReasons.first ?? "Gli ultimi backup sono incompleti.")
        return s
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 2 { return "adesso" }
        if minutes < 60 { return "\(minutes) minuti fa" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 ora fa" : "\(hours) ore fa" }
        let days = hours / 24
        return days == 1 ? "ieri" : "\(days) giorni fa"
    }

    static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "'oggi' HH:mm" : "d MMM HH:mm"
        return f.string(from: date)
    }
}

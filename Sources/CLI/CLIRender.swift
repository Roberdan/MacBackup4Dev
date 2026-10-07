import SwiftUI
import AppKit

/// Debug-only: `RustyMacBackup render-menu <out-dir>` draws the menu popover in its main
/// states to PNG files, so its layout can be checked without clicking the menu bar.
extension CLIHandler {
    @MainActor
    static func renderMenu(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        func summary(_ level: ProtectionSummary.Level, _ headline: String, _ detail: String,
                     incomplete: Bool = false) -> ProtectionSummary {
            ProtectionSummary(level: level, headline: headline, detail: detail, lastComplete: "x",
                              lastCompleteDate: now.addingTimeInterval(-7200), latestIsIncomplete: incomplete,
                              latestReasons: incomplete ? ["5 file non copiati per errore."] : [],
                              looksLikeNewMac: false,
                              days: [.none, .none, .none, .complete, .complete, .none, .complete, .none,
                                     .complete, .none, .complete, .incomplete, .complete, .complete],
                              reposWithSavedCommits: 6, databasesSaved: 3)
        }
        let cfg = try? Config.load(from: Config.defaultPath)
        let states: [(String, (AppUIState) -> Void)] = [
            ("protetto", { s in
                s.appState = .idle
                s.protection = summary(.protected, "Protetto · ultimo completo 2 ore fa", "oggi 07:42 · 171604 file · 0 errori")
            }),
            ("in-corso", { s in
                s.appState = .running
                s.protection = summary(.protected, "Protetto · ultimo completo 2 ore fa", "6 ott 22:24 · 171604 file · 0 errori")
                var st = BackupStatusFile()
                st.state = "running"; st.filesDone = 144_500; st.filesTotal = 171_000
                st.bytesPerSec = 7_300; st.etaSecs = 85
                st.currentFile = "GitHub/MirrorHR_Set/research-cloud-api/data/A13A-CB806E0D8DF4.json"
                s.status = st
            }),
            ("avvisi", { s in
                s.appState = .idle
                s.protection = summary(.attention, "Attenzione · ultimo completo ieri", "L'ultimo backup è incompleto: 5 file non copiati", incomplete: true)
                s.coverageGaps = [CoverageGap(kind: .folder, path: "~/Projects/new-app",
                                              lastModified: ISO8601DateFormatter().string(from: now), approximateBytes: 1_000_000)]
            }),
        ]
        for (name, apply) in states {
            let state = AppUIState()
            state.config = cfg
            state.cachedHasBackups = true
            state.cachedCanUndo = true
            state.scheduleLabel = "ogni 1h"
            state.onRequestScheduleMenu = {}
            apply(state)
            let view = PopoverView().environmentObject(state)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
                throw err("render failed for \(name)")
            }
            let out = (dir as NSString).appendingPathComponent("menu-\(name).png")
            try png.write(to: URL(fileURLWithPath: out))
            print("\(out)  \(Int(image.size.width))×\(Int(image.size.height)) pt")
        }
    }
}

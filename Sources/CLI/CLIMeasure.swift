import AppKit
import SwiftUI
import ServiceManagement

/// Debug-only: `MacBackup4Dev measure-menu` opens the real popover (same controller the app
/// uses) next to a small window, lets it lay out, and prints the popover size against the
/// size its content needs. A popover smaller than its content clips it.
extension CLIHandler {
    @MainActor
    static func measureMenu() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let state = AppUIState()
        state.config = ProcessInfo.processInfo.environment["MB4D_DEMO"] != nil
            ? Self.menuDemoConfig : try? Config.load(from: Config.defaultPath)
        state.appState = .diskAbsent
        state.cachedHasBackups = true
        state.cachedBackupAccessible = false
        state.cachedCanUndo = true
        state.scheduleLabel = "ogni 1h"
        state.schedule = ScheduleStatus(installed: true, intervalMinutes: 60, dailyHour: nil,
                                        slots: Array(stride(from: 0, to: 1440, by: 60)))
        state.onBattery = true
        state.onRequestScheduleMenu = {}
        state.onRequestLoginItemMenu = {}
        state.onRequestLoginItemSettings = {}
        let window = NSWindow(contentRect: NSRect(x: 200, y: 600, width: 120, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        let popover = NSPopover()
        let controller = PopoverViewController(uiState: state)
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.show(relativeTo: window.contentView!.bounds, of: window.contentView!, preferredEdge: .minY)
        func report(_ label: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let needed = controller.sizeThatFits(in: NSSize(width: 10_000, height: 10_000))
            let shown = popover.contentSize
            let ok = shown.width + 0.5 >= needed.width && shown.height + 0.5 >= needed.height
            print("\(label): popover \(Int(shown.width))×\(Int(shown.height)) · contenuto \(Int(needed.width))×\(Int(needed.height)) · \(ok ? "OK" : "TAGLIATO")")
            if let directory = ProcessInfo.processInfo.environment["MB4D_MEASURE_OUTPUT"] {
                do {
                    let output = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let view = controller.view
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw err("Cannot capture the real popover")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw err("Cannot encode the real popover")
                    }
                    try png.write(to: output.appendingPathComponent(label + ".png"))
                } catch {
                    print("Popover capture failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }
        report("disco assente")
        state.storeOpening = true
        report("apertura backup cifrato")
        state.storeOpening = false
        state.cachedBackupAccessible = true
        state.appState = .running
        var st = BackupStatusFile(); st.state = "running"; st.phase = "scanning"
        st.filesDone = 151_000; st.filesTotal = 156_000; st.scanFinished = false
        st.currentFile = "GitHub/x/y.json"; st.etaSecs = 90
        st.startedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        state.status = st
        report("scansione (totale sconosciuto)")
        st.phase = "copying"; st.scanFinished = true
        state.status = st
        report("copia (totale noto)")
        st.beginFinalizationStep("Salvo i commit: repository 123 di 456",
                                 at: Date().addingTimeInterval(-125))
        state.status = st
        report("verifica finale (nessun conto alla rovescia)")
        let finish = Date()
        state.protection = ProtectionSummary(
            level: .protected, headline: "Protetto", detail: "", lastComplete: "demo-snapshot",
            lastCompleteDate: finish.addingTimeInterval(-600), latestIsIncomplete: false,
            latestReasons: [], looksLikeNewMac: false, days: Array(repeating: .complete, count: 14),
            reposWithSavedCommits: 6, databasesSaved: 3, filesInLastComplete: 156_000,
            lastCompleteFinishedDate: finish)
        state.appState = .idle
        st.state = "idle"; st.lastResult = "complete"; st.lastSnapshot = "demo-snapshot"
        st.lastCompleteAt = ISO8601DateFormatter().string(from: finish)
        state.status = st
        report("backup terminato (non in corso)")
        state.protection?.lastCompleteFinishedDate = nil
        state.status = nil
        report("backup vecchio (ora finale sconosciuta)")
        state.protection = nil
        state.status = nil
        state.appState = .idle
        let disk = Self.menuDemoConfig.diskURL
        state.ejection = EjectionFeedback(disk: disk, phase: .closingStore)
        report("chiusura backup cifrato")
        state.ejection?.phase = .ejecting
        report("espulsione in corso")
        state.ejection?.phase = .succeeded
        state.appState = .diskAbsent
        report("disco espulso")
        state.appState = .idle
        state.ejection?.phase = .failed("Backup demo è in uso da: Finder, Terminal, Editor. Chiudili e riprova.")
        report("espulsione fallita")
        state.ejection?.phase = DiskEjection.run(
            disk: disk, store: EncryptedStore.Setup(container: "/Volumes/Backup demo/demo.sparsebundle", volume: "Demo"),
            closeStore: { _, _ in .failed("hdiutil: detach failed - Resource busy") },
            isStoreOpen: { _ in true }, diskutil: { _ in Shell.Result(status: 1, stdout: "", stderr: "") }, processesUsing: { _ in "" },
            progress: { _ in })
        report("chiusura fallita (motivo macOS)")
        state.ejection?.phase = DiskEjection.run(
            disk: disk, store: EncryptedStore.Setup(container: "/Volumes/Backup demo/demo.sparsebundle", volume: "Demo"),
            closeStore: { _, _ in .failed(String(String(repeating: "Il sistema non riesce a chiudere il volume. ", count: 8).prefix(300))) },
            isStoreOpen: { _ in true }, diskutil: { _ in Shell.Result(status: 1, stdout: "", stderr: "") }, processesUsing: { _ in "Finder, Terminal" },
            progress: { _ in })
        report("chiusura fallita (motivo lungo)")
        state.ejection?.phase = DiskEjection.run(
            disk: disk, store: EncryptedStore.Setup(container: "/Volumes/Backup demo/demo.sparsebundle", volume: "Demo"),
            closeStore: { _, _ in .failed("Unmount of disk12 failed: at least one volume could not be unmounted\n"
                + "Unmount was dissented by PID 14647 (/Applications/Microsoft Defender.app/Contents/MacOS/dlp_agent.app/Contents/MacOS/dlp_agent)") },
            isStoreOpen: { _ in true }, diskutil: { _ in Shell.Result(status: 1, stdout: "", stderr: "") }, processesUsing: { _ in "" },
            progress: { _ in })
        report("chiusura rifiutata da Defender")
        state.ejection?.phase = DiskEjection.run(
            disk: disk, store: nil,
            diskutil: { _ in Shell.Result(status: 1, stdout: "Volume could not be unmounted by process 12345", stderr: "") },
            processesUsing: { _ in "" }, isMounted: { _ in true }, progress: { _ in })
        report("espulsione fallita (motivo macOS)")
        state.ejection?.phase = DiskEjection.run(
            disk: disk, store: nil,
            diskutil: { _ in Shell.Result(status: 1, stdout: "", stderr: String(repeating: "Il sistema non riesce a espellere il disco. ", count: 10)) },
            processesUsing: { _ in "Finder, Terminal" }, isMounted: { _ in true }, progress: { _ in })
        report("espulsione fallita (motivo lungo)")
        state.ejection = nil
        state.appState = .idle
        for (status, label): (SMAppService.Status, String) in [
            (.notRegistered, "disattivato"), (.enabled, "attivo"),
            (.requiresApproval, "da consentire"), (.notFound, "non disponibile"),
        ] {
            state.loginItemStatus = status
            report("avvio al login (\(label))")
        }
        state.loginItemError = "macOS non ha applicato la modifica. Controlla gli Elementi login nelle Impostazioni di Sistema."
        report("avvio al login (errore recuperabile)")
        popover.close()
        window.close()
    }
}

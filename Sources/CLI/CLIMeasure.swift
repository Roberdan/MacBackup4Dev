import AppKit
import SwiftUI

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
        state.cachedCanUndo = true
        state.scheduleLabel = "ogni 1h"
        state.onRequestScheduleMenu = {}
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
        state.appState = .running
        var st = BackupStatusFile(); st.state = "running"; st.phase = "scanning"
        st.filesDone = 151_000; st.filesTotal = 156_000; st.scanFinished = false
        st.currentFile = "GitHub/x/y.json"; st.etaSecs = 90
        state.status = st
        report("scansione (totale sconosciuto)")
        st.phase = "copying"; st.scanFinished = true
        state.status = st
        report("copia (totale noto)")
        st.phase = "finalizing"
        state.status = st
        report("verifica finale (nessun conto alla rovescia)")
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
            isStoreOpen: { _ in true }, diskutil: { _ in false }, processesUsing: { _ in "" },
            progress: { _ in })
        report("chiusura fallita (motivo macOS)")
        state.ejection?.phase = DiskEjection.run(
            disk: disk, store: EncryptedStore.Setup(container: "/Volumes/Backup demo/demo.sparsebundle", volume: "Demo"),
            closeStore: { _, _ in .failed(String(String(repeating: "Il sistema non riesce a chiudere il volume. ", count: 8).prefix(300))) },
            isStoreOpen: { _ in true }, diskutil: { _ in false }, processesUsing: { _ in "Finder, Terminal" },
            progress: { _ in })
        report("chiusura fallita (motivo lungo)")
        popover.close()
        window.close()
    }
}

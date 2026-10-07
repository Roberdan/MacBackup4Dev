import AppKit
import SwiftUI

/// Debug-only: `RustyMacBackup measure-menu` opens the real popover (same controller the app
/// uses) next to a small window, lets it lay out, and prints the popover size against the
/// size its content needs. A popover smaller than its content clips it.
extension CLIHandler {
    @MainActor
    static func measureMenu() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let state = AppUIState()
        state.config = try? Config.load(from: Config.defaultPath)
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
        }
        report("disco assente")
        state.appState = .running
        var st = BackupStatusFile(); st.state = "running"; st.filesDone = 50_000; st.filesTotal = 170_000
        st.currentFile = "GitHub/x/y.json"; st.etaSecs = 90
        state.status = st
        report("backup in corso (dopo il cambio)")
        popover.close()
        window.close()
    }
}

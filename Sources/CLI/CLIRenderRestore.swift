import AppKit
import SwiftUI

/// Debug-only: `MacBackup4Dev render-restore <backup-dir> <out-dir>` opens the real
/// "Ripristina → Nuovo Mac" window on a backup folder and saves it as PNG. Read-only.
extension CLIHandler {
    @MainActor
    static func renderRestore(backup: String, to dir: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = RestoreCenterModel(destination: URL(fileURLWithPath: backup), config: nil)
        model.tab = .newMac
        let wc = RestoreCenterWindowController(model: model)
        wc.window?.setContentSize(NSSize(width: 760, height: 1100))
        wc.showWindow(nil)
        model.load()
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        wait(1.5)
        model.loadStages()
        let deadline = Date().addingTimeInterval(60)
        while (model.stages.isEmpty || model.installedPackages.isEmpty) && Date() < deadline { wait(0.3) }
        model.showPackages = true
        model.packageFilter = "post"
        wait(1.5)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let view = wc.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("nuovo-mac.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
        wc.close()
    }
}

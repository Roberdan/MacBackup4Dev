import AppKit
import SwiftUI

/// Debug-only: `MacBackup4Dev render-onboarding <dir>` opens the real first-launch window
/// (real scan of this Mac), steps through it and saves each step as PNG. Uses AppKit's own
/// drawing (cacheDisplay), so lists and buttons look as on screen. Writes nothing else.
extension CLIHandler {
    @MainActor
    static func renderOnboarding(to dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = OnboardingModel()
        let wc = OnboardingWindowController(model: model)
        wc.showWindow(nil)
        func snap(_ name: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            guard let view = wc.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("onboarding-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        snap("1-benvenuto")
        model.startScan()
        let deadline = Date().addingTimeInterval(30)
        while model.step != .choose && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        snap("2-scelta")
        model.step = .disk; snap("3-disco")
        model.step = .schedule; snap("4-frequenza")
        model.step = .summary; snap("5-riepilogo")
        wc.close()
    }
}

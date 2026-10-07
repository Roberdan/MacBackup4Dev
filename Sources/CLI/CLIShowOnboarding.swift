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
        if ProcessInfo.processInfo.environment["MB4D_DEMO"] != nil {
            // Sample data only: README screenshots never show a real Mac.
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            model.existingBackups = [("Backup", URL(fileURLWithPath: "/Volumes/Backup/MacBackup4Dev"), Array(repeating: "s", count: 48))]
            snap("1-benvenuto")
            model.scan = demoScan()
            model.selected = model.scan.defaultSelection
            model.step = .choose
        } else {
            snap("1-benvenuto")
            model.startScan()
        }
        let deadline = Date().addingTimeInterval(30)
        while model.step != .choose && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        snap("2-scelta")
        model.step = .disk; snap("3-disco")
        model.step = .schedule; snap("4-frequenza")
        model.step = .summary; model.password = "una frase"; model.confirm = "una frase"; snap("5-riepilogo")
        wc.close()
        // The "Backup cifrati" window, with sample credentials.
        let enc = EncryptionSetupModel(disk: URL(fileURLWithPath: "/Volumes/Backup"), baseConfig: { nil })
        let ewc = EncryptionSetupWindowController(model: enc)
        ewc.showWindow(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        enc.credentials = [DevItem(id: "~/.ssh", name: ".ssh", paths: ["~/.ssh"], sensitive: true),
                           DevItem(id: "~/.config/gh", name: "gh", paths: ["~/.config/gh"], sensitive: true)]
        enc.chosenCredentials = ["~/.ssh", "~/.config/gh"]
        enc.password = "una frase che ricordo"; enc.confirm = "una frase che ricordo"
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if let view = ewc.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("cifratura.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
        ewc.close()
    }

    static func demoScan() -> DevScan {
        func item(_ path: String, _ name: String? = nil, _ detail: String? = nil, secret: Bool = false) -> DevItem {
            DevItem(id: path, name: name ?? path, paths: [path], detail: detail ?? path, sensitive: secret)
        }
        var scan = DevScan()
        scan.groups = [
            DevGroup(id: "progetti", title: "Progetti e repository", symbol: "folder.badge.gearshape", items: [
                item("~/Developer", nil, "12 repository, con le modifiche non ancora salvate su GitHub"),
                item("~/GitHub", nil, "23 repository, con le modifiche non ancora salvate su GitHub")]),
            DevGroup(id: "shell", title: "Terminale e shell", symbol: "terminal", items: [
                item("~/.zshrc", "zsh", "~/.zshrc, ~/.zprofile, ~/.zsh_history"),
                item("~/.warp", "Warp"), item("~/.config/starship.toml", "starship"), item("~/.tmux.conf", "tmux")]),
            DevGroup(id: "git", title: "Git e SSH", symbol: "arrow.triangle.branch", items: [
                item("~/.gitconfig", "Git config"), item("~/.ssh/config", "SSH config")]),
            DevGroup(id: "editor", title: "Editor e IDE", symbol: "chevron.left.forwardslash.chevron.right", items: [
                item("~/Library/Application Support/Code/User/settings.json", "VS Code settings"),
                item("~/.config/nvim", "nvim"), item("~/.config/zed", "Zed")]),
            DevGroup(id: "ai", title: "Assistenti AI", symbol: "sparkles", items: [
                item("~/.claude", ".claude"), item("~/.copilot", ".copilot"), item("~/.codex", ".codex")]),
            DevGroup(id: "database", title: "Database", symbol: "cylinder.split.1x2", items: [
                DevItem(id: "postgres:shop", name: "shop", paths: [], detail: "Postgres locale, copiato con pg_dump", sensitive: false)]),
            DevGroup(id: "credenziali", title: "Credenziali (una per una)", symbol: "key", items: [
                item("~/.ssh", ".ssh", secret: true), item("~/.config/gh", "gh", secret: true)]),
        ]
        scan.toolchains = [DevToolchain(name: "Homebrew", detail: "142 programmi, 18 app"),
                           DevToolchain(name: "Node.js", detail: "trovato"), DevToolchain(name: "Rust", detail: "trovato")]
        return scan
    }
}

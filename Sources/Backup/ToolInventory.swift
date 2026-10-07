import Foundation

/// The programs of the old Mac, read from the snapshot's `_environment/` (4.0): Homebrew's
/// Brewfile (taps, command-line programs, apps, App Store apps, VS Code extensions) plus the
/// lists of global npm / uv / pipx / cargo packages. On a new Mac each one is offered with
/// its own checkbox and installed one at a time: one failure never stops the others.
enum ToolInventory {
    struct Package: Identifiable, Hashable {
        enum Kind: String, CaseIterable {
            case tap, brew, cask, mas, vscode, npm, uv, pipx, cargo

            var title: String {
                switch self {
                case .tap: return "Sorgenti Homebrew (tap)"
                case .brew: return "Programmi da riga di comando (Homebrew)"
                case .cask: return "App (Homebrew)"
                case .mas: return "App dell'App Store"
                case .vscode: return "Estensioni VS Code"
                case .npm: return "Pacchetti npm globali"
                case .uv: return "Strumenti Python (uv)"
                case .pipx: return "Strumenti Python (pipx)"
                case .cargo: return "Programmi Rust (cargo)"
                }
            }
        }
        let kind: Kind
        let name: String
        /// App Store id (mas only).
        var storeID: String? = nil
        var id: String { kind.rawValue + ":" + name }
    }

    // MARK: - Reading the snapshot

    static func packages(snapshot: URL) -> [Package] {
        let env = snapshot.appendingPathComponent("_environment")
        var out: [Package] = []
        if let brewfile = try? String(contentsOf: env.appendingPathComponent("Brewfile"), encoding: .utf8) {
            out.append(contentsOf: parseBrewfile(brewfile))
        }
        func lines(_ file: String) -> [String] {
            ((try? String(contentsOf: env.appendingPathComponent(file), encoding: .utf8)) ?? "")
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        // VS Code extensions: from the Brewfile when it lists them, otherwise from the list file.
        if !out.contains(where: { $0.kind == .vscode }) {
            out.append(contentsOf: lines("vscode-extensions.txt").map { Package(kind: .vscode, name: $0) })
        }
        out.append(contentsOf: lines("npm-global.txt").map { Package(kind: .npm, name: $0) })
        out.append(contentsOf: lines("uv-tools.txt").map { Package(kind: .uv, name: $0) })
        out.append(contentsOf: lines("pipx.txt").map { Package(kind: .pipx, name: $0) })
        out.append(contentsOf: lines("cargo-install.txt").map { Package(kind: .cargo, name: $0) })
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    /// `brew bundle dump` lines: tap "x", brew "x", cask "x", mas "Name", id: 123, vscode "x".
    static func parseBrewfile(_ text: String) -> [Package] {
        var out: [Package] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let space = line.firstIndex(of: " ") else { continue }
            let word = String(line[..<space])
            guard let first = line.firstIndex(of: "\""),
                  let close = line[line.index(after: first)...].firstIndex(of: "\"") else { continue }
            let name = String(line[line.index(after: first)..<close])
            switch word {
            case "tap": out.append(Package(kind: .tap, name: name))
            case "brew": out.append(Package(kind: .brew, name: name))
            case "cask": out.append(Package(kind: .cask, name: name))
            case "vscode": out.append(Package(kind: .vscode, name: name))
            case "mas":
                let id = line.range(of: "id:").map { line[$0.upperBound...].trimmingCharacters(in: .whitespaces) }
                    .map { String($0.prefix { $0.isNumber }) }
                if let id, !id.isEmpty { out.append(Package(kind: .mas, name: name, storeID: id)) }
            default: continue
            }
        }
        return out
    }

    /// `uv tool list`: "ruff v0.6.0" lines, executables on indented "- ruff" lines.
    static func parseUVToolList(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard let c = line.first, c != "-", c != " " else { return nil }
            return line.split(separator: " ").first.map(String.init)
        }
    }

    /// `cargo install --list`: "ripgrep v14.1.0:" lines, binaries on indented lines.
    static func parseCargoInstallList(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard let c = line.first, c != " " else { return nil }
            return line.split(separator: " ").first.map(String.init)
        }
    }

    // MARK: - On the new Mac

    struct Prerequisite: Identifiable {
        let id: String
        let title: String
        let ok: Bool
        let hint: String
    }

    static var brew: String? { Shell.find(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) }

    /// What must be there before programs can be installed.
    static func prerequisites() -> [Prerequisite] {
        let clt = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10).ok
        return [
            Prerequisite(id: "clt", title: "Strumenti per sviluppatori di Apple (git, compilatori)", ok: clt,
                         hint: clt ? "installati" : "Si installano dalla finestra di Apple: ci vogliono alcuni minuti."),
            Prerequisite(id: "brew", title: "Homebrew", ok: brew != nil,
                         hint: brew != nil ? "installato" : "Si installa nel Terminale con il comando ufficiale: chiede la password del Mac."),
        ]
    }

    static let homebrewInstallCommand =
        "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    /// Starts the installation of a missing prerequisite; the user finishes it in Apple's
    /// window or in Terminal (both ask for confirmation or the password).
    static func startPrerequisite(_ id: String) {
        switch id {
        case "clt":
            _ = Shell.run("/usr/bin/xcode-select", ["--install"], timeout: 20)
        case "brew":
            let script = "tell application \"Terminal\"\nactivate\ndo script \"\(homebrewInstallCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
            _ = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 20)
        default: break
        }
    }

    /// Which of `packages` are already installed (one query per tool, not per package).
    static func installed(_ packages: [Package]) -> Set<String> {
        var out = Set<String>()
        let kinds = Set(packages.map(\.kind))
        func names(_ exe: String?, _ args: [String], parse: (String) -> [String] = { $0.split(separator: "\n").map(String.init) }) -> Set<String> {
            guard let exe else { return [] }
            let r = Shell.run(exe, args, timeout: 120, environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
            return r.ok ? Set(parse(r.stdout).map { $0.trimmingCharacters(in: .whitespaces) }) : []
        }
        let home = NSHomeDirectory()
        if kinds.contains(.brew) { names(brew, ["list", "--formula", "-1"]).forEach { out.insert("brew:" + $0) } }
        if kinds.contains(.cask) { names(brew, ["list", "--cask", "-1"]).forEach { out.insert("cask:" + $0) } }
        if kinds.contains(.tap) { names(brew, ["tap"]).forEach { out.insert("tap:" + $0) } }
        if kinds.contains(.vscode) {
            names(codeCLI, ["--list-extensions"]).forEach { out.insert("vscode:" + $0.lowercased()) }
        }
        if kinds.contains(.uv) {
            names(Shell.find(["/opt/homebrew/bin/uv", home + "/.local/bin/uv"]), ["tool", "list"], parse: parseUVToolList).forEach { out.insert("uv:" + $0) }
        }
        if kinds.contains(.cargo) {
            names(Shell.find([home + "/.cargo/bin/cargo"]), ["install", "--list"], parse: parseCargoInstallList).forEach { out.insert("cargo:" + $0) }
        }
        return out
    }

    static func isInstalled(_ p: Package, in installed: Set<String>) -> Bool {
        p.kind == .vscode ? installed.contains("vscode:" + p.name.lowercased()) : installed.contains(p.id)
    }

    /// VS Code's command-line tool, wherever the app is (also in a folder of Applications).
    static var codeCLI: String? {
        let bundled = "Visual Studio Code.app/Contents/Resources/app/bin/code"
        var candidates = ["/Applications/" + bundled]
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [] where !dir.hasSuffix(".app") {
            candidates.append("/Applications/\(dir)/" + bundled)
        }
        candidates += ["/opt/homebrew/bin/code", "/usr/local/bin/code", NSHomeDirectory() + "/.local/bin/code"]
        return Shell.find(candidates)
    }

    /// The command that installs one package, or nil (with the reason) when its tool is missing.
    static func command(for p: Package) -> (exe: String, args: [String])? {
        let home = NSHomeDirectory()
        // A name read from a file is never allowed to look like an option.
        guard !p.name.hasPrefix("-"), !p.name.isEmpty else { return nil }
        switch p.kind {
        case .tap: return brew.map { ($0, ["tap", p.name]) }
        case .brew: return brew.map { ($0, ["install", p.name]) }
        case .cask: return brew.map { ($0, ["install", "--cask", p.name]) }
        case .mas:
            guard let id = p.storeID, let mas = Shell.find(["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]) else { return nil }
            return (mas, ["install", id])
        case .vscode: return codeCLI.map { ($0, ["--install-extension", p.name]) }
        case .npm: return Shell.find(["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]).map { ($0, ["install", "-g", p.name]) }
        case .uv: return Shell.find(["/opt/homebrew/bin/uv", home + "/.local/bin/uv"]).map { ($0, ["tool", "install", p.name]) }
        case .pipx: return Shell.find(["/opt/homebrew/bin/pipx", home + "/.local/bin/pipx"]).map { ($0, ["install", p.name]) }
        case .cargo: return Shell.find([home + "/.cargo/bin/cargo"]).map { ($0, ["install", p.name]) }
        }
    }

    static func missingToolHint(_ kind: Package.Kind) -> String {
        switch kind {
        case .tap, .brew, .cask: return "manca Homebrew"
        case .mas: return "manca mas (brew install mas) o l'accesso all'App Store"
        case .vscode: return "manca VS Code"
        case .npm: return "manca Node.js (brew install node)"
        case .uv: return "manca uv (brew install uv)"
        case .pipx: return "manca pipx (brew install pipx)"
        case .cargo: return "manca Rust (rustup)"
        }
    }

    /// Installs the chosen packages in a safe order (taps, then programs, then the rest),
    /// one at a time. Returns (installed, failed).
    @discardableResult
    static func install(_ packages: [Package], sink: ((String) -> Void)? = nil) -> (ok: Int, failed: Int) {
        let order = Package.Kind.allCases
        var ok = 0, failed = 0
        for p in packages.sorted(by: { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }) {
            guard let cmd = command(for: p) else {
                sink?("  ✗ \(p.name): \(missingToolHint(p.kind))"); failed += 1; continue
            }
            let r = Shell.run(cmd.exe, cmd.args, timeout: 3600,
                              environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "NONINTERACTIVE": "1"])
            if r.ok { ok += 1; sink?("  ✓ \(p.name)") } else {
                failed += 1
                let why = (r.stderr.split(separator: "\n").last.map(String.init) ?? "codice \(r.status)").prefix(160)
                sink?("  ✗ \(p.name): \(why)")
            }
        }
        return (ok, failed)
    }
}

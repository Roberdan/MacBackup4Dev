import Foundation

/// Machine identity for backup snapshots.
struct MachineID: Codable {
    let hostname: String
    let serialNumber: String
    let macOSVersion: String
    let arch: String
    let timestamp: String
    /// Home folder of the Mac that made the snapshot (4.1): a new Mac with another user name
    /// rewrites it in restored configuration files (HomeRewrite). nil in older snapshots.
    var home: String? = nil
}

/// Captures a portable snapshot of the dev environment before each backup.
/// Generates metadata.json, Brewfile, app list, macOS info, and a restore script.
enum EnvironmentSnapshot {
    static func capture(to destURL: URL) {
        let envDir = destURL.appendingPathComponent("_environment")
        try? FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)

        writeMetadata(to: destURL)
        captureBrewfile(to: envDir)
        captureSystemInfo(to: envDir)
        captureAppList(to: envDir)
        captureVSCodeExtensions(to: envDir)
        capturePackageLists(to: envDir)
        copyAppBinary(to: envDir)
        generateRestoreScript(to: envDir)

    }

    /// The app at the top of the physical backup disk, NOT encrypted, so a new Mac can
    /// reinstall it straight from the disk (decided 2026-10-07). Called at launch, when the
    /// disk is attached and after each backup; copies only when the version differs.
    static func refreshRecoveryApp(onDisk disk: URL) {
        guard let appURL = findAppBundle(), FileManager.default.isWritableFile(atPath: disk.path) else { return }
        refreshRecoveryApp(from: appURL, in: disk)
    }

    /// Puts the running app at `<backup folder>/MacBackup4Dev.app` when that copy is missing or
    /// of another version (copy beside, then rename: never a half copy), and removes this
    /// app's older copies and installers (same bundle id, older names) from that folder.
    static func refreshRecoveryApp(from appURL: URL, in root: URL) {
        let fm = FileManager.default
        let target = root.appendingPathComponent("\(AppIdentity.name).app")
        // Info.plist read from disk: Bundle(url:) caches, and would report a replaced copy's old version.
        func info(_ app: URL, _ key: String) -> String? {
            NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?[key] as? String
        }
        let mine = info(appURL, "CFBundleShortVersionString")
        let there = info(target, "CFBundleShortVersionString")
        if mine != nil, mine != there {
            let staged = root.appendingPathComponent(".\(AppIdentity.name)-new.app")
            try? fm.removeItem(at: staged)
            do {
                try fm.copyItem(at: appURL, to: staged)
                try? fm.removeItem(at: target)
                try fm.moveItem(at: staged, to: target)
                Log.info("Recovery app on the backup disk updated to \(mine ?? "?")")
            } catch {
                try? fm.removeItem(at: staged)
                Log.error("Recovery app not updated: \(error.localizedDescription)")
                return
            }
        }
        // Older copies of this app and their installers: one current copy is enough.
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let url = root.appendingPathComponent(name)
            if name == "\(AppIdentity.legacyName).app",
               info(url, "CFBundleIdentifier") == AppIdentity.bundleID {
                try? fm.removeItem(at: url)
            } else if name.hasSuffix(".pkg"),
                      name.hasPrefix(AppIdentity.legacyName + "-") || name.hasPrefix(AppIdentity.name + "-") {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Write machine identity to snapshot root as metadata.json
    private static func writeMetadata(to snapshotDir: URL) {
        let meta = MachineID(
            hostname: ProcessInfo.processInfo.hostName,
            serialNumber: serialNumber(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            arch: machineArch(),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            home: NSHomeDirectory()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: snapshotDir.appendingPathComponent("metadata.json"), options: .atomic)
    }

    /// Read metadata from a snapshot directory (returns nil if not present).
    static func readMetadata(from snapshotDir: URL) -> MachineID? {
        let url = snapshotDir.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MachineID.self, from: data)
    }

    /// Get this machine's serial number via IOKit.
    private static func serialNumber() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "unknown" }
        defer { IOObjectRelease(service) }
        let key = kIOPlatformSerialNumberKey as CFString
        guard let serialRef = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0) else {
            return "unknown"
        }
        return serialRef.takeRetainedValue() as? String ?? "unknown"
    }

    private static func captureBrewfile(to dir: URL) {
        // Use brew directly (not via env/shell) to avoid sourcing .zshrc
        let brewPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew/bin/brew" : "/usr/local/bin/brew"
        guard FileManager.default.fileExists(atPath: brewPath) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = ["bundle", "dump", "--file=-", "--force"]
        // Clean environment to avoid triggering dotfile managers
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if !data.isEmpty {
                try data.write(to: dir.appendingPathComponent("Brewfile"))
            }
        } catch {}
    }

    private static func captureSystemInfo(to dir: URL) {
        var info: [String] = []
        info.append("# Environment Snapshot")
        info.append("# Generated: \(ISO8601DateFormatter().string(from: Date()))")
        info.append("")

        // macOS version
        let pv = ProcessInfo.processInfo
        info.append("macOS: \(pv.operatingSystemVersionString)")
        info.append("Host: \(pv.hostName)")
        info.append("Arch: \(machineArch())")
        info.append("")

        // Shell
        info.append("SHELL: \(ProcessInfo.processInfo.environment["SHELL"] ?? "unknown")")
        info.append("")

        // Homebrew prefix
        let brewPrefix = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            ? "/opt/homebrew" : "/usr/local"
        info.append("Homebrew: \(brewPrefix)")

        let output = info.joined(separator: "\n")
        try? output.write(to: dir.appendingPathComponent("system-info.txt"),
                          atomically: true, encoding: .utf8)
    }

    private static func captureAppList(to dir: URL) {
        let fm = FileManager.default
        var apps: [String] = []
        // Apps grouped in folders (/Applications/Dev, /Applications/AI) count too.
        if let contents = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for name in contents.sorted() {
                if name.hasSuffix(".app") { apps.append(String(name.dropLast(4))); continue }
                var isDir: ObjCBool = false
                guard !name.hasPrefix("."), fm.fileExists(atPath: "/Applications/" + name, isDirectory: &isDir), isDir.boolValue,
                      let inner = try? fm.contentsOfDirectory(atPath: "/Applications/" + name) else { continue }
                apps.append(contentsOf: inner.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) })
            }
        }
        let output = apps.joined(separator: "\n")
        try? output.write(to: dir.appendingPathComponent("installed-apps.txt"),
                          atomically: true, encoding: .utf8)
    }

    private static func captureVSCodeExtensions(to dir: URL) {
        // VS Code
        captureCommandOutput(
            cmd: ToolInventory.codeCLI ?? "/usr/local/bin/code", altCmd: "/opt/homebrew/bin/code",
            args: ["--list-extensions"],
            to: dir.appendingPathComponent("vscode-extensions.txt"))
        // Cursor
        captureCommandOutput(
            cmd: "/usr/local/bin/cursor", altCmd: "/opt/homebrew/bin/cursor",
            args: ["--list-extensions"],
            to: dir.appendingPathComponent("cursor-extensions.txt"))
    }

    /// Global packages installed outside Homebrew, one name per line, so a new Mac can
    /// offer to reinstall them one by one (4.0).
    static func capturePackageLists(to dir: URL) {
        let home = NSHomeDirectory()
        func run(_ candidates: [String], _ args: [String]) -> String? {
            guard let exe = Shell.find(candidates) else { return nil }
            let r = Shell.run(exe, args, timeout: 60,
                              environment: ["HOME": home, "PATH": "/opt/homebrew/bin:/usr/local/bin:\(home)/.cargo/bin:\(home)/.local/bin:/usr/bin:/bin"])
            // npm ls exits 1 on a harmless peer-dependency warning: keep the output anyway.
            return r.ok || !r.stdout.isEmpty ? r.stdout : nil
        }
        func save(_ names: [String], _ file: String) {
            let unique = Array(Set(names.filter { !$0.isEmpty })).sorted()
            guard !unique.isEmpty else { return }
            try? (unique.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        if let json = run(["/opt/homebrew/bin/npm", "/usr/local/bin/npm"], ["ls", "-g", "--depth=0", "--json"]),
           let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let deps = obj["dependencies"] as? [String: Any] {
            save(deps.keys.filter { $0 != "npm" && $0 != "corepack" }, "npm-global.txt")
        }
        if let out = run(["/opt/homebrew/bin/uv", home + "/.local/bin/uv", home + "/.cargo/bin/uv"], ["tool", "list"]) {
            save(ToolInventory.parseUVToolList(out), "uv-tools.txt")
        }
        if let out = run(["/opt/homebrew/bin/pipx", home + "/.local/bin/pipx"], ["list", "--short"]) {
            save(out.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }, "pipx.txt")
        }
        if let out = run([home + "/.cargo/bin/cargo", "/opt/homebrew/bin/cargo"], ["install", "--list"]) {
            save(ToolInventory.parseCargoInstallList(out), "cargo-install.txt")
        }
    }

    private static func captureCommandOutput(cmd: String, altCmd: String,
                                              args: [String], to url: URL) {
        let path = FileManager.default.fileExists(atPath: cmd) ? cmd :
                   (FileManager.default.fileExists(atPath: altCmd) ? altCmd : nil)
        guard let execPath = path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: execPath)
        p.arguments = args
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run(); p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if !data.isEmpty { try data.write(to: url) }
        } catch {}
    }

    static func findAppBundle() -> URL? {
        let mainPath = Bundle.main.bundlePath
        if mainPath.hasSuffix(".app") {
            return URL(fileURLWithPath: mainPath)
        }
        if let execPath = Bundle.main.executablePath {
            var url = URL(fileURLWithPath: execPath)
            for _ in 0..<4 {
                url = url.deletingLastPathComponent()
                if url.path.hasSuffix(".app") { return url }
            }
        }
        return nil
    }

    private static func copyAppBinary(to dir: URL) {
        guard let appURL = findAppBundle(),
              FileManager.default.fileExists(atPath: appURL.path) else { return }
        let destApp = dir.appendingPathComponent("\(AppIdentity.name).app")
        try? FileManager.default.removeItem(at: destApp)
        try? FileManager.default.copyItem(at: appURL, to: destApp)
    }

    private static func generateRestoreScript(to dir: URL) {
        let script = """
        #!/bin/bash
        set -euo pipefail

        # MacBackup4Dev Environment Restore Script
        # Run this on a fresh Mac to restore your dev environment.
        #
        # Usage: bash restore.sh [backup-snapshot-path]

        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        SNAPSHOT="${1:-$(dirname "$SCRIPT_DIR")}"

        echo "=== MacBackup4Dev Environment Restore ==="
        echo "Snapshot: $SNAPSHOT"
        echo "Environment: $SCRIPT_DIR"
        echo ""

        # 1. Install Homebrew if missing
        if ! command -v brew &>/dev/null; then
            echo "Installing Homebrew..."
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
        fi
        echo "[ok] Homebrew ready"

        # 2. Restore Brewfile (taps, formulae, casks, mas apps)
        if [ -f "$SCRIPT_DIR/Brewfile" ]; then
            echo "Installing packages from Brewfile..."
            brew bundle install --file="$SCRIPT_DIR/Brewfile" --no-lock || true
            echo "[ok] Homebrew packages restored"
        fi

        # 3. Restore config files
        echo ""
        echo "Restoring config files..."
        HOME_DIR="$HOME"

        for item in "$SNAPSHOT"/.*; do
            name="$(basename "$item")"
            case "$name" in
                .|..|.DS_Store|.Trash|.Spotlight-*) continue ;;
            esac
            dest="$HOME_DIR/$name"
            if [ -e "$dest" ]; then
                echo "  [skip] ~/$name (already exists)"
            else
                cp -R "$item" "$dest" 2>/dev/null && echo "  [ok] ~/$name" || echo "  [fail] ~/$name"
            fi
        done

        # Restore non-hidden dirs (GitHub, Developer, etc.)
        for item in "$SNAPSHOT"/*; do
            name="$(basename "$item")"
            case "$name" in
                _environment) continue ;;
            esac
            dest="$HOME_DIR/$name"
            if [ -e "$dest" ]; then
                echo "  [skip] ~/$name (already exists)"
            else
                cp -R "$item" "$dest" 2>/dev/null && echo "  [ok] ~/$name" || echo "  [fail] ~/$name"
            fi
        done

        # 4. Install VS Code extensions
        if [ -f "$SCRIPT_DIR/vscode-extensions.txt" ] && command -v code &>/dev/null; then
            echo ""
            echo "Installing VS Code extensions..."
            while IFS= read -r ext; do
                code --install-extension "$ext" --force 2>/dev/null && echo "  [ok] $ext" || echo "  [fail] $ext"
            done < "$SCRIPT_DIR/vscode-extensions.txt"
        fi

        # 5. Install Cursor extensions
        if [ -f "$SCRIPT_DIR/cursor-extensions.txt" ] && command -v cursor &>/dev/null; then
            echo ""
            echo "Installing Cursor extensions..."
            while IFS= read -r ext; do
                cursor --install-extension "$ext" --force 2>/dev/null && echo "  [ok] $ext" || echo "  [fail] $ext"
            done < "$SCRIPT_DIR/cursor-extensions.txt"
        fi

        # 6. Clone Git repos (restore .git/objects excluded from backup)
        echo ""
        echo "Checking Git repos..."
        if [ -d "$HOME_DIR/GitHub" ]; then
            for repo in "$HOME_DIR/GitHub"/*/; do
                name="$(basename "$repo")"
                if [ -d "$repo/.git" ] && [ ! -d "$repo/.git/objects" ]; then
                    echo "  Re-fetching $name..."
                    (cd "$repo" && git fetch --all 2>/dev/null && echo "  [ok] $name" || echo "  [fail] $name")
                fi
            done
        fi

        # 7. Install the backup app itself
        if [ -d "$SCRIPT_DIR/MacBackup4Dev.app" ]; then
            echo ""
            echo "Installing MacBackup4Dev.app..."
            cp -R "$SCRIPT_DIR/MacBackup4Dev.app" /Applications/ 2>/dev/null \\
                && echo "[ok] MacBackup4Dev.app installed" \\
                || echo "[fail] Could not install (try: sudo cp -R)"
        fi

        echo ""
        echo "=== Restore complete ==="
        echo ""
        echo "What was restored:"
        echo "  - Homebrew packages (formulae, casks, Mac App Store apps)"
        echo "  - Config files (shell, git, ssh, editors, AI tools)"
        echo "  - VS Code / Cursor extensions"
        echo "  - Git repos (re-fetched from remote)"
        echo "  - MacBackup4Dev.app"
        echo ""
        echo "Manual steps needed:"
        echo "  - Sign into iCloud, GitHub, Azure, etc."
        echo "  - Re-download Xcode certificates (Xcode > Settings > Accounts)"
        echo "  - Restart your shell (source ~/.zshrc or open new terminal)"
        """
        let url = dir.appendingPathComponent("restore.sh")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        // Make executable
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func machineArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

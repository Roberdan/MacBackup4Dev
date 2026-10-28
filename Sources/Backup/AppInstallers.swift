import Foundation

enum AppInstallers {
    struct Hint {
        var packageID: String
        var requiresInstaller: Bool
    }

    static func hints() -> [String: Hint] {
        guard let brew = ToolInventory.brew else { return [:] }
        let result = Shell.run(brew, ["info", "--json=v2", "--installed", "--cask"], timeout: 60,
                               environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"])
        guard result.ok else {
            Log.warn("Cannot identify Homebrew app installers; app copies remain enabled: \(result.stderr.suffix(200))")
            return [:]
        }
        do { return try parse(result.stdout) }
        catch {
            Log.warn("Cannot read Homebrew app metadata; app copies remain enabled: \(error)")
            return [:]
        }
    }

    static func parse(_ json: String) throws -> [String: Hint] {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else {
            throw AppInventory.failure("Metadati Homebrew non validi.")
        }
        var out: [String: Hint] = [:]
        var ambiguous = Set<String>()
        for cask in casks {
            guard let token = cask["token"] as? String,
                  let artifacts = cask["artifacts"] as? [[String: Any]] else { continue }
            let needsInstaller = artifacts.contains { artifact in
                ["pkg", "installer", "preflight", "postflight"].contains { artifact[$0] != nil }
            }
            for artifact in artifacts {
                guard let app = artifact["app"] as? [Any], let source = app.first as? String else { continue }
                let target = app.compactMap { ($0 as? [String: Any])?["target"] as? String }.first
                    ?? (source as NSString).lastPathComponent
                guard AppInventory.validRelativePath(target) else { continue }
                let path = "/Applications/" + target
                if out[path] != nil { ambiguous.insert(path) }
                out[path] = Hint(packageID: "cask:" + token, requiresInstaller: needsInstaller)
            }
        }
        for path in ambiguous { out.removeValue(forKey: path) }
        return out
    }
}

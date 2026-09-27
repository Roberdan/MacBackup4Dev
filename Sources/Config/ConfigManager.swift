import Foundation

struct Config {
    var source: SourceConfig
    var destination: DestinationConfig
    var exclude: ExcludeConfig
    var retention: RetentionConfig
    var protection: ProtectionConfig = ProtectionConfig()

    static var defaultPath: URL {
        URL(fileURLWithPath: ("~/.config/rusty-mac-backup/config.toml" as NSString).expandingTildeInPath)
    }

    static func load(from url: URL) throws -> Config {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parseTOML(content)
    }

    func save(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var out: [String] = []
        out.append("[source]")
        out.append("paths = [")
        for path in source.paths {
            out.append("    \"\(Self.escape(path))\",")
        }
        out.append("]")
        out.append("")
        out.append("[destination]")
        out.append("path = \"\(Self.escape(destination.path))\"")
        out.append("")
        out.append("[exclude]")
        out.append("patterns = [")
        for pattern in exclude.patterns {
            out.append("    \"\(Self.escape(pattern))\",")
        }
        out.append("]")
        out.append("")
        out.append("[retention]")
        out.append("hourly = \(retention.hourly)")
        out.append("daily = \(retention.daily)")
        out.append("weekly = \(retention.weekly)")
        out.append("monthly = \(retention.monthly)")
        out.append("")
        out.append("[protection]")
        out.append("include_rights_managed_files = \(protection.includeRightsManagedFiles)")
        out.append("include_cloud_storage = \(protection.includeCloudStorage)")
        out.append("")

        let data = out.joined(separator: "\n").data(using: .utf8)!
        try data.write(to: url, options: [.atomic])
        // Set config permissions to 0600 (owner-only)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func parseTOML(_ content: String) throws -> Config {
        var config = Config(
            source: SourceConfig(paths: []),
            destination: DestinationConfig(path: ""),
            exclude: ExcludeConfig(patterns: []),
            retention: RetentionConfig()
        )

        var currentSection = ""
        var arrayState: (section: String, key: String, values: [String])?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if var state = arrayState {
                if let closeIdx = line.firstIndex(of: "]") {
                    let beforeClose = String(line[..<closeIdx])
                    state.values.append(contentsOf: parseArrayItems(from: beforeClose))
                    assign(section: state.section, key: state.key, values: state.values, to: &config)
                    arrayState = nil
                } else {
                    state.values.append(contentsOf: parseArrayItems(from: line))
                    arrayState = state
                }
                continue
            }

            if line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            if value.hasPrefix("[") {
                let afterOpen = String(value.dropFirst())
                if let closeIndex = afterOpen.firstIndex(of: "]") {
                    let inner = String(afterOpen[..<closeIndex])
                    let values = parseArrayItems(from: inner)
                    assign(section: currentSection, key: key, values: values, to: &config)
                } else {
                    let initial = parseArrayItems(from: afterOpen)
                    arrayState = (section: currentSection, key: key, values: initial)
                }
                continue
            }

            if let str = parseQuotedString(value) {
                assign(section: currentSection, key: key, stringValue: str, to: &config)
            } else if let boolValue = parseBool(value) {
                assign(section: currentSection, key: key, boolValue: boolValue, to: &config)
            } else if let intValue = UInt32(value) {
                assign(section: currentSection, key: key, intValue: intValue, to: &config)
            }
        }

        // Migrate old format: if paths is empty but we got a legacy "path" + "extra_paths"
        if config.source.paths.isEmpty, let legacy = config.source.legacyPath {
            config.source.paths = [legacy] + config.source.legacyExtraPaths
            config.source.legacyPath = nil
            config.source.legacyExtraPaths = []
        }

        return config
    }

    private static func assign(section: String, key: String, stringValue: String, to config: inout Config) {
        switch "\(section).\(key)" {
        case "source.path": config.source.legacyPath = stringValue
        case "destination.path": config.destination.path = stringValue
        default: break
        }
    }

    private static func assign(section: String, key: String, intValue: UInt32, to config: inout Config) {
        switch "\(section).\(key)" {
        case "retention.hourly": config.retention.hourly = intValue
        case "retention.daily": config.retention.daily = intValue
        case "retention.weekly": config.retention.weekly = intValue
        case "retention.monthly": config.retention.monthly = intValue
        default: break
        }
    }

    private static func assign(section: String, key: String, values: [String], to config: inout Config) {        switch "\(section).\(key)" {
        case "source.paths": config.source.paths = values
        case "source.extra_paths": config.source.legacyExtraPaths = values
        case "exclude.patterns": config.exclude.patterns = values
        default: break
        }
    }

    private static func assign(section: String, key: String, boolValue: Bool, to config: inout Config) {
        switch "\(section).\(key)" {
        case "protection.include_rights_managed_files": config.protection.includeRightsManagedFiles = boolValue
        case "protection.include_cloud_storage": config.protection.includeCloudStorage = boolValue
        default: break
        }
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func parseQuotedString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseArrayItems(from input: String) -> [String] {
        var items: [String] = []
        var inQuotes = false
        var escaped = false
        var token = ""
        for char in input {
            if escaped { token.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; token.append(char); continue }
            if char == "\"" {
                inQuotes.toggle()
                token.append(char)
                if !inQuotes, let parsed = parseQuotedString(token) {
                    items.append(parsed)
                    token = ""
                }
                continue
            }
            if inQuotes { token.append(char) }
        }
        return items
    }

    private static func stripComment(from line: String) -> String {
        var out = ""
        var inQuotes = false
        var escaped = false
        for char in line {
            if escaped { out.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; out.append(char); continue }
            if char == "\"" { inQuotes.toggle(); out.append(char); continue }
            if char == "#", !inQuotes { break }
            out.append(char)
        }
        return out
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

struct SourceConfig {
    var paths: [String]
    // Legacy migration support
    var legacyPath: String?
    var legacyExtraPaths: [String] = []

    func allExpandedPaths() -> [String] {
        paths.map { ConfigDiscovery.expand($0) }
    }
}

struct DestinationConfig {
    var path: String
}

struct ExcludeConfig {
    var patterns: [String]
}

struct RetentionConfig {
    var hourly: UInt32 = 24
    var daily: UInt32 = 30
    var weekly: UInt32 = 52
    var monthly: UInt32 = 0
}

/// Missing keys, including older label-based configurations, default to exclusion.
struct ProtectionConfig {
    var includeRightsManagedFiles: Bool = false
    /// OneDrive/Dropbox/Google Drive et al. (~/Library/CloudStorage). Config-only: no UI
    /// checkbox on purpose -- edit config.toml directly to turn this on.
    var includeCloudStorage: Bool = false
}

/// Patterns excluded from every backup by default. Also used by discovery when sizing a
/// candidate directory, so a folder that is only large because of its cache still counts
/// as configuration.
let baseExcludePatterns: [String] = [
    // macOS system junk (CCC-recommended)
    ".DS_Store", ".Trash", ".Trashes", ".Spotlight-V100",
    ".fseventsd", ".TemporaryItems", ".VolumeIcon.icns",
    "DocumentRevisions-V100",
    // Git internals (large object store -- repo is re-cloneable)
    ".git/objects", ".git/lfs",
    // Dev build artifacts (regenerable via build/install)
    "node_modules", ".next", ".nuxt", "dist", "build/intermediates",
    "target/debug", "target/release",
    ".build", "DerivedData",
    "__pycache__", ".venv", ".tox", "*.pyc",
    ".cache", "*.tmp", "*.swp",
    // App caches inside backed-up dirs
    "Caches", "GPUCache", "ShaderCache", "Code Cache",
    "CachedData", "CachedExtensions", "CachedExtensionVSIXs",
    // Large binaries
    "*.iso", "*.dmg",
    // AI tool caches (regenerable)
    "embedding-cache.db*", "session-store.db*", "session.db",
    "marketplace-cache", "*.jsonl",
    // Logs
    "*.log",
    // AI models (huge, re-downloadable)
    ".ollama/models", ".lmstudio",
    // Caches, state and runtime data inside otherwise-config directories.
    // Discovery picks the directories; these keep the data out of them.
    "logs", "log", "sessions", "session-state", "session-store",
    "backups", "worktrees", "blobs", "models", "registry", "downloads",
    "language_servers", "shell-snapshots", "crashpad", "tmp", "temp",
    "*-cache", "*-caches", "*-profile", "*-profiles", "*-backups", "*.old", "*.bak",
    "*.sqlite", "*.sqlite3", "*.db", "*.db-wal", "*.db-shm",
]

/// The full default exclusion set: the patterns above plus the hidden paths discovery
/// refuses to treat as configuration. The second group matters because a folder can be
/// included as a whole source (`~/.local`) while a branch inside it is pure data
/// (`~/.local/share`) — filtering that only during discovery would still let the backup
/// copy it.
let defaultExcludePatterns: [String] =
    baseExcludePatterns + ConfigDiscovery.hiddenDenyPaths.sorted()

func generateDefaultConfig(backupPath: String) -> Config {
    let (discovered, dataExclusions) = ConfigDiscovery.discoverAll()
    var paths: [String] = []
    for item in discovered where !item.sensitive {
        for path in item.paths where !ConfigDiscovery.isForbidden(path) {
            paths.append(path)
        }
    }
    // Always include the backup config itself (for portability)
    paths.append("~/.config/rusty-mac-backup")

    // Never list a directory and its own children as separate sources
    paths = ConfigDiscovery.pruneRedundant(paths)

    // Repos are discovered individually (~/GitHub/*, ~/Developer/*, ~/Projects/*)

    return Config(
        source: SourceConfig(paths: paths),
        destination: DestinationConfig(path: backupPath),
        exclude: ExcludeConfig(patterns: defaultExcludePatterns + dataExclusions.sorted()),
        retention: RetentionConfig()
    )
}

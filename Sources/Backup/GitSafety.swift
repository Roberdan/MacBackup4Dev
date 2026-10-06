import Foundation

/// What a snapshot knows about one git repository. `.git/objects` is never copied (it is
/// large and re-cloneable), so without this record a commit that was never pushed is gone.
/// Scar 2026-10-06: unpublished branches of casa-caccini, VirtualBPMFy27 and
/// research-cloud-api were lost exactly that way.
struct GitRepoRecord: Codable, Equatable {
    struct Branch: Codable, Equatable {
        var name: String
        var sha: String
        var upstream: String?
        var unpushedCommits: Int
    }
    var relativePath: String
    var remotes: [String: String]
    var head: String
    var headSHA: String
    var branches: [Branch]
    var stashes: Int
    var worktrees: [String]
    var unpushedCommits: Int
    /// File name inside `_rustymacbackup/git/`, present only when something was unpushed.
    var bundle: String?
    var error: String?
}

enum GitSafety {
    static let directoryName = "git"

    /// Directories that are git repositories (main checkout: `.git` is a directory) below
    /// the given sources. Linked worktrees are found through their main repository.
    static func discoverRepositories(sources: [String], excludeFilter: ExcludeFilter,
                                     home: String, maxDepth: Int = 4) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", ".git", "Library", ".Trash", "DerivedData",
                                 ".build", "build", "dist", ".next", "target", ".venv"]
        func visit(_ dir: URL, depth: Int) {
            var isDir: ObjCBool = false
            let gitPath = dir.appendingPathComponent(".git").path
            if fm.fileExists(atPath: gitPath, isDirectory: &isDir), isDir.boolValue {
                found.append(dir)
            }
            guard depth < maxDepth,
                  let children = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []) else { return }
            for child in children {
                let name = child.lastPathComponent
                guard !skip.contains(name) else { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let rel = child.path.hasPrefix(home + "/") ? String(child.path.dropFirst(home.count + 1)) : child.path
                guard !excludeFilter.isExcluded(relativePath: rel) else { continue }
                visit(child, depth: depth + 1)
            }
        }
        for source in sources {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else { continue }
            visit(URL(fileURLWithPath: source), depth: 0)
        }
        // A source and its parent can both be listed: report each repository once.
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Record the repository and bundle every commit not reachable from a remote.
    static func capture(repository: URL, home: String, into directory: URL) -> GitRepoRecord {
        // /var is /private/var on macOS: compare real paths, or a repo looks outside the home.
        let realHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let realRepo = repository.resolvingSymlinksInPath().path
        let rel = realRepo.hasPrefix(realHome + "/")
            ? String(realRepo.dropFirst(realHome.count + 1)) : realRepo
        var record = GitRepoRecord(relativePath: rel, remotes: [:], head: "", headSHA: "",
                                   branches: [], stashes: 0, worktrees: [], unpushedCommits: 0)
        guard let git = Shell.git else {
            record.error = "git non trovato"
            return record
        }
        let path = repository.path
        func g(_ args: [String], timeout: TimeInterval = 120) -> Shell.Result {
            Shell.run(git, ["-C", path] + args, timeout: timeout)
        }

        let remotes = g(["remote", "-v"])
        for line in remotes.stdout.split(separator: "\n") where line.hasSuffix("(fetch)") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2 { record.remotes[String(parts[0])] = String(parts[1]) }
        }
        let head = g(["symbolic-ref", "--quiet", "--short", "HEAD"])
        record.head = head.ok ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "(detached)"
        let headSHA = g(["rev-parse", "--verify", "--quiet", "HEAD"])
        record.headSHA = headSHA.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty repository (no commit yet) has nothing to lose in git terms.
        guard headSHA.ok || !g(["for-each-ref", "refs/heads"]).stdout.isEmpty else { return record }

        let hasRemotes = !record.remotes.isEmpty
        let refs = g(["for-each-ref", "--format=%(refname:short)\t%(objectname)\t%(upstream:short)", "refs/heads"])
        var refsToBundle: [String] = []
        for line in refs.stdout.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 2 else { continue }
            let count: Int
            if hasRemotes {
                let c = g(["rev-list", "--count", cols[1], "--not", "--remotes"])
                count = Int(c.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            } else {
                let c = g(["rev-list", "--count", cols[1]])
                count = Int(c.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            let upstream = cols.count > 2 && !cols[2].isEmpty ? cols[2] : nil
            record.branches.append(.init(name: cols[0], sha: cols[1], upstream: upstream,
                                         unpushedCommits: count))
            if count > 0 { refsToBundle.append("refs/heads/\(cols[0])") }
        }
        let stash = g(["stash", "list", "--format=%H"])
        record.stashes = stash.stdout.split(separator: "\n").count
        if record.stashes > 0 { refsToBundle.append("refs/stash") }
        let worktrees = g(["worktree", "list", "--porcelain"])
        record.worktrees = worktrees.stdout.split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
            .filter { $0 != path }
        // Branches of different worktrees can share commits: count each commit once.
        if hasRemotes, !refsToBundle.isEmpty {
            let all = g(["rev-list", "--count"] + refsToBundle.filter { $0 != "refs/stash" } + ["--not", "--remotes"])
            record.unpushedCommits = Int(all.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? record.branches.map(\.unpushedCommits).reduce(0, +)
        } else {
            record.unpushedCommits = record.branches.map(\.unpushedCommits).max() ?? 0
        }

        guard !refsToBundle.isEmpty else { return record }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            record.error = "cartella git non creabile: \(error.localizedDescription)"
            return record
        }
        let name = bundleName(for: rel)
        let target = directory.appendingPathComponent(name).path
        var args = ["bundle", "create", target] + refsToBundle
        if hasRemotes { args += ["--not", "--remotes"] }
        let bundle = g(args, timeout: 600)
        if bundle.ok, FileManager.default.fileExists(atPath: target) {
            let verify = g(["bundle", "verify", target])
            if verify.ok { record.bundle = name } else {
                record.error = "pacchetto non valido: \(verify.stderr.prefix(200))"
            }
        } else {
            record.error = "pacchetto non creato: \(bundle.stderr.prefix(200))"
        }
        return record
    }

    static func bundleName(for relativePath: String) -> String {
        let safe = relativePath.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return String(safe) + ".bundle"
    }

    static func captureAll(sources: [String], excludeFilter: ExcludeFilter, home: String,
                           into snapshot: URL) -> [GitRepoRecord] {
        let dir = snapshot.appendingPathComponent(SnapshotManifest.directoryName)
            .appendingPathComponent(directoryName)
        return discoverRepositories(sources: sources, excludeFilter: excludeFilter, home: home)
            .map { capture(repository: $0, home: home, into: dir) }
    }

    /// Put the saved commits back into a clone: every bundled branch becomes a local branch
    /// again (forced: the bundle is the newer truth), the stash comes back as a branch
    /// `recupero/stash` because git cannot re-create a stash list from a ref.
    static func apply(bundle: URL, to repository: URL) -> Shell.Result {
        guard let git = Shell.git else {
            return Shell.Result(status: -1, stdout: "", stderr: "git non trovato")
        }
        let heads = Shell.run(git, ["-C", repository.path, "bundle", "list-heads", bundle.path])
        guard heads.ok else { return heads }
        var specs: [String] = []
        for line in heads.stdout.split(separator: "\n") {
            guard let ref = line.split(separator: " ").last.map(String.init) else { continue }
            if ref.hasPrefix("refs/heads/") { specs.append("+\(ref):\(ref)") }
            if ref == "refs/stash" { specs.append("+refs/stash:refs/heads/recupero/stash") }
        }
        guard !specs.isEmpty else { return heads }
        return Shell.run(git, ["-C", repository.path, "fetch", "--update-head-ok", bundle.path] + specs)
    }
}

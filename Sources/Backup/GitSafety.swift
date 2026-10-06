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
    /// Set when the repository could not be read or the bundle could not be made: the
    /// snapshot is then incomplete, never silently "nothing to save".
    var error: String?
    /// Things saved only partially (older stashes), shown but not fatal.
    var warnings: [String]? = nil
    /// What the bundle contains (bundled ref SHAs + published base): an unchanged key lets
    /// the next snapshot hard-link the previous bundle instead of writing it again.
    var bundleKey: String? = nil
}

enum GitSafety {
    static let directoryName = "git"

    /// Directories that are git repositories (main checkout: `.git` is a directory) below
    /// the given sources. Linked worktrees are found through their main repository.
    /// Submodules (`.git` is a file) are not recorded: their commits live in their own remote.
    static func discoverRepositories(sources: [String], excludeFilter: ExcludeFilter,
                                     home: String, maxDepth: Int = 5) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", ".git", "Library", ".Trash", "DerivedData",
                                 ".build", "build", "dist", ".next", "target", ".venv"]
        func isRepo(_ dir: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir.appendingPathComponent(".git").path, isDirectory: &isDir) && isDir.boolValue
        }
        func visit(_ dir: URL, depth: Int) {
            if isRepo(dir) { found.append(dir) }
            guard depth < maxDepth,
                  let children = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []) else { return }
            for child in children {
                let name = child.lastPathComponent
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                // A repository is a repository even when it is called build/dist/target.
                if skip.contains(name) && !isRepo(child) { continue }
                let rel = child.path.hasPrefix(home + "/") ? String(child.path.dropFirst(home.count + 1)) : child.path
                guard !excludeFilter.isExcluded(relativePath: rel) || isRepo(child) else { continue }
                visit(child, depth: depth + 1)
            }
        }
        for source in sources {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else { continue }
            visit(URL(fileURLWithPath: source), depth: 0)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The refs that define "already published": each remote's default branch only.
    /// Stale remote-tracking refs (a branch squash-merged and deleted on GitHub) are NOT
    /// trusted: commits only reachable from them would be missing from a fresh clone, so a
    /// bundle excluding them could not be applied (scar found in review, 2026-10-06).
    static func publishedRefs(_ g: (_ args: [String]) -> Shell.Result, remotes: [String]) -> [String] {
        var refs: [String] = []
        for remote in remotes.sorted() {
            let head = g(["symbolic-ref", "--quiet", "refs/remotes/\(remote)/HEAD"])
            let target = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // origin/HEAD can point at a branch that was pruned since (review R4).
            if head.ok, !target.isEmpty, g(["rev-parse", "--verify", "--quiet", target]).ok {
                refs.append(target)
                continue
            }
            for candidate in ["main", "master", "Development", "develop", "trunk"] {
                let ref = "refs/remotes/\(remote)/\(candidate)"
                if g(["rev-parse", "--verify", "--quiet", ref]).ok { refs.append(ref); break }
            }
        }
        return refs
    }

    /// Record the repository and bundle every commit not reachable from a remote default branch.
    static func capture(repository: URL, home: String, into directory: URL,
                        previous: (record: GitRepoRecord, directory: URL)? = nil) -> GitRepoRecord {
        // /var is /private/var on macOS: compare real paths, or a repo looks outside the home.
        let realHome = FileScanner.realPath(home)
        let realRepo = FileScanner.realPath(repository.path)
        let rel = realRepo.hasPrefix(realHome + "/")
            ? String(realRepo.dropFirst(realHome.count + 1)) : realRepo
        var record = GitRepoRecord(relativePath: rel, remotes: [:], head: "", headSHA: "",
                                   branches: [], stashes: 0, worktrees: [], unpushedCommits: 0)
        guard let git = Shell.git else {
            record.error = "git non trovato"
            return record
        }
        let path = repository.path
        // English messages: "The bundle requires…" is parsed below (git ships translations).
        func g(_ args: [String], timeout: TimeInterval = 120) -> Shell.Result {
            Shell.run(git, ["-C", path] + args, timeout: timeout, environment: ["LC_ALL": "C"])
        }
        func fail(_ what: String, _ r: Shell.Result) -> GitRepoRecord {
            var copy = record
            copy.error = "\(what): " + String(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            return copy
        }

        let remotes = g(["remote", "-v"])
        guard remotes.ok else { return fail("git non legge il repository", remotes) }
        for line in remotes.stdout.split(separator: "\n") where line.hasSuffix("(fetch)") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if parts.count >= 2 { record.remotes[String(parts[0])] = String(parts[1]) }
        }
        let heads = g(["for-each-ref", "--format=%(refname:short)\t%(objectname)\t%(upstream:short)", "refs/heads"])
        guard heads.ok else { return fail("elenco dei branch non leggibile", heads) }
        let headSHA = g(["rev-parse", "--verify", "--quiet", "HEAD"])
        record.headSHA = headSHA.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = g(["symbolic-ref", "--quiet", "--short", "HEAD"])
        record.head = head.ok ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "(detached)"
        // A brand-new repository with no commit has nothing git can lose.
        if heads.stdout.isEmpty && !headSHA.ok { return record }
        guard headSHA.ok else { return fail("HEAD non leggibile", headSHA) }

        let published = publishedRefs({ g($0) }, remotes: Array(record.remotes.keys))
        func countUnpublished(_ revs: [String]) -> Int? {
            let r = g(["rev-list", "--count"] + revs + (published.isEmpty ? [] : ["--not"] + published))
            return r.ok ? Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        }

        var refsToBundle: [String] = []
        for line in heads.stdout.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 2 else { continue }
            guard let count = countUnpublished([cols[1]]) else {
                return fail("conteggio dei commit di \(cols[0]) non riuscito", g(["rev-list", "-1", cols[1]]))
            }
            let upstream = cols.count > 2 && !cols[2].isEmpty ? cols[2] : nil
            record.branches.append(.init(name: cols[0], sha: cols[1], upstream: upstream, unpushedCommits: count))
            if count > 0 { refsToBundle.append("refs/heads/\(cols[0])") }
        }
        if record.head == "(detached)", let n = countUnpublished([record.headSHA]), n > 0 {
            refsToBundle.append("HEAD")
        }
        let stash = g(["stash", "list", "--format=%H"])
        let stashes = stash.stdout.split(separator: "\n")
        record.stashes = stashes.count
        if record.stashes > 0 { refsToBundle.append("refs/stash") }
        if record.stashes > 1 {
            record.warnings = ["\(record.stashes - 1) stash più vecchi non salvati (solo l'ultimo è nel pacchetto)"]
        }
        let worktrees = g(["worktree", "list", "--porcelain"])
        record.worktrees = worktrees.stdout.split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
            .filter { FileScanner.realPath($0) != realRepo }

        let branchRevs = refsToBundle.filter { $0 != "refs/stash" }
        if !branchRevs.isEmpty {
            record.unpushedCommits = countUnpublished(branchRevs) ?? record.branches.map(\.unpushedCommits).reduce(0, +)
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
        var keyParts: [String] = []
        for ref in refsToBundle {
            keyParts.append(ref + "=" + g(["rev-parse", "--verify", "--quiet", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for ref in published {
            keyParts.append("base:" + ref + "=" + g(["rev-parse", "--verify", "--quiet", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let key = keyParts.sorted().joined(separator: ";")
        record.bundleKey = key
        // Same commits as yesterday: hard-link yesterday's verified bundle (review R3).
        if let previous, previous.record.bundleKey == key, let oldName = previous.record.bundle {
            let old = previous.directory.appendingPathComponent(oldName).path
            if FileManager.default.fileExists(atPath: old),
               (try? FileManager.default.linkItem(atPath: old, toPath: target)) != nil {
                record.bundle = name
                return record
            }
        }
        let args = ["bundle", "create", target] + refsToBundle + (published.isEmpty ? [] : ["--not"] + published)
        let bundle = g(args, timeout: 600)
        guard bundle.ok, FileManager.default.fileExists(atPath: target) else {
            return fail("pacchetto non creato", bundle)
        }
        // The bundle may only depend on commits a fresh clone has: the remote default
        // branches. Anything else means it could not be applied after a reinstall.
        let verify = g(["bundle", "verify", target])
        guard verify.ok else { return fail("pacchetto non valido", verify) }
        var inRequires = false
        for line in verify.stdout.split(separator: "\n") {
            if line.hasPrefix("The bundle ") { inRequires = line.hasPrefix("The bundle requires"); continue }
            guard inRequires, let sha = line.split(separator: " ").first, sha.count >= 40 else { continue }
            let reachable = published.contains { ref in
                g(["merge-base", "--is-ancestor", String(sha), ref]).ok
            }
            if !reachable {
                return fail("il pacchetto dipende da un commit non presente sul ramo principale remoto (\(sha.prefix(8)))",
                            Shell.Result(status: 1, stdout: "", stderr: ""))
            }
        }
        record.bundle = name
        return record
    }

    /// Readable and collision-free: `a b` and `a_b` get different names.
    static func bundleName(for relativePath: String) -> String {
        let safe = String(relativePath.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        var hash: UInt64 = 1469598103934665603
        for byte in relativePath.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return safe + "-" + String(hash & 0xFFFF_FFFF, radix: 16) + ".bundle"
    }

    static func captureAll(sources: [String], excludeFilter: ExcludeFilter, home: String,
                           into snapshot: URL, previousSnapshot: URL? = nil) -> [GitRepoRecord] {
        let dir = snapshot.appendingPathComponent(SnapshotManifest.directoryName)
            .appendingPathComponent(directoryName)
        let prevDir = previousSnapshot?.appendingPathComponent(SnapshotManifest.directoryName)
            .appendingPathComponent(directoryName)
        var prevRecords: [String: GitRepoRecord] = [:]
        for r in previousSnapshot.flatMap({ SnapshotManifest.read(from: $0) })?.git ?? [] {
            prevRecords[r.relativePath] = r
        }
        return discoverRepositories(sources: sources, excludeFilter: excludeFilter, home: home).map { repo in
            let realHome = FileScanner.realPath(home), realRepo = FileScanner.realPath(repo.path)
            let rel = realRepo.hasPrefix(realHome + "/") ? String(realRepo.dropFirst(realHome.count + 1)) : realRepo
            let previous = prevDir.flatMap { d in prevRecords[rel].map { ($0, d) } }
            return capture(repository: repo, home: home, into: dir, previous: previous)
        }
    }

    /// Put the saved commits back into a clone: every bundled branch becomes a local branch
    /// again (forced: the bundle is the newer truth); the stash and a detached HEAD come back
    /// as `recupero/stash` and `recupero/detached` because git cannot recreate them as such.
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
            if ref == "HEAD" { specs.append("+HEAD:refs/heads/recupero/detached") }
        }
        guard !specs.isEmpty else { return heads }
        return Shell.run(git, ["-C", repository.path, "fetch", "--update-head-ok", bundle.path] + specs)
    }
}

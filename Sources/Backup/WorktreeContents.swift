import Foundation

/// What a saved checkout of a deleted worktree holds that nothing else may have a copy of.
/// Files git ignores (local helpers, exports, artifacts) are in no commit: once the worktree is
/// gone, the copy in an old snapshot can be the last one. Caches their tool rebuilds do not count.
enum WorktreeContents {
    enum Verdict: Equatable {
        /// Nothing git ignores except caches: the copy can go.
        case disposable
        /// Ignored files that are not caches (a few, relative to the copy): the copy stays.
        case holdsIgnoredFiles([String])
        /// git could not say what the copy holds: it stays until someone can look.
        case unverified(String)
    }

    /// Folders and files a tool creates again by itself, wherever they sit in a copy.
    static let regenerable: Set<String> = [
        "__pycache__", ".ruff_cache", ".pytest_cache", ".mypy_cache", "node_modules", ".venv",
        ".build", "DerivedData", ".DS_Store",
    ]

    static func isRegenerable(_ ignoredPath: String) -> Bool {
        ignoredPath.split(separator: "/").contains { regenerable.contains(String($0)) }
    }

    /// Asks git which files of `copy` the main repository's rules ignore. `repository` is the main
    /// `.git` directory: the copy's own `.git` file leads to a worktree entry that is usually gone.
    /// Ignored folders are listed whole, so the walk stays short, and empty ones are not listed.
    static func inspect(copy: URL, repository: URL, timeout: TimeInterval = 120,
                        cancelled: () -> Bool = { false }) -> Verdict {
        guard let git = Shell.git else { return .unverified("git non trovato") }
        let listed = Shell.run(
            git, ["--no-optional-locks", "--git-dir=" + repository.path, "--work-tree=" + copy.path,
                  "ls-files", "--others", "--ignored", "--exclude-standard",
                  "--directory", "--no-empty-directory", "-z"],
            cwd: copy.path, timeout: timeout, environment: ["LC_ALL": "C"], cancelled: cancelled)
        guard listed.ok else { return .unverified(listed.failureReason) }
        let held = listed.stdout.split(separator: "\0").map(String.init).filter {
            !isRegenerable($0) && (!$0.hasSuffix("/") || holdsMoreThanCaches(copy.appendingPathComponent($0)))
        }
        return held.isEmpty ? .disposable : .holdsIgnoredFiles(Array(held.sorted().prefix(3)))
    }

    /// git lists a folder whole when everything untracked in it is ignored, so `pkg/` can be nothing
    /// but `pkg/__pycache__/`. Looks inside, without entering caches: anything else is something to
    /// keep, and so is a folder that cannot be read.
    private static func holdsMoreThanCaches(_ directory: URL) -> Bool {
        var unreadable = false
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, _ in unreadable = true; return true }) else { return true }
        for case let url as URL in walker {
            if regenerable.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true { continue }
            return true
        }
        return unreadable
    }

    /// The lines the cleanup command prints about copies it left alone (nothing when there are none).
    static func report(_ kept: [WorktreePolicy.KeptCopy]) -> [String] {
        var held: [String] = [], unverified: [String] = []
        for copy in kept {
            switch copy.reason {
            case .ignoredFiles(let sample): held.append("  \(copy.path) · es. \(sample.joined(separator: ", "))")
            case .unverified(let why): unverified.append("  \(copy.path) · \(why)")
            }
        }
        var lines: [String] = []
        if !held.isEmpty {
            lines.append("Copie conservate perché contengono file ignorati da git, forse unici: \(held.count)")
            lines += held
        }
        if !unverified.isEmpty {
            lines.append("Copie conservate perché non verificabili: \(unverified.count)")
            lines += unverified
        }
        return lines
    }
}

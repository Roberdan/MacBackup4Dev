import Foundation

/// Tests for the streaming file scanner.
final class FileScannerTests {
    func test_onlyMissingChildrenAreTolerated() throws {
        for error in [
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
            NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        ] {
            try expect(FileScanner.isMissingEntryError(error), "normal child deletion is not a traversal failure")
        }
        for error in [
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError),
            NSError(domain: "OtherDomain", code: Int(ENOENT))
        ] {
            try expect(!FileScanner.isMissingEntryError(error), "permission, I/O and unknown failures stay actionable")
        }
    }

    func test_explicitSourcesCannotBypassExclusions() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["repo/node_modules/pkg/index.js", "repo/.yarn/cache/pkg.zip",
                     "repo/target/debug/bin", "repo/file.tmp", "repo/src/main.swift"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "data".write(to: url, atomically: true, encoding: .utf8)
        }
        let paths = ["repo/node_modules", "repo/node_modules/pkg/index.js", "repo/file.tmp", "repo/src/main.swift"]
        var seen: [String] = []
        FileScanner.walk(sources: paths.map { root.appendingPathComponent($0) },
                         basePaths: Array(repeating: root.path, count: paths.count),
                         excludeFilter: ExcludeFilter(patterns: [])) { entry in
            seen.append(entry.relativePath)
            return true
        }
        try expectEqual(seen, ["repo/src/main.swift"], "Explicit files and directory roots must obey exclusions")
        try expectEqual(scan(root: root, patterns: []), ["repo/src/main.swift"], "Old empty config must still skip nested caches")
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("repo/file.tmp").path),
                   "Exclusion must not delete original temporary files")
    }


    /// The temp dir is canonicalised with `realpath(3)`, because `NSTemporaryDirectory()`
    /// hands back `/var/...` while the enumerator reports `/private/var/...`. Foundation's
    /// `resolvingSymlinksInPath()` is no help — it deliberately *strips* a leading `/private`,
    /// which is the wrong direction. Without this the base-path prefix never matches and every
    /// relative path collapses to a bare filename, hiding what the test is actually asserting.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rmb-scanner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let resolved = realpath(dir.path, nil) else { return dir }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func scan(root: URL, patterns: [String]) -> [String] {
        var seen: [String] = []
        FileScanner.walk(sources: [root],
                         basePaths: [root.path],
                         excludeFilter: ExcludeFilter(patterns: patterns)) { entry in
            seen.append(entry.relativePath)
            return true
        }
        return seen
    }

    /// An excluded FILE must never cost a sibling directory its contents.
    ///
    /// `skipDescendants()` skips the subdirectory the enumerator is about to descend into. It
    /// used to be called for every entry matching an exclude pattern, files included — so a
    /// `.DS_Store` sitting immediately before a real directory silently swallowed that whole
    /// subtree. Nothing failed, nothing was logged; the files were simply not in the backup.
    func test_excludedFileDoesNotSwallowSiblingDirectory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Names chosen so the excluded file sorts before the directory.
        try "junk".write(to: root.appendingPathComponent(".DS_Store"),
                         atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("zzArchive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try "keep me".write(to: archive.appendingPathComponent("notes.md"),
                            atomically: true, encoding: .utf8)
        try "keep me too".write(to: archive.appendingPathComponent("data.txt"),
                                atomically: true, encoding: .utf8)

        let seen = scan(root: root, patterns: [".DS_Store"])

        try expect(seen.contains("zzArchive/notes.md"),
                   "a directory next to an excluded file must still be scanned (got: \(seen))")
        try expect(seen.contains("zzArchive/data.txt"),
                   "the whole subtree must survive, not just the first entry (got: \(seen))")
        try expect(!seen.contains(".DS_Store"), "the excluded file itself must stay excluded")
    }

    /// The other half of the same contract: an excluded DIRECTORY must still be pruned.
    /// Fixing the bug above must not turn `shouldSkipDirectory` into a no-op.
    func test_excludedDirectoryIsStillPruned() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let modules = root.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try "x".write(to: modules.appendingPathComponent("index.js"),
                      atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("app.swift"),
                      atomically: true, encoding: .utf8)

        let seen = scan(root: root, patterns: ["node_modules"])

        try expect(seen.contains("app.swift"), "real files must be scanned (got: \(seen))")
        try expect(!seen.contains(where: { $0.contains("node_modules") }),
                   "an excluded directory must still be pruned entirely (got: \(seen))")
    }

    /// Several excluded files in a row must not compound the damage either.
    func test_multipleExcludedFilesBeforeDirectory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["a.log", "b.log", "c.tmp"] {
            try "junk".write(to: root.appendingPathComponent(name),
                             atomically: true, encoding: .utf8)
        }
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "keep".write(to: docs.appendingPathComponent("readme.md"),
                         atomically: true, encoding: .utf8)

        let seen = scan(root: root, patterns: ["*.log", "*.tmp"])

        try expect(seen.contains("docs/readme.md"),
                   "the directory must survive a run of excluded files (got: \(seen))")
        try expectEqual(seen.count, 1, "only the real file should be scanned (got: \(seen))")
    }
}

import Foundation

extension SafetyTests {
    /// A real, empty repository: the cleanup asks git what the saved copy of one of its worktrees holds.
    func makeRepository(_ path: String) throws {
        guard Shell.git != nil else { throw TestFailure.failed("git is needed to build the fixture") }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = try git(["init", "-q", "-b", "main", path], path)
    }
}

/// A deleted worktree's saved copy can be the last one of the files git ignores (local helpers,
/// exports): the cleanup keeps it, lists it, and still removes copies that hold nothing but caches.
final class WorktreeContentsTests {
    let safety = SafetyTests()

    private struct Fixture {
        let box: SafetyTests.Sandbox
        let snapshot: URL
        var destination: URL { URL(fileURLWithPath: box.dest) }
    }

    /// An old snapshot of a real repository whose exclude file says `rules`.
    private func fixture(rules: String) throws -> Fixture {
        let box = try safety.makeSandbox()
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try safety.makeRepository(box.home + "/GitHub/main")
        try safety.write(rules, to: box.home + "/GitHub/main/.git/info/exclude")
        let snapshot = try safety.runEngine(safety.config(box, sources: ["GitHub/main"]), box).snapshot
        return Fixture(box: box, snapshot: snapshot)
    }

    /// The saved copy of a worktree whose checkout is gone: its marker, one ordinary file, `extra`.
    @discardableResult
    private func plant(_ relative: String, in f: Fixture, extra: [String: String] = [:]) throws -> URL {
        let copy = f.snapshot.appendingPathComponent(relative)
        try safety.write("gitdir: \(f.box.home)/GitHub/main/.git/worktrees/wt\n", to: copy.path + "/.git")
        try safety.write("tracked", to: copy.path + "/file.txt")
        for (path, text) in extra { try safety.write(text, to: copy.path + "/" + path) }
        return copy
    }

    func test_aCopyHoldingIgnoredFilesThatAreNotCachesIsKeptAndListed() throws {
        guard Shell.git != nil else { return }
        let f = try fixture(rules: "artifacts/\nscratch.txt\n__pycache__/\nbuild_out/\n")
        defer { safety.cleanup(f.box) }
        let fm = FileManager.default
        let exports = try plant("Work/exports", in: f, extra: ["artifacts/report.json": "precious", "__pycache__/m.pyc": "x"])
        let note = try plant("Work/note", in: f, extra: ["scratch.txt": "mine"])
        let ownRules = try plant("Work/own-rules", in: f, extra: [".gitignore": "local/\n", "local/helper.sh": "echo"])
        let mixed = try plant("Work/mixed", in: f, extra: ["build_out/__pycache__/x.pyc": "x", "build_out/report.csv": "precious"])

        let outcome = try WorktreePolicy.cleanup(at: f.destination, home: f.box.home)
        try expect(outcome.removed.isEmpty, "nothing that may be the only copy goes: \(outcome.removed)")
        try expectEqual(try String(contentsOf: exports.appendingPathComponent("artifacts/report.json"), encoding: .utf8),
                        "precious", "the ignored export is still there")
        for copy in [note, ownRules, mixed] { try expect(fm.fileExists(atPath: copy.path + "/file.txt"), "kept: \(copy.path)") }
        let name = f.snapshot.lastPathComponent
        let samples = Dictionary(uniqueKeysWithValues: outcome.kept.compactMap { kept -> (String, [String])? in
            if case .ignoredFiles(let sample) = kept.reason { return (kept.path, sample) } else { return nil }
        })
        try expectEqual(samples, ["\(name)/Work/exports": ["artifacts/"], "\(name)/Work/note": ["scratch.txt"],
                                  "\(name)/Work/own-rules": ["local/"], "\(name)/Work/mixed": ["build_out/"]],
                        "each kept copy is listed with what makes it unique, a cache beside it notwithstanding")
        let lines = WorktreeContents.report(outcome.kept)
        try expect(lines.first?.contains("4") == true && lines.contains { $0.contains("Work/exports") && $0.contains("artifacts/") },
                   "the cleanup command says which copies stayed and why: \(lines)")

        let manifest = SnapshotManifest.read(from: f.snapshot)
        try expectEqual(Set(manifest?.retainedWorktreeCopies ?? []), ["Work/exports", "Work/note", "Work/own-rules", "Work/mixed"],
                        "the snapshot remembers them")
        try expectEqual(manifest?.temporaryWorktreeCopies, [], "so they are not looked at again")
        try expect(try WorktreePolicy.cleanup(at: f.destination, home: f.box.home).kept.isEmpty, "the next backup leaves them alone")

        let again = try WorktreePolicy.cleanup(at: f.destination, home: f.box.home, searchAgain: true)
        try expectEqual(again.kept.count, 4, "an explicit request looks at them anew and lists them again")
        try expect(again.removed.isEmpty && fm.fileExists(atPath: exports.path + "/artifacts/report.json"), "and still removes nothing")
    }

    func test_aCopyWithOnlyCachesIsStillRemoved() throws {
        guard Shell.git != nil else { return }
        let f = try fixture(rules: "__pycache__/\nnode_modules/\n.venv/\n.build/\n.DS_Store\nartifacts/\n")
        defer { safety.cleanup(f.box) }
        let fm = FileManager.default
        let caches = try plant("Work/caches", in: f, extra: [
            "__pycache__/m.pyc": "x", "pkg/__pycache__/n.pyc": "x", "node_modules/p/index.js": "x",
            ".venv/bin/python": "x", ".build/debug/app": "x", "sub/.DS_Store": "x"])
        let empty = try plant("Work/empty-ignored", in: f)
        try fm.createDirectory(atPath: empty.path + "/artifacts", withIntermediateDirectories: true)

        let outcome = try WorktreePolicy.cleanup(at: f.destination, home: f.box.home)
        try expectEqual(Set(outcome.removed), Set(["Work/caches", "Work/empty-ignored"].map { f.snapshot.lastPathComponent + "/" + $0 }),
                        "caches are rebuilt by their tools, and an empty ignored folder holds nothing; kept: \(outcome.kept)")
        try expect(!fm.fileExists(atPath: caches.path) && !fm.fileExists(atPath: empty.path), "really gone")
        try expect(outcome.kept.isEmpty, "nothing to list")
        try expectEqual(SnapshotManifest.read(from: f.snapshot)?.removedTemporaryWorktrees?.count, 2, "the removal is audited as before")
    }

    func test_aCopyGitCannotExamineIsKeptAndListed() throws {
        let box = try safety.makeSandbox()
        defer { safety.cleanup(box) }
        let fm = FileManager.default
        try safety.write("source", to: box.home + "/GitHub/main/file.txt")
        try fm.createDirectory(atPath: box.home + "/GitHub/main/.git/worktrees", withIntermediateDirectories: true)
        let snapshot = try safety.runEngine(safety.config(box, sources: ["GitHub/main"]), box).snapshot
        let copy = snapshot.appendingPathComponent("Work/wt")
        try safety.write("gitdir: \(box.home)/GitHub/main/.git/worktrees/wt\n", to: copy.path + "/.git")
        try safety.write("only copy", to: copy.path + "/file.txt")

        let outcome = try WorktreePolicy.cleanup(at: URL(fileURLWithPath: box.dest), home: box.home)
        try expect(outcome.removed.isEmpty && fm.fileExists(atPath: copy.path + "/file.txt"),
                   "a repository git cannot read says nothing about what is ignored: the copy stays")
        guard case .unverified = outcome.kept.first?.reason else { throw TestFailure.failed("listed as not verifiable: \(outcome.kept)") }
        try expect(WorktreeContents.report(outcome.kept).first?.contains("non verificabili") == true, "and the command says so")
        try expectEqual(SnapshotManifest.read(from: snapshot)?.temporaryWorktreeCopies, ["Work/wt"],
                        "it is looked at again at the next backup, not written off")
    }

    func test_onlyKnownCachesAreRegenerable() throws {
        for path in ["__pycache__/", "pkg/sub/__pycache__/", "web/node_modules/", ".venv/", ".build/", "App/DerivedData/",
                     ".pytest_cache/", ".ruff_cache/", "a/.DS_Store"] {
            try expect(WorktreeContents.isRegenerable(path), "a cache: \(path)")
        }
        for path in ["artifacts/", "dist/", "build/", "target/", ".env", "scratch.txt", "notes/node_modules_backup/", "tools/venv/"] {
            try expect(!WorktreeContents.isRegenerable(path), "not a cache: \(path)")
        }
    }
}

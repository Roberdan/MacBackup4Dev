import Foundation

/// 4.1: a new Mac with another user name gets the old home rewritten in restored config files.
struct HomeRewriteTests {
    let safety = SafetyTests()

    func test_onlyWholePathComponentsAreReplaced() throws {
        let r = HomeRewrite(from: "/Users/roberdan", to: "/Users/rob")
        try expectEqual(r.apply(to: "export PATH=/Users/roberdan/.local/bin:$PATH"), "export PATH=/Users/rob/.local/bin:$PATH", "inside a PATH")
        try expectEqual(r.apply(to: "\"/Users/roberdan\""), "\"/Users/rob\"", "quoted home")
        try expectEqual(r.apply(to: "/Users/roberdanX/file"), "/Users/roberdanX/file", "another user that starts the same is untouched")
        try expectEqual(r.apply(to: "cd /Users/roberdan"), "cd /Users/rob", "at the end")
    }

    func test_textAndBinaryPlistAreRewrittenOthersLeftAlone() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let r = HomeRewrite(from: "/Users/old", to: "/Users/new")
        let text = box.root.appendingPathComponent("zshrc").path
        try "source /Users/old/.config/zsh/x.zsh\n".write(toFile: text, atomically: true, encoding: .utf8)
        try expect(r.rewriteFile(atPath: text), "text rewritten")
        try expectEqual(try String(contentsOfFile: text, encoding: .utf8), "source /Users/new/.config/zsh/x.zsh\n", "content")

        let plist = box.root.appendingPathComponent("agent.plist")
        let dict: [String: Any] = ["Label": "x", "ProgramArguments": ["/Users/old/bin/tool", "--flag"]]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0).write(to: plist)
        try expect(r.rewriteFile(atPath: plist.path), "binary plist rewritten")
        let back = NSDictionary(contentsOf: plist) as? [String: Any]
        try expectEqual(back?["ProgramArguments"] as? [String], ["/Users/new/bin/tool", "--flag"], "paths inside the plist")

        let binary = box.root.appendingPathComponent("blob").path
        var data = Data([0, 1, 2, 0]); data.append(Data("/Users/old".utf8))
        try data.write(to: URL(fileURLWithPath: binary))
        try expect(!r.rewriteFile(atPath: binary), "binary file never touched")
    }

    func test_newUserGetsRewrittenConfigOnRestore() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let snap = box.root.appendingPathComponent("2026-10-07_120000")
        try safety.write("export X=/Users/oldname/bin\n", to: snap.path + "/.zshrc")
        try safety.write(#"{"hostname":"a","serialNumber":"b","macOSVersion":"c","arch":"d","timestamp":"e","home":"/Users/oldname"}"#,
                         to: snap.path + "/metadata.json")
        try expectEqual(HomeRewrite.oldHome(snapshot: snap), "/Users/oldname", "old home from metadata")
        let newHome = box.root.appendingPathComponent("newhome").path
        try FileManager.default.createDirectory(atPath: newHome, withIntermediateDirectories: true)
        let shell = NewMacRestore.stages(snapshot: snap, config: nil).first { $0.id == "shell" }!
        _ = NewMacRestore.runStage(shell, snapshot: snap, home: newHome, dryRun: false, shellCheck: { _ in nil })
        try expectEqual(try String(contentsOfFile: newHome + "/.zshrc", encoding: .utf8), "export X=\(newHome)/bin\n",
                        "the restored .zshrc points at the new home")
        // Undo still works on a rewritten file (its stamp is taken after the rewrite).
        _ = NewMacRestore.undoStage("shell", home: newHome)
        try expect(!FileManager.default.fileExists(atPath: newHome + "/.zshrc"), "rewritten file undone")
    }

    func test_oldHomeGuessedForOlderSnapshots() throws {
        let box = try safety.makeSandbox(); defer { safety.cleanup(box) }
        let snap = box.root.appendingPathComponent("s")
        try safety.write("a /Users/mario/x\nb /Users/mario/y\nc /Users/Shared/z\n", to: snap.path + "/.zshrc")
        try expectEqual(HomeRewrite.oldHome(snapshot: snap), "/Users/mario", "most frequent /Users/<name>, never Shared")
        try expectNil(HomeRewrite.make(snapshot: snap, newHome: "/Users/mario"), "same user: nothing to rewrite")
    }
}

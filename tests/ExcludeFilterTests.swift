import Foundation

final class ExcludeFilterTests {
    func test_mandatoryCachesWithOldConfig() throws {
        let filter = ExcludeFilter(patterns: [])
        for path in ["GitHub/app/node_modules/pkg/index.js", "GitHub/app/.yarn/cache/pkg.zip",
                     "GitHub/app/.gradle/caches/data", "GitHub/app/target/debug/app",
                     "GitHub/app/target/release/app", "GitHub/app/build/intermediates/data",
                     "GitHub/app/.pytest_cache/data", "GitHub/app/.ruff_cache/data",
                     "GitHub/app/.mypy_cache/data", "GitHub/app/__pycache__/mod.pyc",
                     "GitHub/app/.cache/data", "GitHub/app/.next/cache/data",
                     "GitHub/app/.turbo/data", "GitHub/app/file.tmp", "GitHub/app/file.swp",
                     ".rustybackup-pre-restore", ".rustybackup-pre-restore/old/undo.json"] {
            try expect(filter.isExcluded(relativePath: path), "Mandatory exclusion: \(path)")
            try expect(filter.shouldSkipDirectory(relativePath: path), "Prune excluded subtree: \(path)")
        }
        for path in ["GitHub/app/src/cache.swift", "GitHub/app/src/tempParser.ts",
                     "GitHub/app/.git/objects/local-commit", "GitHub/app/.env",
                     "GitHub/app/package-lock.json", "GitHub/app/Cargo.lock",
                     "GitHub/app/data.sqlite", "GitHub/app/training.jsonl",
                     "GitHub/app/target/debugger/main.rs", "GitHub/app/.gradle/gradle.properties",
                     "GitHub/app/.yarnrc.yml", "GitHub/app/build/source.swift",
                     "Documents/temp/report.docx", "GitHub/app/tmp/notes.md"] {
            try expect(!filter.isExcluded(relativePath: path), "Do not invent exclusions for real data: \(path)")
        }
    }

    func test_pluginCacheDirIsMandatoryExcludedDistinctFromDotCache() throws {
        // Found 2026-09-27: ".cache" (dotfile, already mandatory) did not cover a plugin
        // manager's own "cache" subdirectory (no leading dot) -- unlabeled .docx/.pptx/.xlsx
        // template assets in ~/.codex/plugins/cache/ tripped an org's endpoint-DLP block on
        // every backup run.
        let filter = ExcludeFilter(patterns: [])
        try expect(filter.isExcluded(relativePath: ".codex/plugins/cache/openai-templates/reference.docx"),
                   "plugin cache dir must be excluded even with an old/empty config.toml")
        try expect(filter.shouldSkipDirectory(relativePath: ".codex/plugins/cache"),
                   "cache subtree must be pruned, not just filtered file by file")
        // A file merely named "cache.ext" is real data, not the directory -- must survive.
        try expect(!filter.isExcluded(relativePath: "GitHub/app/src/cache.swift"),
                   "a file named cache.* is not the cache/ directory")
    }

    func test_sitePackagesOfficeAssetsAreMandatoryExcluded() throws {
        // Found 2026-09-27, same endpoint-DLP trigger as the plugin cache dirs above, but
        // from installed Python packages instead: python-pptx/python-docx ship a default
        // template, and statsmodels ships .xls test fixtures, both inside site-packages.
        let filter = ExcludeFilter(patterns: [])
        for path in [".venvs/py314/lib/python3.14/site-packages/pptx/templates/default.pptx",
                     ".venvs/py314/lib/python3.14/site-packages/docx/templates/default.docx",
                     ".claude-science/conda/pkgs/statsmodels-0.15.0/lib/python3.11/site-packages/"
                     + "statsmodels/datasets/macrodata/src/macrodata.xls/macrodata.xls",
                     ".claude-science/conda/envs/python/lib/python3.11/site-packages/"
                     + "statsmodels/tsa/tests/results/test_spec.xls"] {
            try expect(filter.isExcluded(relativePath: path), "site-packages office asset: \(path)")
        }
        // A real document that merely lives near a directory named "site-packages" (not
        // inside it) must not be swept up by the same pattern.
        try expect(!filter.isExcluded(relativePath: "GitHub/app/site-packages-notes/report.docx"),
                   "must not match a sibling directory that only shares the name as a prefix")
    }

    func test_checkoutsAreMandatoryExcludedEvenWithOldConfig() throws {
        let filter = ExcludeFilter(patterns: [])
        try expect(filter.isExcluded(relativePath: ".gbrain/checkouts/Roberdan/roberdan-os/file.md"),
                   "Re-clonable checkouts must be excluded regardless of what an old config.toml has on disk")
        try expect(filter.shouldSkipDirectory(relativePath: ".gbrain/checkouts"),
                   "checkouts subtree must be pruned, not just filtered file by file")
    }

    func test_nestedMultiComponentPatterns() throws {
        let filter = ExcludeFilter(patterns: [".git/objects", "custom/cache"])
        try expect(filter.isExcluded(relativePath: "GitHub/app/.git/objects/pack/data"), "Nested configured paths must match")
        try expect(filter.shouldSkipDirectory(relativePath: "GitHub/app/custom/cache"), "Nested directories must be pruned")
        try expect(!filter.isExcluded(relativePath: "GitHub/app/custom/cache-source/main.swift"), "Respect component boundaries")
    }

    func test_wildcardStar() throws {
        try expect(ExcludeFilter.globMatch(pattern: "*.tmp", text: "file.tmp"), "*.tmp should match file.tmp")
        try expect(ExcludeFilter.globMatch(pattern: "*.tmp", text: "report.tmp"), "*.tmp should match report.tmp")
        try expect(!ExcludeFilter.globMatch(pattern: "*.tmp", text: "file.txt"), "*.tmp should not match file.txt")
        try expect(!ExcludeFilter.globMatch(pattern: "*.tmp", text: "tmp"), "*.tmp should not match tmp")
    }

    func test_wildcardQuestion() throws {
        try expect(ExcludeFilter.globMatch(pattern: "file?.txt", text: "file1.txt"), "file?.txt should match file1.txt")
        try expect(ExcludeFilter.globMatch(pattern: "file?.txt", text: "fileA.txt"), "file?.txt should match fileA.txt")
        try expect(!ExcludeFilter.globMatch(pattern: "file?.txt", text: "file12.txt"), "file?.txt should not match file12.txt")
        try expect(!ExcludeFilter.globMatch(pattern: "file?.txt", text: "file.txt"), "file?.txt should not match file.txt")
    }

    func test_componentMatch() throws {
        let filter = ExcludeFilter(patterns: ["node_modules"])
        try expect(filter.isExcluded(relativePath: "node_modules/package/index.js"), "node_modules should match at root")
        try expect(filter.isExcluded(relativePath: "projects/app/node_modules/pkg/lib.js"), "node_modules should match at depth")
        try expect(!filter.isExcluded(relativePath: "projects/app/src/main.js"), "src path should not be excluded")
    }

    func test_pathPrefixMatch() throws {
        let filter = ExcludeFilter(patterns: ["Library/Caches"])
        try expect(filter.isExcluded(relativePath: "Library/Caches/com.apple/data"), "Library/Caches prefix should match child")
        try expect(filter.isExcluded(relativePath: "Library/Caches"), "Library/Caches should match exact path")
        try expect(!filter.isExcluded(relativePath: "Library/CachesExtended/data"), "boundary prefix should not overmatch")
    }

    func test_notExcluded() throws {
        let filter = ExcludeFilter(patterns: ["*.tmp", "node_modules", ".DS_Store"])
        try expect(!filter.isExcluded(relativePath: "Documents/report.pdf"), "report.pdf should not be excluded")
        try expect(!filter.isExcluded(relativePath: "src/main.swift"), "main.swift should not be excluded")
    }

    func test_directorySkip() throws {
        let filter = ExcludeFilter(patterns: ["node_modules", "Library/Caches"])
        try expect(filter.shouldSkipDirectory(relativePath: "node_modules"), "node_modules should be skipped")
        try expect(filter.shouldSkipDirectory(relativePath: "Library/Caches"), "Library/Caches should be skipped")
        try expect(!filter.shouldSkipDirectory(relativePath: "Documents"), "Documents should not be skipped")
    }

    func test_dotPatterns() throws {
        let filter = ExcludeFilter(patterns: [".DS_Store", ".Spotlight-*"])
        try expect(filter.isExcluded(relativePath: ".DS_Store"), ".DS_Store should match")
        try expect(filter.isExcluded(relativePath: "some/dir/.DS_Store"), "nested .DS_Store should match")
        try expect(filter.isExcluded(relativePath: ".Spotlight-V100"), ".Spotlight-* should match")
    }

    func test_globMatchesOriginalSemantics() throws {
        func strings(_ alphabet: [String], depth: Int) -> [String] {
            var all = [""]
            var level = [""]
            for _ in 0..<depth {
                level = level.flatMap { prefix in alphabet.map { prefix + $0 } }
                all.append(contentsOf: level)
            }
            return all
        }
        let patterns = strings(["a", "/", "*", "?"], depth: 4)
        let texts = strings(["a", "b", "/"], depth: 4)
        for pattern in patterns {
            for text in texts {
                try expectEqual(ExcludeFilter.globMatch(pattern: pattern, text: text),
                                referenceGlob(pattern: pattern, text: text),
                                "glob semantics: \(pattern) vs \(text)")
            }
        }
        for (pattern, text) in [("?.txt", "é.txt"), ("?.txt", "👩‍💻.txt"),
                                ("*.tmp", "*x.tmp"), ("**/*.txt", "a/b/c.txt"),
                                ("a*?b", "a/b"), ("a/*/b", "a/x/y/b")] {
            try expectEqual(ExcludeFilter.globMatch(pattern: pattern, text: text),
                            referenceGlob(pattern: pattern, text: text), "Unicode and slash boundaries")
        }
    }

    private func referenceGlob(pattern: String, text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var dp = Array(repeating: Array(repeating: false, count: t.count + 1), count: p.count + 1)
        dp[0][0] = true
        for i in p.indices {
            if p[i] == "*" { dp[i + 1][0] = dp[i][0] }
            for j in t.indices {
                if p[i] == "*" {
                    dp[i + 1][j + 1] = dp[i][j + 1] || (t[j] != "/" && dp[i + 1][j])
                } else if p[i] == "?" {
                    dp[i + 1][j + 1] = t[j] != "/" && dp[i][j]
                } else {
                    dp[i + 1][j + 1] = p[i] == t[j] && dp[i][j]
                }
            }
        }
        return dp[p.count][t.count]
    }
}

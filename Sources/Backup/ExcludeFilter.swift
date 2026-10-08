import Foundation

struct ExcludeFilter {
    /// Enforced even with an old or empty config; avoid broad data/source extensions.
    static let mandatoryPatterns = [
        ".DS_Store", ".Trash", ".Trashes", ".TemporaryItems",
        ".rustybackup-pre-restore",
        "node_modules", ".next", ".nuxt", ".svelte-kit",
        ".cache", ".parcel-cache", ".turbo", ".npm", ".pnpm-store",
        ".yarn/cache", ".yarn/unplugged",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".venv", ".tox", ".nox", "*.pyc", "*.pyo",
        ".build", "DerivedData", "build/intermediates", "target/debug", "target/release",
        ".gradle/caches", ".gradle/daemon", ".gradle/workers",
        // Re-clonable/re-downloadable working copies (e.g. ~/.gbrain/checkouts, 11 GB+).
        "checkouts",
        // "cache" (no dot) is a distinct literal from ".cache" above -- e.g. a plugin
        // manager's <tool>/plugins/cache/ (found 2026-09-27: unlabeled .docx/.pptx/.xlsx
        // template assets in there tripped an org's endpoint-DLP block during backup).
        "Caches", "cache", "GPUCache", "ShaderCache", "Code Cache",
        "*.tmp", "*.temp", "*.swp", "*.swo", "*~",
    ]

    /// Office-format sample/template assets bundled *inside* an installed Python package
    /// (python-docx's default.docx, python-pptx's default.pptx, statsmodels' .xls test
    /// fixtures, ...). Pip/conda-reinstallable, never the user's own documents -- same
    /// endpoint-DLP "copying unlabeled office files" trigger as the plugin cache dirs
    /// above (found 2026-09-27). Handled separately from mandatoryPatterns/globMatch: '*'
    /// there is deliberately barred from crossing '/' (see globMatch), and the package's
    /// own subdirectory sits between "site-packages" and the file (.../site-packages/pptx/
    /// templates/default.pptx), so a single-"*" glob pattern can never reach it.
    private static let vendoredOfficeExtensions: Set<String> = ["docx", "pptx", "xlsx", "xls", "xlsb"]

    private static func isVendoredOfficeAsset(pathComponents: [String]) -> Bool {
        guard let fileName = pathComponents.last,
              vendoredOfficeExtensions.contains((fileName as NSString).pathExtension.lowercased())
        else { return false }
        return pathComponents.dropLast().contains("site-packages")
    }

    let patterns: [String]

    /// Single-component literal patterns ("node_modules", "logs"). Matching these is a
    /// set lookup per path component instead of a glob run per pattern, which is the
    /// difference between seconds and minutes on a large tree.
    private let literalComponents: Set<String>
    /// Everything else: wildcards and multi-component paths.
    private struct Glob {
        private enum Matcher {
            case literal(String)
            case prefix(String)
            case suffix(String)
            case wildcard([Character])
        }
        private let matcher: Matcher

        init(_ pattern: String) {
            if !ExcludeFilter.hasWildcards(pattern) {
                matcher = .literal(pattern)
            } else if !pattern.contains("?"), pattern.first == "*", !pattern.dropFirst().contains("*") {
                matcher = .suffix(String(pattern.dropFirst()))
            } else if !pattern.contains("?"), pattern.last == "*", !pattern.dropLast().contains("*") {
                matcher = .prefix(String(pattern.dropLast()))
            } else {
                matcher = .wildcard(Array(pattern))
            }
        }

        func matches(_ text: String, characters: inout [Character]?) -> Bool {
            switch matcher {
            case .literal(let value):
                return value == text
            case .prefix(let value):
                return text.hasPrefix(value) && !text.dropFirst(value.count).contains("/")
            case .suffix(let value):
                return text.hasSuffix(value) && !text.dropLast(value.count).contains("/")
            case .wildcard(let pattern):
                let textCharacters = characters ?? Array(text)
                characters = textCharacters
                return ExcludeFilter.wildcardMatch(pattern: pattern, text: textCharacters)
            }
        }
    }

    private struct ComplexPattern {
        let glob: Glob
        let components: [Glob]
        let matchesComponent: Bool
        let literalPrefix: String?
    }
    private let complexPatterns: [ComplexPattern]

    init(patterns: [String]) {
        let effective = Array(Set(patterns + Self.mandatoryPatterns)).sorted()
        self.patterns = effective
        var literals: Set<String> = []
        var complex: [ComplexPattern] = []
        for raw in effective {
            let pattern = Self.normalizePath(raw)
            if pattern.isEmpty { continue }
            if !Self.hasWildcards(pattern) && !pattern.contains("/") {
                literals.insert(pattern)
            } else {
                complex.append(ComplexPattern(glob: Glob(pattern),
                                              components: Self.pathComponents(pattern).map(Glob.init),
                                              matchesComponent: !pattern.contains(Character("/")),
                                              literalPrefix: Self.hasWildcards(pattern) ? nil : pattern + "/"))
            }
        }
        self.literalComponents = literals
        self.complexPatterns = complex
    }

    /// Check if a relative path should be excluded from backup.
    /// Three-level matching:
    /// 1. Full relative path match: "Library/Caches" matches "Library/Caches/foo/bar"
    /// 2. Path component match: "node_modules" matches "projects/app/node_modules/pkg/index.js"
    /// 3. Directory prefix match at boundary: ".git/objects" matches ".git/objects/pack/data"
    func isExcluded(relativePath: String) -> Bool {
        let path = Self.normalizePath(relativePath)
        let pathComponents = Self.pathComponents(path)

        for component in pathComponents where literalComponents.contains(component) {
            return true
        }

        if Self.isVendoredOfficeAsset(pathComponents: pathComponents) {
            return true
        }

        var characters: [Character]?
        var componentCharacters = Array<[Character]?>(repeating: nil, count: pathComponents.count)
        for entry in complexPatterns {
            // 1) Full path match (glob) + direct subtree inclusion for literal paths.
            if entry.glob.matches(path, characters: &characters) {
                return true
            }
            if let prefix = entry.literalPrefix, path.hasPrefix(prefix) {
                return true
            }

            // 2) Component match.
            if entry.matchesComponent {
                for index in pathComponents.indices {
                    if entry.glob.matches(pathComponents[index], characters: &componentCharacters[index]) {
                        return true
                    }
                }
            }

            // 3) Directory prefix match on component boundaries.
            if entry.components.count > 1,
               Self.componentPrefixMatch(patternComponents: entry.components, pathComponents: pathComponents,
                                         characters: &componentCharacters) {
                return true
            }
        }

        return false
    }

    /// Check if a directory should be skipped entirely (don't descend).
    /// Used by FileManager.enumerator to skip entire subtrees.
    func shouldSkipDirectory(relativePath: String) -> Bool {
        let path = Self.normalizePath(relativePath)
        let pathComponents = Self.pathComponents(path)

        for component in pathComponents where literalComponents.contains(component) {
            return true
        }

        var characters: [Character]?
        var componentCharacters = Array<[Character]?>(repeating: nil, count: pathComponents.count)
        for entry in complexPatterns {
            // Direct directory match.
            if entry.glob.matches(path, characters: &characters) {
                return true
            }

            // Match directory names anywhere in the current path.
            if entry.matchesComponent {
                for index in pathComponents.indices {
                    if entry.glob.matches(pathComponents[index], characters: &componentCharacters[index]) {
                        return true
                    }
                }
            }

            // Match pattern as a path prefix at component boundaries.
            if entry.components.count > 1,
               Self.componentPrefixMatch(patternComponents: entry.components, pathComponents: pathComponents,
                                         characters: &componentCharacters) {
                return true
            }
        }

        return false
    }

    /// Glob pattern matching supporting * and ? wildcards.
    /// * matches any sequence of characters (including empty)
    /// ? matches exactly one character
    static func globMatch(pattern: String, text: String) -> Bool {
        var characters: [Character]?
        return Glob(pattern).matches(text, characters: &characters)
    }

    private static func wildcardMatch(pattern p: [Character], text t: [Character]) -> Bool {
        var pi = 0
        var ti = 0
        var star: Int?
        var starEnd = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                star = pi
                starEnd = ti
                pi += 1
            } else if pi < p.count, p[pi] == t[ti] || (p[pi] == "?" && t[ti] != "/") {
                pi += 1
                ti += 1
            } else if let star, starEnd < t.count, t[starEnd] != "/" {
                // Retry only within this path component: '*' must never consume '/'.
                starEnd += 1
                ti = starEnd
                pi = star + 1
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private static func normalizePath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == "." ? "" : path
    }

    private static func pathComponents(_ path: String) -> [String] {
        guard !path.isEmpty else {
            return []
        }
        return path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func hasWildcards(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    private static func componentPrefixMatch(patternComponents: [Glob], pathComponents: [String],
                                             characters: inout [[Character]?]) -> Bool {
        guard !patternComponents.isEmpty, patternComponents.count <= pathComponents.count else {
            return false
        }

        for start in 0...(pathComponents.count - patternComponents.count) {
            var matches = true
            for index in patternComponents.indices {
                let pathIndex = start + index
                if !patternComponents[index].matches(pathComponents[pathIndex], characters: &characters[pathIndex]) {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }
}

import Foundation

/// A new Mac with another user name (4.1): configuration files often contain the old home
/// written out in full (`/Users/roberdan/...`: LaunchAgents, shell files, tool configs). On
/// restore, text files and property lists get the old home replaced by the new one; anything
/// else is copied as it is. Only `/Users/<old>` followed by `/`, a quote or the end of a
/// token is replaced, so `/Users/roberdanX` is never touched.
struct HomeRewrite: Equatable {
    let from: String
    let to: String

    /// nil when there is nothing to rewrite (same home, or the old one is unknown).
    static func make(snapshot: URL, newHome: String) -> HomeRewrite? {
        guard let old = oldHome(snapshot: snapshot), old != newHome else { return nil }
        return HomeRewrite(from: old, to: newHome)
    }

    /// The home of the Mac that made the snapshot: written in metadata.json since 4.1, guessed
    /// for older snapshots from the most frequent `/Users/<name>` in its LaunchAgents and shell
    /// files.
    static func oldHome(snapshot: URL) -> String? {
        if let data = try? Data(contentsOf: snapshot.appendingPathComponent("metadata.json")),
           let meta = try? JSONDecoder().decode(MachineID.self, from: data), let home = meta.home, !home.isEmpty {
            return home
        }
        var counts: [String: Int] = [:]
        let fm = FileManager.default
        var files = [".zshrc", ".zprofile", ".bashrc", ".gitconfig"].map { snapshot.appendingPathComponent($0) }
        let agents = snapshot.appendingPathComponent("Library/LaunchAgents")
        files += ((try? fm.contentsOfDirectory(atPath: agents.path)) ?? []).map { agents.appendingPathComponent($0) }
        for file in files {
            guard let text = textOf(file) else { continue }
            let regex = try? NSRegularExpression(pattern: #"/Users/([A-Za-z0-9._-]+)"#)
            for m in regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                guard let r = Range(m.range(at: 1), in: text), text[r] != "Shared" else { continue }
                counts["/Users/" + text[r], default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func textOf(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000 else { return nil }
        if data.starts(with: Array("bplist".utf8)),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            return String(data: xml, encoding: .utf8)
        }
        guard !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the old home in a string (only as a whole path component).
    func apply(to text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: from)
        guard let regex = try? NSRegularExpression(pattern: escaped + #"(?=[/"'\s:;,)<\]]|$)"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: to))
    }

    /// Rewrites the file in place when it is a text file or a property list holding the old
    /// home. Returns true when it changed. Binary files and big files are left alone.
    @discardableResult
    func rewriteFile(atPath path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path), data.count < 2_000_000,
              data.range(of: Data(from.utf8)) != nil || data.starts(with: Array("bplist".utf8)) else { return false }
        if data.starts(with: Array("bplist".utf8)) {
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [.mutableContainersAndLeaves], format: &format) else { return false }
            let rewritten = rewrite(plist)
            guard !(rewritten as AnyObject).isEqual(plist),
                  let out = try? PropertyListSerialization.data(fromPropertyList: rewritten, format: format, options: 0) else { return false }
            return (try? out.write(to: URL(fileURLWithPath: path))) != nil
        }
        guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else { return false }
        let new = apply(to: text)
        guard new != text else { return false }
        return (try? new.write(toFile: path, atomically: false, encoding: .utf8)) != nil
    }

    private func rewrite(_ value: Any) -> Any {
        switch value {
        case let s as String: return apply(to: s)
        case let a as [Any]: return a.map { rewrite($0) }
        case let d as [String: Any]: return d.mapValues { rewrite($0) }
        default: return value
        }
    }
}

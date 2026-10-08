import Foundation
import Darwin

struct FileEntry {
    let relativePath: String
    let absolutePath: String
    let size: UInt64
    let mtime: Date
}

/// Streaming file scanner -- yields files one at a time via callback.
/// Never loads entire file tree into memory.
/// Skips symbolic links to prevent loops and TCC-protected target access.
/// Bird-safe: yields in batches with micro-pauses to avoid triggering
/// iCloud eviction cascades (CCC uses similar technique).
enum FileScanner {
    /// Bird-safe: pause every N files to let iCloud daemon settle.
    /// 100ms on battery (conservative), 5ms on AC (20x faster).
    static let BIRD_SAFE_BATCH_SIZE = 50
    static let BIRD_SAFE_PAUSE_US: UInt32 = IOPriority.isOnBattery() ? 100_000 : 5_000
    static func walk(
        sources: [URL],
        basePaths: [String],
        excludeFilter: ExcludeFilter,
        onTraversalError: ((String, Error) -> Void)? = nil,
        handler: (FileEntry) -> Bool
    ) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
                                       .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)

        for (index, source) in sources.enumerated() {
            // Always use HOME as base — ensures snapshot preserves full relative paths
            // e.g. ~/GitHub/MyRepo/file.swift → "GitHub/MyRepo/file.swift" (not "file.swift")
            let basePath = basePaths[index].hasSuffix("/") ? basePaths[index] : basePaths[index] + "/"
            // Outside the home, keep the absolute path without its leading "/".
            let sourceRelativePath = source.path.hasPrefix(basePath)
                ? String(source.path.dropFirst(basePath.count)) : String(source.path.drop(while: { $0 == "/" }))
            guard !excludeFilter.isExcluded(relativePath: sourceRelativePath) else { continue }
            // The source existed when the backup started: gone now means data not saved.
            guard FileManager.default.fileExists(atPath: source.path) else {
                onTraversalError?(source.path, NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                    userInfo: [NSLocalizedDescriptionKey: "Cartella sparita durante il backup"]))
                continue
            }
            // Check if source is a single file (not a directory)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir)
            if !isDir.boolValue {
                guard let values = try? source.resourceValues(forKeys: keySet),
                      values.isSymbolicLink != true,
                      let size = values.fileSize,
                      let mtime = values.contentModificationDate else { continue }
                // Use home-relative path for single files too
                let rel: String
                if source.path.hasPrefix(basePath) {
                    rel = String(source.path.dropFirst(basePath.count))
                } else {
                    // Outside the home: keep the whole path, never only the name (collisions).
                    rel = String(source.path.drop(while: { $0 == "/" }))
                }
                let entry = FileEntry(
                    relativePath: rel,
                    absolutePath: source.path,
                    size: UInt64(size),
                    mtime: mtime
                )
                if !handler(entry) { return }
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: source,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                // F-08: Record traversal errors instead of silently swallowing them.
                // Distinguishes permission skips from genuine I/O failures.
                errorHandler: { url, error in
                    onTraversalError?(url.path, error)
                    return true  // continue traversal past unreadable entries
                }
            ) else {
                onTraversalError?(source.path, NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: "Cartella non leggibile"]))
                continue
            }

            // The enumerator may hand back resolved paths (/private/var for /var, a symlinked
            // parent folder). Never fall back to the bare file name: two files with the same
            // name in different folders would overwrite each other in the snapshot.
            let resolvedBase = realPath(basePath) + "/"
            let resolvedSource = realPath(source.path) + "/"
            var batchCount = 0
            while let url = enumerator.nextObject() as? URL {
                let fullPath = url.path
                let relativePath: String
                if fullPath.hasPrefix(basePath) {
                    relativePath = String(fullPath.dropFirst(basePath.count))
                } else if fullPath.hasPrefix(resolvedBase) {
                    relativePath = String(fullPath.dropFirst(resolvedBase.count))
                } else if fullPath.hasPrefix(resolvedSource) {
                    relativePath = sourceRelativePath + "/" + String(fullPath.dropFirst(resolvedSource.count))
                } else {
                    relativePath = sourceRelativePath + "/" + url.lastPathComponent
                }

                // Skip iCloud placeholder files (evicted by bird)
                if url.lastPathComponent.hasSuffix(".icloud") && url.lastPathComponent.hasPrefix(".") {
                    continue
                }

                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: keySet)
                } catch {
                    // A temp file deleted between listing and reading is normal; anything
                    // else that cannot be read is data not saved (review H3).
                    if FileManager.default.fileExists(atPath: fullPath) { onTraversalError?(fullPath, error) }
                    continue
                }
                let isDirectory = values.isDirectory == true

                // `skipDescendants()` must only ever be called for a directory. Calling it
                // after a FILE skips the next subdirectory the enumerator was about to
                // descend into — and the whole subtree vanishes from the backup without a
                // single error. An excluded file sitting next to a real directory (a
                // `.DS_Store` before `zzArchive/`, a `*.log` before a source folder) was
                // enough to silently drop everything inside it.
                if isDirectory && excludeFilter.shouldSkipDirectory(relativePath: relativePath) {
                    enumerator.skipDescendants()
                    continue
                }
                if excludeFilter.isExcluded(relativePath: relativePath) {
                    continue
                }

                // Skip symbolic links entirely
                if values.isSymbolicLink == true {
                    if isDirectory { enumerator.skipDescendants() }
                    continue
                }

                guard values.isRegularFile == true,
                      let size = values.fileSize,
                      let mtime = values.contentModificationDate else {
                    continue
                }

                let entry = FileEntry(
                    relativePath: relativePath,
                    absolutePath: fullPath,
                    size: UInt64(size),
                    mtime: mtime
                )
                if !handler(entry) { return }

                // Bird-safe: pause every N files to let iCloud settle
                batchCount += 1
                if batchCount >= BIRD_SAFE_BATCH_SIZE {
                    batchCount = 0
                    usleep(BIRD_SAFE_PAUSE_US)
                }
            }
        }
    }

    /// Canonical path through realpath(3). Unlike `resolvingSymlinksInPath`, it keeps the
    /// `/private` prefix that the enumerator itself reports for /var and /tmp.
    static func realPath(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let resolved = Darwin.realpath(trimmed, nil) else { return trimmed }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

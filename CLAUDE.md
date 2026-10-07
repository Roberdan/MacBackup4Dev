# CLAUDE.md — RustyMacBackup

## Project

Native macOS backup app (Swift, AppKit/SwiftUI). Single `.app` binary that acts as both menu bar app and CLI tool. No external dependencies. Target: macOS 14+ arm64.

**Product**: whitelist-only incremental backup with hard links. Time Machine alternative for MDM-restricted Macs. Dev-tool configs + arbitrary folders.

## Build & Test

```bash
./build.sh              # compile + sign → build/RustyMacBackup.app
./run-tests.sh          # 96 tests → build/RustyMacBackupTests
./build-pkg.sh          # creates .pkg installer
```

Version is set in one place: `VERSION` default in `build.sh`. `build-pkg.sh` reads it, the release workflow overrides it from the `v*` tag, and the CLI reads `CFBundleShortVersionString` at runtime.

## Module Map

```
Sources/
  App/          AppDelegate, main, StatusManager, AutoUpdater, IconManager, MenuBuilder
  Backup/       BackupEngine(+Helpers), HardLinker, FileScanner, RestoreEngine,
                RetentionManager, SnapshotCleanup, DestinationLock, ExcludeFilter, EnvironmentSnapshot, StatusModels, BackupTypes,
                SnapshotManifest (+SnapshotCatalog), GitSafety, DatabaseDumps, CoverageAuditor,
                SelectiveRestore (+Topics, FileVersions), NewMacRestore, ProtectionSummary, Shell
  Config/       ConfigManager, ConfigDiscovery, ScheduleManager
  CLI/          CLIHandler, CLIRestore (3.0 commands), PruneOptions
  Diagnostics/  Log, ErrorReporter, DiskDiagnostics, FDACheck
  UI/           PopoverView, RestoreCenter, TreeView, AppUIState, ProgressBarView,
                SnapshotPickerView, DesignTokens, TreeWindowController, PopoverViewController
```

## ⚠️ CRITICAL KNOWN TRAP — COPYFILE_CLONE DESTROYS SOURCE FILES

**Do NOT use `COPYFILE_CLONE` flag with `copyfile()` across different filesystems.**

When copying APFS → ExFAT/HFS+ (or any cross-volume operation), `COPYFILE_CLONE` silently degrades to a **move** — it deletes the source file. This has destroyed the developer's Mac multiple times.

**Current safe implementation** (`HardLinker.swift:26`):
```swift
// COPYFILE_ALL = DATA|XATTR|STAT|ACL = 0x0F  (NO CLONE!)
let flags = copyfile_flags_t(UInt32(0x0F))
```

**Never change this to use `COPYFILE_CLONE` (1<<24) or any clone flag.** Even if Apple docs suggest it for performance, it is unsafe for cross-volume operations. The README erroneously still mentions "APFS clone support" — that line is wrong, the feature was removed for safety.

## Architecture Decisions

- **Single binary**: CLI mode detected via `ProcessInfo.processInfo.arguments`. If args present → CLI, otherwise → menu bar app.
- **Hard links for deduplication**: `HardLinker.shouldHardLink()` checks size + mtime delta < 1.0s. Files identical to previous snapshot get hard-linked (zero space cost).
- **Snapshot naming**: `in-progress-YYYY-MM-DD_HHmmss` during backup, renamed to `YYYY-MM-DD_HHmmss` on success.
- **8 parallel workers**: `TaskGroup` bounded to 8 concurrent `processFile` tasks.
- **Status file**: `~/.local/share/rusty-mac-backup/status.json` — updated every 500 files.
- **Config**: `~/.config/rusty-mac-backup/config.toml`
- **Lock file**: `<destination>/rustymacbackup.lock` (PID-based, stale detection via `kill(pid, 0)`).

## 3.0 invariants (scar 2026-10-06 — do not weaken)

- **A snapshot is good only if its manifest says `complete: true`.** `SnapshotCatalog` is the
  single source for "which snapshot is good": restore defaults, retention protection and the
  menu all ask it. Never pick "the newest directory" anywhere else.
- **The scanner → copy queue must never drop entries.** `AsyncStream` stays `.unbounded`,
  bounded by the `QUEUE_LIMIT` semaphore. `bufferingNewest`/`bufferingOldest` drop silently.
- **Never fall back to the bare file name for a relative path** (`FileScanner`): use
  `realPath` (realpath(3)); `resolvingSymlinksInPath` strips `/private` and breaks prefixes.
- **Retention never deletes the 3 newest complete snapshots** and does nothing when the newest
  snapshot has a `shrinkWarning` (new or emptied Mac).
- **Restore writes beside the target and renames into place; undo.json lists replaced AND
  created files.** Tests must pass a temp `undoRoot`/`home`: never write into the real home.
- Tests run the real engine with `BackupRunOptions(home:)` and `StatusWriter(directory:)`
  pointed at a sandbox: never the user's status file.
- **The picker must never drop a configured source** (scar 2026-10-07): every
  `enabledPaths` entry discovery does not know is listed under "Le tue cartelle". "Tutti"
  never selects `sensitive` items. "Esegui ora" never opens the picker.
- **The popover's controller is the NSHostingController itself** (`sizingOptions =
  .preferredContentSize`). Never wrap it in another view controller: NSPopover then stays at
  320×320 and clips. Check layout changes with `RustyMacBackup measure-menu` (real popover),
  not only `render-menu` (content only).
- **The coverage audit never suggests credentials, `_parked` folders, caches/profiles or
  databases inside a tool's hidden folder** (`CoverageAuditor.isNoise`).

## Known Critical Issues (from 2026-03-20 audit)

Status 2026-10-06: P0.1, P0.2, P0.3, P0.5, P0.6 fixed (F-01…F-06); P0.4 mitigated (codesign
verify + rsync rollback; identity pinning still missing because CI releases are ad-hoc signed).

### P0 — Must fix before wide distribution

| ID | Location | Issue |
|----|----------|-------|
| P0.1 | `BackupEngine.swift:44-45` | `cleanStaleInProgress()` runs **before** lock acquisition — concurrent run can delete active in-progress dir |
| P0.2 | `BackupEngine.swift:191` | Cancelled backup still renames `in-progress-*` to final snapshot — partial backup looks valid |
| P0.3 | `BackupEngine+Helpers.swift:8-11` | Mount validation uses only `statfs()` — stale `/Volumes` mountpoint can redirect backup to internal disk |
| P0.4 | `AutoUpdater.swift:51-89` | Updater does `rsync --delete` with no signature verification and no rollback |
| P0.5 | `RestoreEngine.swift:118-123,173-210` | Undo restore replaces entire top-level dirs, not individual files — can destroy newer files |
| P0.6 | `BackupEngine+Helpers.swift:67-80` | Error categories use Swift type names as keys; `ErrorReporter` expects semantic keys (`permission_denied` etc.) |

### P1 — High priority

- `HardLinker.swift:13`: mtime tolerance 1.0s can miss same-size edits — reduce significantly
- `FileScanner.swift:61-66`: traversal errors swallowed (errorHandler always returns `true`)
- Multiple `try? statusWriter.write(...)` silently drop persistence failures
- `RestoreEngine.swift`: restore has no free-space preflight
- `ScheduleManager.swift:57-74`: uses legacy `launchctl load/unload` — migrate to `bootstrap/bootout gui/<uid>`

## Forbidden Paths (hardcoded)

Never allow backup of: `Library/Mail`, `Library/Messages`, `Library/Safari`, `Library/Containers`, `Library/Mobile Documents`, `Library/Caches`, `/Library`, `/System`, `/etc`, `/Applications`, `/usr`, `/opt`, `/private`

`Library/CloudStorage` (OneDrive/Dropbox/Google Drive) is forbidden the same way but lives in
its own list (`ConfigDiscovery.cloudStoragePrefixes`), gated by `isForbidden(_:allowCloudStorage:)`
and `ProtectionConfig.includeCloudStorage` (config.toml only, no UI checkbox — see README
"CloudStorage opt-in"). Kept separate from the list above because the risk is different: a
sync-provider/DLP concern, not the daemon-crash one that applies to the others.

**The picker (`TreeSelectionModel.addCustomPath`, used by "Aggiungi percorso") must call
`isForbidden` before adding anything.** Before 2026-09-27 it didn't: `NSOpenPanel` lets the
user browse anywhere, so a forbidden path (e.g. CloudStorage) would show up checked in the
tree even though `BackupEngine` would still block it at run time — confusing, and the origin
of a real bug report ("why is OneDrive even in the list").

## UI State

- `AppUIState.hasBackups` calls `RestoreEngine.findBackupSnapshots()` as a computed property — **disk I/O in view layer**. Do not make it worse; cache this.
- Stop button sets UI to idle before engine fully drains — expected, tracked as P2.

## Testing

Tests live in `tests/`. Run via `./run-tests.sh` (96 tests). No SPM/Xcode project — raw `swiftc` compilation.
Covers: ExcludeFilter, Retention, Config parsing, BackupEngine, HardLinker, legacy config migration,
and (3.0) SafetyTests (real engine runs in a sandbox), RestoreTests, ProtectionSummaryTests.

# RustyMacBackup

> A native macOS menu-bar app that backs up your developer environment to an external disk — safely, incrementally, and without Full Disk Access.

Built for developers who live in the terminal and need a reliable, transparent backup of their configs, dotfiles, SSH keys, and project repos. Not a replacement for Time Machine — a complement to it.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green) ![Version](https://img.shields.io/badge/version-2.2.0-brightgreen)

---

## Why

Time Machine doesn't work on MDM-managed Macs. iCloud doesn't back up `~/.ssh` or `~/GitHub`. Cloud sync services fight with `node_modules` and `.git`. Git doesn't back up your shell config.

RustyMacBackup solves the problem that every developer has but nobody talks about: **your muscle memory lives in dotfiles, and they're never backed up.**

---

## How It Works

```
External Disk
└── RustyMacBackup/
    ├── 2026-03-20T14:32:00/    ← snapshot (hard-linked, incremental)
    │   ├── .zshrc
    │   ├── .gitconfig
    │   ├── .ssh/config
    │   ├── .config/nvim/
    │   └── GitHub/MyProject/
    ├── 2026-03-19T08:00:00/    ← yesterday (unchanged files = zero extra space)
    └── status.json             ← live progress / last result
```

Each backup creates a timestamped snapshot. **Unchanged files are hard-linked** from the previous snapshot — so 100 snapshots of a 2 GB config tree might use only 2.1 GB total. Changed files are copied with full attribute preservation (`copyfile()` with DATA|XATTR|STAT|ACL flags).

> ⚠️ **`COPYFILE_CLONE` is intentionally disabled.** On macOS, APFS cloning silently becomes a destructive *move* when source and destination are on different filesystems (APFS → ExFAT/HFS+). We've seen this destroy entire home directories. We use `copyfile()` with `COPYFILE_ALL = 0x0F` only.

Backups run:
- **On demand** — menu bar button or `rustyback backup`
- **On schedule** — via macOS `LaunchAgent` (hourly, daily, or custom interval)
- **Automatically stopped** on disk eject or low battery

---

## What Gets Backed Up

The app auto-discovers installed tools on first launch. You confirm what to include via a SwiftUI tree with collapsible categories and tri-state checkboxes.

| Category | Auto-discovered paths |
|----------|-----------------------|
| **Shell** | `.zshrc`, `.bashrc`, `.bash_profile`, `.config/fish/` |
| **Git** | `.gitconfig`, `.gitignore_global`, `.gitmessage` |
| **SSH** | `.ssh/config`, `.ssh/known_hosts` *(NOT private keys — by design)* |
| **Terminal** | Ghostty, Warp, iTerm2, Alacritty, kitty, tmux, zellij |
| **Editor** | Neovim, Vim, Emacs, VS Code, Cursor, Zed, Sublime Text |
| **Dev Tools** | starship, direnv, mise/asdf, Cargo config, Brewfile |
| **AI Tools** | Claude CLI settings, Ollama config |
| **Cloud/Auth** | Tailscale, 1Password CLI config |
| **macOS** | Dock prefs, Finder prefs, keyboard shortcuts |
| **App Configs** | Every hidden folder in your home (`~/.codex`, `~/.docker`, `~/.terraform.d`, …) that holds configuration rather than data |
| **Repos** | `~/GitHub`, `~/Developer`, `~/Projects` — or any custom path |
| **Custom** | Any file or folder you add via the `+` button |

### Configuration, Not Data

Hidden folders in your home directory are picked up automatically, so a tool you install
tomorrow is backed up without editing any list. What is *not* configuration is filtered out
in two passes:

1. **By name** — package registries and downloaded runtimes (`.npm`, `.cargo/registry`,
   `.rustup`, `.nuget`), model stores (`.ollama`, `.lmstudio`), caches, logs, browser
   profiles, `node_modules`, timestamped `.bak-*` copies.
2. **By size** — a folder over 200 MB once the exclusions are applied is data, not
   configuration. The scan opens it, finds the oversized part inside, and adds *that* to the
   exclusion list while still backing up the folder itself.

Folders that hold credentials (`.ssh`, `.gnupg`, `.aws`, `.azure`, `.docker`, `.npmrc`) are
detected but left **off by default** — you opt into them explicitly, exactly as before.

### What It Will Never Touch

These paths are hardcoded as forbidden and enforced at both the UI and engine level —
including the "Aggiungi percorso" picker, which now rejects them on add instead of
listing them as if they were backupable:

```
~/Library/Mail         ~/Library/Messages      ~/Library/Safari
~/Library/Containers   ~/Library/Caches
/Library   /System   /etc   /Applications   /usr   /opt   /private
```

`~/Library/CloudStorage` (OneDrive, Dropbox, Google Drive, …) is forbidden by the same
rule but for a different reason: not a daemon-crash risk, a *provider* one (a sync client
re-uploading a local copy, a company's DLP policy blocking the copy). See `[protection]`
below for the config-only opt-in.

No Full Disk Access required. No TCC prompts. No system file access.

---

## Installation

**From source (recommended for developers):**

```bash
git clone https://github.com/Roberdan/RustyMacBackup.git
cd RustyMacBackup
./install.sh        # builds with swiftc + installs to /Applications
```

Requires macOS 14+ (Sonoma) and Xcode Command Line Tools (`xcode-select --install`).

**From pkg installer:**

Download `RustyMacBackup-2.2.0-arm64.pkg` from [Releases](https://github.com/Roberdan/RustyMacBackup/releases) and double-click. No admin password needed after first install — auto-updates work in-place.

---

## Quick Start (CLI)

```bash
# Convenience alias
alias rustyback='/Applications/RustyMacBackup.app/Contents/MacOS/RustyMacBackup'

# First-time setup: discovers configs, picks destination disk
rustyback init

# See what configs are detected on this Mac
rustyback discover

# Run a backup now
rustyback backup

# Check live status + last result
rustyback status

# List snapshots
rustyback list
```

## CLI Reference

| Command | Description |
|---------|-------------|
| `discover` | Show all detected dev tool configs |
| `init` | Interactive setup: discover + pick disk |
| `backup` | Run backup now (foreground, with progress) |
| `stop` | Cancel a running backup |
| `status` | Live status, last result, folder list |
| `list` | List snapshots on disk |
| `prune [--dry-run \| --yes]` | Preview retention-policy cleanup; `--yes` deletes |
| `prune --older-than 1m\|6m\|1y [--dry-run \| --yes]` | Preview/delete snapshots older than 1 month, 6 months or 1 year |
| `restore <snapshot> [path] --to <dest>` | Restore files from a snapshot |
| `config show\|add\|remove\|edit` | Manage backed-up paths |
| `schedule on\|off\|interval <min>\|daily <hour>` | Manage LaunchAgent schedule |
| `errors [--all]` | Show categorised backup errors |
| `--version` | Print version |

---

## Configuration

### Freeing backup disk space

In the menu-bar app, choose **Libera spazio…**, then **1 mese**, **6 mesi**
or **1 anno**. The preview shows the destination, current free space, cutoff date and number
of snapshots. After deletion it reports the space actually freed, measured on the disk.
Nothing is deleted until you confirm **Elimina backup**; **Annulla** keeps everything.
This is a one-time cleanup, not a change to your scheduled retention policy.
The most recent snapshot is always kept, even if it is older than the selected period.

The same operation is available from the CLI:

```bash
rustyback prune --older-than 6m           # preview only
rustyback prune --older-than 6m --yes     # permanently delete after reviewing
```

Age refers to the snapshot date, not the modification dates of files inside it.
Periods use calendar months; snapshots exactly on the cutoff are retained.
Cleanup only removes complete, timestamp-named snapshot directories in the configured
destination, never source files, in-progress backups, symbolic links or unrelated folders.
Backup, restore and cleanup share a destination lock to prevent concurrent deletion.
Failures are reported rather than counted as successful removals. If a removal is interrupted,
its remaining files stay in a hidden `.deleting-*` directory, not a restorable snapshot;
the error includes that path for recovery. This operation does not empty those remnants.

**Space freed is not the sum of snapshot sizes:** unchanged files are hard-linked.
Their space is recovered only after the last snapshot referencing them is removed.
Cache data already in retained snapshots is left intact; exclusions apply to future backups.

### Cache and temporary-file exclusions

Known regenerable caches and temporary files are **always excluded**, including for old
configurations with an empty `[exclude]` list and explicitly selected source files/folders.
These include `node_modules`, `.next`, `.nuxt`, `.svelte-kit`, `.cache`, `.parcel-cache`,
`.turbo`, `.npm`, `.pnpm-store`, `.yarn/cache`, `.yarn/unplugged`, Python bytecode and
test/type-checker caches, `.venv`, `.tox`, `.nox`, Swift `.build`/`DerivedData`,
Rust `target/debug` and `target/release`, Android `build/intermediates`, Gradle runtime
caches, macOS cache folders, `tmp`, `temp`, `*.tmp`, `*.temp`, editor swap/backup files.
Multi-component exclusions work inside nested repositories too.

Your configured exclusions are added to this mandatory set. The mandatory rules do not
exclude source files merely because their names contain "cache" or "temp", nor do they
exclude `.env`, dependency lockfiles, databases, `.jsonl`, or Git history by themselves.
Existing configured/default exclusions still apply (including broader data/Git exclusions).
Generic folders named `tmp` or `temp` are *not* excluded automatically, because outside
repositories they can hold real work; add them to `[exclude]` if they are disposable.
Custom cache locations need an explicit pattern: the app cannot infer every tool's temporary
files, and deliberately does not apply all `.gitignore` rules, which may hide valuable local data.

### Configuration file

Config lives at `~/.config/rusty-mac-backup/config.toml` and is created by `rustyback init`. You can also edit it directly.

```toml
[source]
paths = [
    "~/.zshrc",
    "~/.gitconfig",
    "~/.ssh/config",          # known_hosts only — private keys excluded
    "~/.config/ghostty",
    "~/.config/nvim",
    "~/.config/starship.toml",
    "~/GitHub",               # entire GitHub folder, incremental
]

[destination]
path = "/Volumes/BackupDisk/RustyMacBackup"

[exclude]
patterns = [
    "node_modules", ".git/objects", "*.tmp",
    ".DS_Store", "Caches", "Cache", "__pycache__",
]

[retention]
hourly  = 24    # keep last 24 hourly snapshots
daily   = 30    # keep last 30 daily snapshots
weekly  = 52    # keep last 52 weekly snapshots
monthly = 0     # keep forever

[protection]
include_rights_managed_files = false
include_cloud_storage = false
```

### CloudStorage opt-in (OneDrive, Dropbox, Google Drive, …)

`~/Library/CloudStorage` is excluded by default (see above). Setting
`[protection] include_cloud_storage = true` in `config.toml` lifts the exclusion for
that one path — it does **not** weaken any of the other forbidden paths. There is
**no UI checkbox for this on purpose**: unlike Rights Management (worst case, a file is
skipped), touching a cloud-provider folder from a backup tool is one accidental click
away from that provider's sync client behaving unpredictably. Edit the config file
directly if you need it.

### Rights Management protection (managed documents)

Recognized Rights Management protected files are **excluded by default**, regardless of
destination. This is not an Office-format exclusion: ordinary Office files, PDFs, images
and text remain included. A sensitivity label alone is not proof of encryption/protection.

- **Separate opt-in.** In the backup source selector, enable **Includi file protetti
  (Rights Management)**.
  **Tutti** / **Nessuno** and folder selections never change this switch. **Avvia Backup**
  saves it for subsequent manual, CLI and scheduled runs; **Annulla** discards the edit.
  Alternatively, set `[protection] include_rights_managed_files = true`. This permits normal copy attempts,
  not a bypass of company protections: authorization dialogs or blocked copies can return.
- **Exclusion before any copy or hard link.** Explicitly selected protected files are excluded
  too. New snapshots omit them even if an older snapshot contains them. Existing snapshots
  are not modified by this preference (normal retention still applies).
- **A skip is never silent.** Skipped files are counted in `status.json` (`files_skipped`) and
  reported in `errors.json` under `rights_managed_skipped` (up to 50 example paths).
  Malformed inspection metadata is skipped separately under
  `protection_inspection_failed`, with the reason in the log, not claimed as rights protection.
  Ordinary permission, missing-file and I/O errors retain their normal actionable categories.

Detection runs locally, without launching a document viewer, authenticating, decrypting,
changing labels or uploading data:

- Microsoft protected containers: `.pfile`, `.ppdf`, `.ptxt`, `.pxml`, protected image
  extensions and `.rpmsg` (case-insensitive).
- Compound-file directory metadata: `DRMEncryptedTransform` / `DRMEncryptedDataSpace`
  from [MS-OFFCRYPTO IRMDS](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-offcrypto/dc6708bb-e852-44b1-acba-f74614155191).
  The directory allocation chain is followed even when fragmented; password-only Office
  encryption is not treated as Rights Management.
- PDF `MicrosoftIRMServices` security-handler names and the legacy
  `MicrosoftIRMServices Protected PDF.pdf` attachment name. PDFs are scanned in bounded-memory
  chunks, including metadata in the middle; larger PDFs require an additional read pass.

**Limits:** this is a format-marker detector, not the Microsoft MIP SDK or an exhaustive
rights-policy evaluator. Unknown/vendor-specific protection, renamed generic containers,
compressed PDF metadata and protected attachments inside arbitrary archives can be missed.
Detected markers indicate protection, not license validity. Files changing during a backup
can also invalidate inspection. See Microsoft's
[supported formats](https://learn.microsoft.com/en-us/information-protection/develop/concept-supported-filetypes).

**Endpoint DLP is different:** a company may block copies of *unprotected, unlabeled*
documents. Such a policy is not stored as Rights Management protection in the file; this
filter cannot predict it or guarantee that every company dialog disappears. Full Disk Access
does not override it. The previous `skip_unlabeled_office` / `skip_when_label_unknown` flags
are retired; older configs adopt the new protection-only default when the new key is absent.

**It is easy to blame the wrong folder here.** `~/Library/CloudStorage` (OneDrive included)
is always excluded (see "What It Will Never Touch" above), so it is never the source of an
endpoint-DLP prompt during a backup. The real, repeatable source: an **ordinary Git repo
that is a configured backup source and happens to contain unlabeled company Office files**
(e.g. a `.pptx`/`.xlsx`/`.docx` committed into a corporate repo's docs/archive folder). The
backup engine genuinely reads/copies those — that is a real "copying an unlabeled office
file" event, not a false positive. Confirmed 2026-09-27: `~/GitHub/FDE_Update/zzArchive/`
had four such files. Fix at the source, not in this tool: apply a sensitivity label to the
file (even the unencrypted default label clears it), or add an `exclude.patterns` entry for
that specific file/folder if it doesn't need to be in the backup at all.

---

## Safety net (3.0)

- **Verified snapshots**: `_rustymacbackup/manifest.json` in every snapshot says whether it is
  complete. Incomplete ones are never the restore default and never count as "protected".
- **Unpublished commits**: a `git bundle` per repository with only the commits not on a remote.
- **Databases**: list them in config; they are copied consistently.

```toml
[databases]
sqlite = ["~/GitHub/MyApp/runtime/history.db"]
postgres = ["my_app_db"]

[coverage]
ignore = ["~/Scratch"]          # never report this folder as "not backed up"

[topics]
"My project" = ["~/GitHub/my-project", "~/.config/my-project"]
```

- **Coverage audit**: active folders and databases outside the backup are shown in the menu.
- **Retention**: the 3 newest complete snapshots are never deleted; nothing is pruned while the
  Mac looks new or emptied.

## Menu Bar App

Launch the app (no arguments) to get the menu-bar popover:

```
┌─────────────────────────────────────┐
│ ● RustyMacBackup          [RUNNING] │
├─────────────────────────────────────┤
│ Backup in progress…                 │
│ SanDisk: 142 GB free                │
│ ████████████░░░░ 67%  8.2 MB/s      │
│ ETA: 2 min  ·  ~/GitHub/MyProject   │
├─────────────────────────────────────┤
│ [    Stop Backup    ]               │  ← red filled button
│ Ripristina snapshot…                │
│ Pianificazione: ogni ora            │
│ Libera spazio…                      │
│ ─────────────────────────────────── │
│ Apri cartella backup                │
│ Espelli disco                       │
├─────────────────────────────────────┤
│ Esci                                │
└─────────────────────────────────────┘
```

**Status dot colours:**
- 🟢 Green — idle, last backup succeeded
- 🟡 Gold — backup running
- 🟠 Orange — stopping or backup overdue (>24 h)
- 🔵 Blue — restore in progress
- 🔴 Red — last backup failed / disk absent

**Libera spazio…** opens a small menu (older than 1 month / 6 months / 1 year), shows a preview with destination, cutoff date and number of backups, and deletes only after explicit confirmation. The result reports the space actually freed on the disk. See [Freeing backup disk space](#freeing-backup-disk-space).

**After a failed backup**, an error card appears with a localised description, suggested fix, and a direct "Show Log" link to Console.app.

---

## Architecture

Single-binary `.app` bundle — no frameworks, no SPM, no Xcode project. Compiled with raw `swiftc`.

```
Sources/
├── App/
│   ├── AppDelegate.swift       # NSApplicationDelegate, menu bar, popover lifecycle
│   ├── StatusManager.swift     # Polls status.json from disk, manages AppState
│   ├── AutoUpdater.swift       # GitHub release check, codesign verify, atomic install
│   ├── IconManager.swift       # Animated menu-bar icon (3-frame pulse per state)
│   └── main.swift              # Entry point: CLI dispatch or NSApplication.main()
├── Backup/
│   ├── BackupEngine.swift      # Core backup loop, lock, TaskGroup workers
│   ├── BackupEngine+Helpers.swift  # Mount validation, lock format, stale cleanup
│   ├── DestinationLock.swift   # Shared lock: backup, restore and cleanup never overlap
│   ├── FileScanner.swift       # Recursive traversal with exclude filter
│   ├── HardLinker.swift        # Hard-link decision (mtime + size, 1 ms tolerance)
│   ├── RestoreEngine.swift     # Restore + manifest-based undo
│   ├── RetentionManager.swift  # Snapshot pruning (hourly/daily/weekly/monthly)
│   ├── SnapshotCleanup.swift   # Manual cleanup: preview, confirm, measure freed space
│   └── StatusWriter.swift      # Writes status.json + errors.json to disk
├── UI/
│   ├── PopoverView.swift       # SwiftUI popover (4-zone layout, 320 px)
│   ├── BackupTreeView.swift    # Collapsible tree with tri-state checkboxes
│   └── AppUIState.swift        # @Observable state shared between AppDelegate + SwiftUI
├── Config/
│   ├── Config.swift            # TOML config model + parser
│   ├── ConfigDiscovery.swift   # Auto-discovery of dev tool paths
│   └── ScheduleManager.swift  # LaunchAgent bootstrap/bootout
├── CLI/
│   ├── CLIHandler.swift        # All CLI subcommands
│   └── PruneOptions.swift      # `prune --older-than 1m|6m|1y [--yes]` parsing
└── Diagnostics/
    └── ErrorReporter.swift     # Error taxonomy, localised titles, suggested actions
```

**Key design decisions:**

- **No Full Disk Access** — whitelist model means we never need it
- **Hard links for deduplication** — same as Time Machine, but transparent
- **`copyfile()` not `COPYFILE_CLONE`** — APFS cloning is dangerous cross-volume (see above)
- **Lock file with PID + timestamp + UUID** — stale lock detection survives crashes
- **`mountedVolumeURLs()` not `statfs()`** — `statfs()` returns success on ejected volumes
- **`launchctl bootstrap/bootout`** — not the deprecated `load/unload`
- **No SPM / no Xcode** — single `swiftc` invocation, easy to audit, no dependency graph

---

## Building & Testing

```bash
# Build only
./build.sh

# Run unit tests (55 tests)
./run-tests.sh

# Build distributable .pkg + .app.zip
./build-pkg.sh

# Build specific version
VERSION=2.6.0 ./build-pkg.sh
```

Tests cover: `ExcludeFilter`, `RetentionManager`, `Config` parsing + round-trip, `BackupEngine` snapshot naming, `HardLinker` mtime logic, legacy config migration, manual snapshot cleanup (preview, lock, latest-backup protection, hard-link safety) and mandatory cache exclusions.

---

## Restore & Undo

Three ways, in the menu (**Ripristina…**) and in the CLI. Each one previews first and can be
undone file by file (`undo`, or *Annulla l'ultimo ripristino* in the menu).

```bash
RustyMacBackup snapshots                    # completo / incompleto / non verificato
RustyMacBackup topics                       # Warp, Terminale e shell, Claude Code, …
RustyMacBackup restore-topic warp           # preview; add --yes to restore
RustyMacBackup versions ~/.zshrc            # every distinct version of one file
RustyMacBackup restore-file ~/.zshrc --snapshot 2026-10-04_190948 --yes
RustyMacBackup new-mac                      # checklist + preview of a whole new Mac
RustyMacBackup new-mac --steps config,repos,databases --yes
```

**Nuovo Mac** restores configuration files that are missing (never overwriting), clones each
repository on the branch and commit it had, puts unpublished commits back from the saved
bundle and the uncommitted files on top (so `git status` shows exactly what was local),
restores SQLite files and recreates absent Postgres databases. A half-restored folder in the
way is moved to `~/RustyMacBackup-copie-parziali`, never deleted.

Only complete snapshots are offered by default. Restoring from an incomplete one requires
naming it with `--snapshot` and prints a warning.

## Auto-Update

On launch, the app checks `https://github.com/Roberdan/RustyMacBackup/releases/latest` in the background. When a newer version is found:

1. A blue banner appears in the popover with an **Installa** button (and a **×** to dismiss)
2. Clicking install: downloads `.app.zip`, verifies codesign + bundle ID, extracts over the running app
3. Progress shown inline: *Scaricamento… → Verifica firma… → Installazione…*
4. On failure: the previous `.app` is restored from a rollback copy

FDA permissions are preserved because the update replaces the bundle in-place without reinstalling the LaunchAgent.

---

## Disclaimer

This software is provided **as-is**, without warranty of any kind. I built it for my own use and share it in the hope it's useful — but I take no responsibility for data loss, corruption, missed backups, or any other damage that may result from using it.

**Backup software is critical infrastructure.** Before relying on RustyMacBackup for anything important:
- Verify your backups actually restore correctly (`rustyback restore`)
- Keep at least one other backup method (Time Machine, cloud, etc.)
- Test on non-critical data first

The MIT licence applies — use at your own risk.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Read [`CLAUDE.md`](CLAUDE.md) first.

## License

MIT — see [LICENSE](LICENSE)

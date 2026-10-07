# Changelog

## [4.0.1] - 2026-10-07

### Fixed
- **The app comes back after an update.** It was relaunched by a helper process that macOS
  closes together with the app, so 3.3.0 installed 4.0.0 and never restarted. Now the new copy
  is started by macOS (LaunchServices), the old one quits only once the new one is running,
  and a new copy asks any older one to quit (never a backup running from the command line).
  Checked on a real Mac with `MacBackup4Dev relaunch-test`.
- **Your edits to config.toml are no longer undone.** *Aggiungi* / *Ignora* on a coverage
  warning and *Esegui ora* saved the copy of the config loaded at launch, silently dropping
  anything changed in the file since. They now re-read the file first.
- **The advanced restore no longer replaces your config.** At the end it generated a fresh
  default config over the existing one; now only when there is none.

## [4.0.0] - 2026-10-07

### Changed
- **Renamed MacBackup4Dev** (was RustyMacBackup): app, command, menus, config folder
  (`~/.config/macbackup4dev`), data folder (`~/.local/share/macbackup4dev`), LaunchAgent
  (`com.roberdan.macbackup4dev`), GitHub repository. Everything moves by itself: folders are
  moved with a link left at the old place, the schedule moves to the new label (only when no
  backup is running), a 3.x app renames itself, the 3.x pkg app is removed by the 4.0 pkg.
  Unchanged on purpose: the bundle identifier, everything on the backup disk, past undo data.
  3.2+ updates to 4.0 by itself through a signed `RustyMacBackup-4.0.0.app.zip` bridge.

### Added
- **First launch finds the developer environment by itself** and lets you choose: projects per
  folder (with repository counts), terminal and shell, Git and SSH, editors and IDEs
  (JetBrains settings without plugins, Neovim, Helix, Windsurf, VS Code snippets), AI
  assistants, languages, cloud and containers, every `~/.config` tool one by one, local
  Postgres databases, macOS settings. Credentials are listed apart and never pre-selected;
  test databases are not proposed; cloud folders are never walked. Then disk, schedule, first
  backup. `MacBackup4Dev scan` shows the same in the terminal.
- **"Questo è un Mac nuovo"** on the first screen when a backup disk is attached: straight to
  the guided restore.
- **New Mac as onboarding:** two new first phases. *Strumenti di base* checks Apple's developer
  tools and Homebrew and starts their installers (Apple's window / Terminal with the official
  command). *Programmi* lists every program of the old Mac — Homebrew formulae, apps and taps,
  App Store apps, VS Code extensions, global npm / uv / pipx / cargo packages — each with its
  own checkbox, already installed ones marked, search, install one at a time (a failure never
  stops the others). Replaces the all-or-nothing `brew bundle` phase.
- Every backup now also saves the global npm, uv, pipx and cargo packages and the apps kept in
  `/Applications` subfolders.

### Fixed
- The first-launch scan took 2.5 minutes on a real home (folder sizes measured again at every
  level): now 0.4 s, sizes measured only for what was chosen, and cached.
- Warp's settings path (`~/.warp`, `dev.warp.Warp-Stable`); our own undo folder is no longer
  proposed as configuration; `~/.config` is no longer taken whole (it held `gh`'s token).

## [3.3.0] - 2026-10-07

### Added
- **"Nuovo Mac" a tappe.** The restore of a whole Mac is split into small phases run one at a
  time, in a safe order: documents, repositories, databases, one phase per tool (Warp, Claude
  Code, Copilot, Git e SSH, …), other configurations, shell, Homebrew, services. Each phase
  has a preview, is recorded, and can be undone on its own (`new-mac --undo <id>`). The
  window marks the next phase and suggests a restart after the shell and the services.
- **The shell phase checks itself:** after restoring, a fresh login shell must start and
  finish within 20 s; if it hangs or dies the phase undoes itself.
- **Services (LaunchAgents) are off by default, one toggle each.** Turning one on starts it,
  watches it for a few seconds and, if it exits with an error or crashes, stops it and moves
  its file aside (never deleted). *Spegni* turns it off the same way.

### Fixed
- **Nothing that starts at login is copied by a file restore any more**: LaunchAgents,
  LaunchDaemons, login items, the old Mac's `com.apple.*` and per-host (`ByHost`)
  preferences. Before, *Configurazioni e file* and the *Servizi automatici* topic copied every
  LaunchAgent at once, and all of them started at the next login (scar 2026-10-06: after the
  reboot the Mac did not get back to a usable login). The *Servizi automatici* topic is gone.
- *App del vecchio Mac* now finds apps kept in folders (`/Applications/Dev`, `/Applications/AI`).
- Apps you do not want back are no longer listed as missing: *Non mi servono* in the window,
  or `ignore_apps` under `[coverage]` in config.toml.

## [3.2.0] - 2026-10-07

### Added
- **Automatic, signed updates.** The app checks GitHub at launch and every 6 hours and
  installs new versions by itself when no backup, restore or cleanup is running, then
  relaunches and notifies. Every update archive is signed by the release workflow (Ed25519,
  Sparkle-style `.sig`); the app installs nothing unsigned, signed by another key, older than
  itself, of another app or failing `codesign --verify`.
- The footer shows the version and the update mode; its menu has *Cerca aggiornamenti ora* and
  *Installa automaticamente* (on by default).
- Releases carry `.sig` files, `SHA256SUMS.txt` and notes taken from this changelog.

### Changed
- The app is replaced with two renames in `/Applications` (rollback if the second fails)
  instead of an `rsync` over the running bundle.
- The pkg installer gives the app to the logged-in user, so later updates need no password,
  and restarts only the menu-bar app (a running backup is left alone). It no longer opens
  the Full Disk Access settings, which the app does not need.
- The `.app.zip` is made with `ditto`, which keeps the code signature intact.

### Upgrading from 3.1.x
- Install the 3.2.0 pkg once by hand (3.1.x cannot verify signatures and was installed by
  the administrator). From 3.2.0 on, updates are automatic.

## [3.1.3] - 2026-10-07

### Fixed
- **The menu popover was still clipped on every side.** The 3.0.2 fix did not work in the real
  app: the popover's controller wrapped a SwiftUI hosting controller and never passed its
  size on, so the popover stayed at macOS's default 320×320 whatever it contained. The
  popover's controller is now the hosting controller itself; measured on the real popover:
  380×432 with the disk absent, growing to 380×477 when a backup starts.

### Added
- `measure-menu` (debug): opens the real popover and prints its size against the size its
  content needs (`OK` / `TAGLIATO`). `render-menu` only draws the content, so it cannot
  catch a popover that is too small.

## [3.1.2] - 2026-10-07

### Fixed
- **Espelli disco is safe.** It refuses while a backup is running (also one the schedule
  started on its own) instead of forcing the unmount under it. When the disk is busy it says
  which apps hold it (e.g. "Finder, CleanMyMac_5"); it forces the unmount only when nothing
  but Spotlight's indexers is left. Messages in Italian.

## [3.1.1] - 2026-10-07

### Fixed
- The coverage audit no longer suggests linked git worktrees: they are temporary (a job's
  worktree was added, then deleted during the backup, making it incomplete) and their
  commits are already saved through the main repository.
- Build and test scripts find Xcode wherever it is installed (e.g. `/Applications/Dev`), not
  only in `/Applications`.

## [3.1.0] - 2026-10-07

### Changed
- **New look for the menu popover**: a deep dark panel lit by the state colour, one large
  ring that answers "am I protected?" (a full green shield; the live percentage while a
  backup runs; orange or red when something needs attention), stat pills (files, repos with
  saved commits, databases), a glowing 14-day strip, a gradient primary button and tiles
  with coloured icons for the other actions.
- Numbers use thousands separators; the file count is no longer repeated.
- `.DS_Store` files are no longer tracked in the repository.

## [3.0.2] - 2026-10-07

### Fixed
- **The menu popover was clipped** (header and last rows cut) once a backup started: it kept
  the size it had when it opened. It now follows its content.
- More breathing room: 16 pt margins, aligned menu rows, visible problem cards, "Ultimo
  completo: …" while a backup runs, no misleading copy speed (most files are hard-linked).
- Incomplete reasons no longer mention internal files.

### Added
- `render-menu <dir>` (debug): draws the popover in its main states to PNG files, to check
  the layout without clicking the menu bar.

## [3.0.1] - 2026-10-07

Found on the first morning of real use.

### Fixed
- **The folder picker silently rewrote the source list.** It showed only the folders discovery
  knows, so confirming it dropped every other configured folder (the Obsidian vault, the CI
  runners, folders added from the coverage audit). Every configured folder is now listed
  under *Le tue cartelle*.
- **"Tutti" selected credentials** (the SSH private key, `.npmrc`, Azure sessions, the GitHub
  CLI token) into a backup on a disk the app itself reports as unencrypted. Items marked
  sensitive are now only ever chosen one by one.
- **"Esegui ora" no longer goes through the picker**: it backs up the current configuration.
  Choosing folders is the separate *Scegli cosa salvare…*.
- Starting a backup while another one runs (the nightly run, a second click) is no longer
  reported as a failure: the menu shows the running backup.
- The coverage audit suggested credentials (`~/.azure`), parked copies (`_name`),
  browser-profile and tool-internal databases (`~/.codex`, Atuin, Playwright profiles). It
  now suggests only folders and project databases worth backing up.
- Engine error messages are in Italian.

## [3.0.0] - 2026-10-06

Rewritten after a real reinstall on 2026-10-06, where restoring a Mac from these backups
took a whole day and lost data. Every item below fixes something that happened that day.

### Added
- **Verified snapshots.** Every snapshot carries `_rustymacbackup/manifest.json`: files
  found vs copied, copy errors, unreadable folders, saved commits and databases. A snapshot
  with any of these problems is marked **incomplete**: it is never the default for a
  restore and never counted as "protected". Older snapshots show as *non verificato*.
- **Unpublished commits survive.** For every git repository in the backed-up folders a
  `git bundle` keeps exactly the commits not on any remote (plus the stash), with branches,
  upstreams and worktrees recorded. `.git/objects` is still not copied.
- **Databases.** `[databases] sqlite = [...]` are copied with SQLite's online backup API;
  `[databases] postgres = [...]` are dumped with `pg_dump -Fc`.
- **Coverage audit.** After each backup (and with `coverage`), folders changed in the last
  30 days that no source covers, and SQLite files that are not copied, are reported in the
  menu with *Aggiungi* / *Ignora*. `[coverage] ignore = [...]` silences one for good.
- **Restore by topic** (Warp, Terminale e shell, Claude Code, Copilot, Git e SSH, Editor,
  Font, …; more via `[topics]`), **by file** with every distinct version across snapshots,
  and **Nuovo Mac**: login/app checklist, configuration (only missing files), repositories
  cloned on the same branch and commit with unpublished commits and local edits back,
  databases, Homebrew, chosen LaunchAgents. Everything previews first, writes each file next
  to its target and renames it into place, and can be undone file by file (created files
  included).
- New window **Ripristina** (Argomento / File / Nuovo Mac) and CLI commands `snapshots`,
  `coverage`, `versions`, `find`, `topics`, `restore-topic`, `restore-file`, `undo`,
  `new-mac` (all preview without `--yes`).
- Notifications say *Backup completo* or *Backup incompleto* (with the reason), also for
  scheduled runs.

### Changed
- **Menu redesigned, all in Italian.** First line: protected or not, counting only complete
  snapshots ("Protetto · ultimo completo 2 ore fa"); then problems with the button that fixes
  them; a 14-day strip; *Esegui ora* / *Ripristina…*. Speedometer removed.
- **Retention never deletes the 3 newest complete snapshots**, and pauses entirely when the
  newest snapshot looks like a new or emptied Mac (far fewer files than the last complete
  one). The manual cleanup protects complete snapshots too.
- Build scripts use the full Xcode when the Command Line Tools lack the SwiftUI macro plugin.

### Fixed
- The file queue between scanner and copy workers used `bufferingNewest(256)`, which drops
  waiting files when scanning runs ahead of copying. It now never drops (bounded by a
  semaphore). The 6 October snapshot was missing ~80% of its files, evenly across folders.
- Paths under a symlinked parent (`/var` → `/private/var`) were stored flat by file name:
  files with the same name could overwrite each other inside a snapshot.
- Restore skipped nothing internal: `_rustymacbackup` and Finder litter are no longer offered.
- Undo removes the files a restore created, not only the ones it replaced.
- `brew bundle --no-lock` (removed from Homebrew) no longer breaks the Homebrew restore.
- VM/container disk images (`.colima`, `.lima`, `.orbstack`) excluded (recovered change).
- Pre-release review: undo never deletes or overwrites a file changed after the restore;
  a repository git cannot read, a folder that disappeared, or an unreadable folder make
  the snapshot incomplete; unpublished commits are judged against each remote's default
  branch, so their bundle applies to a fresh clone even after a squash-merge deleted the
  branch; detached HEAD saved; retention keeps the complete snapshot of each slot; restore
  leaves symlinks and folders of another type alone; `--to` and `.`/`..` paths normalised;
  external commands cannot hang (SIGKILL after the grace period, no blocking final read).

## [2.6.0] - 2026-09-24

### Added
- **Libera spazio…** in the menu and `prune --older-than 1m|6m|1y` in the CLI:
  one-time manual cleanup with a preview (destination, cutoff date, count, free space)
  and explicit confirmation. The CLI previews unless `--yes` is given. After deletion the
  space actually freed is reported, measured on the disk (hard-linked data shared with kept
  snapshots frees nothing). The most recent snapshot is always kept.
- Backup, restore and cleanup share a destination lock; interrupted deletions stay in a
  hidden `.deleting-*` folder instead of looking like a valid snapshot.
- Known regenerable caches (`node_modules`, `.venv`, `__pycache__`, `DerivedData`,
  `target/debug`, …) are always excluded, also with old configs and explicit sources.

### Fixed
- Menu popover resizes with its content (the disk-space line no longer hides under
  **Start Backup**); cleanup shows its real phase (checking, awaiting confirmation,
  deleting) and disabled rows look disabled.
- Multi-component exclusions (e.g. `.git/objects`) now match inside nested repositories.
- Unit tests no longer write into the app's real log file.

## [2.5.1] - 2026-09-22

### Changed
- Recognized Rights Management protected documents are excluded by default across formats,
  before copies or hard links, on all destinations. Ordinary Office documents remain included.
  Detection uses protected-container extensions and local CFB/PDF metadata, not decryption.
- Added a separate **Includi file protetti (Rights Management)** switch, independent
  of **Tutti** and **Nessuno**. Starting a backup saves the preference for later runs.
- Replaced label-based DLP settings with `[protection] include_rights_managed_files = false`.
  The detector does not predict separate endpoint policies (such as blocking unlabeled USB copies).
- Reports distinguish recognized protection from inspection failures. Failure to save the
  preference is visible and prevents starting the backup. Existing snapshots are untouched.

## [2.5.0] - 2026-08-30

### Added
- **Hidden home folders are backed up by default** — discovery no longer depends on a
  hand-written list of ~70 tools, which silently missed roughly 40 dot-directories on a
  working machine (`.codex`, `.copilot`, `.agents`, `.gbrain`, `.docker`, `.terraform.d`,
  `.gnupg`, …). Every hidden entry in the home directory is now a candidate, so a tool
  installed tomorrow is covered without editing any list. The curated candidates stay: they
  still carry the parts of `~/Library` that are configuration but not hidden.
- **Two-pass "configuration, not data" filter** — first by name (package registries, model
  stores, caches, logs, browser profiles, `node_modules`, timestamped `.bak-*` copies), then
  by size: a folder still over 200 MB is opened, and the oversized part inside it is added to
  the exclusion list rather than the whole folder being dropped or the whole folder being
  copied. On the author's Mac this turns 74.7 GB of hidden folders into ~8 GB of actual
  configuration.
- **Credential-bearing folders are detected but off by default** — `.ssh`, `.gnupg`, `.aws`,
  `.azure`, `.docker`, `.npmrc` and friends are marked sensitive by the dynamic scan, so the
  generated configuration leaves them out and the existing opt-in path is unchanged.

### Changed
- **Size is measured net of the exclusions** — a folder that is only large because of its
  cache counts as small. Without this, a 1.1 GB skill checkout whose bulk was `node_modules`
  was treated as data and enumerated file by file.
- **Listing no longer measures anything** — `discover` and the selection tree return in
  milliseconds instead of a minute; the tree walk happens only when a configuration is
  generated.

### Fixed
- **`ExcludeFilter` was quadratic in patterns** — single-component literal patterns are now a
  set lookup per path component instead of a glob run per pattern. This is on the hot path of
  every backup, not just discovery: roughly 2× faster on a large tree.

## [2.4.0] - 2026-08-25

### Added
- **Version in the popover header** — read from the running bundle rather than written as a
  literal, so what the UI claims and what is installed cannot disagree. A `swiftc` build with
  no bundle shows `dev`, which is the truthful answer there.

### Fixed
- **Popover stayed open when clicking another app** — `behavior = .transient` was already set,
  but this is an `LSUIElement` agent that never becomes active, so a click belonging to a
  *different* application is never delivered to it and the popover simply hovered over whatever
  the user had moved on to. A global mouse-down monitor, installed while the popover is shown
  and removed in `popoverDidClose`, sees exactly the events `.transient` cannot. Clicks inside
  the popover are still `.transient`'s job, which is why the monitor is global and not local.

## [2.3.0] - 2026-08-25

### Added
- **Endpoint DLP guard** — on a Mac managed with Microsoft Purview, copying an *unlabeled*
  Office file to removable media is vetoed by the endpoint agent: `copyfile()` returns `EPERM`
  and macOS raises a modal justification dialog. During an unattended hourly backup nobody
  answers it and the file is never copied. `DLPGuard` now decides before the copy is attempted,
  so the dialog never appears. A file is skipped only when the destination is removable media,
  the file is an Office document, *and* it carries no MIP sensitivity label (read from
  `docProps/custom.xml` in the OOXML package).
- **`[dlp]` config section** — `skip_unlabeled_office` and `skip_when_label_unknown`, both
  defaulting to true. The TOML parser now understands booleans at all, which it previously did
  not.
- **`dlp_skipped` report category** — skipped files are counted in `status.json`
  (`files_skipped`) and named in `errors.json`, kept apart from real errors so a skip never
  inflates the error total. A file absent from the backup is always explainable.

### Fixed
- **Silent subtree loss in the scanner** — `FileScanner` called `enumerator.skipDescendants()`
  for every entry matching an exclude pattern, *files included*. `skipDescendants()` skips the
  subdirectory the enumerator is about to descend into, so an excluded file sitting immediately
  before a real directory swallowed that entire subtree. Nothing failed and nothing was logged:
  the files were simply absent from every snapshot. A single stray `.DS_Store` was enough — on
  this machine it cost `FDE_Update/zzArchive/` (6 files) and
  `the-standing-egg/docs/archive/exports/` (4 files), and any `*.log`, `*.tmp`, `*.pyc` or
  `*.jsonl` in the wrong position would do the same. `skipDescendants()` is now called only for
  directories.
- **Misleading advice on DLP failures** — these surfaced as `permission_denied`, whose
  suggested action is "check Full Disk Access". No local setting fixes a Purview policy, so
  the operator was sent chasing a fix that does not exist.
- **`files_skipped` never reported** — the field was written to `status.json` but never
  assigned, so it always read 0 while `errors.json` listed skipped files.
- **Stale recovery installer on the backup disk** — `install.sh` synced the `.app` and then
  copied "the newest `.pkg` lying around", which nothing ever rebuilt. The artifact whose
  entire purpose is restoring the app from the backup had sat at 1.0.0 since March while the
  installed app moved on: the one scenario it exists for would have handed back a five-month-old
  build. `install.sh` now builds the installer it ships (`build-pkg.sh`, which produces the app
  once and both artifacts from it), pins the copy to the version it just built rather than to a
  glob, and removes any older `.pkg` from the disk so there are never two with no way to tell
  which matches the `.app` beside them. `build-pkg.sh` also derives the version from `build.sh`
  instead of repeating the literal — the same drift, one level down.
- **Concurrency warnings in `AppDelegate`** — four `capture of 'self' with non-Sendable type`
  warnings. `AppDelegate` touches AppKit and `uiState` throughout, both main-thread-only, so the
  isolation was already real and simply undeclared; the class is now `@MainActor`. `runDiskutil`
  is explicitly `nonisolated`, since `handleEject` calls it from a background queue precisely
  because it blocks. Builds clean.

### Notes
- The DLP check runs **after** the hard-link attempt, not before. DLP vetoes the copy, not the
  link, so a file already present in the previous snapshot is still linked into the new one and
  stays in the backup chain. Enabling the guard never evicts what is already backed up.

## [2.2.0] - 2026-03-20

### Fixed
- **Lock file race condition** — lock format extended to `PID\nTIMESTAMP\nUUID`; stale cleanup only removes dirs older than 2 hours when no live owner is found (F-01)
- **Cancel safety** — cancelling a backup now deletes the in-progress snapshot instead of renaming it to a corrupt final snapshot (F-02)
- **Mount validation** — `statfs()` was returning success on stale `/Volumes/X` dirs even after disk ejection; now uses `mountedVolumeURLs()` to verify real mount (F-03)
- **Updater rollback** — auto-updater now verifies codesign + bundle ID before installing, rolls back automatically on rsync failure (F-04)
- **Undo restore** — restore now writes `manifest.json` with overwritten paths for precise undo; falls back to top-level scan for legacy dirs (F-05)
- **Traversal errors surfaced** — `FileScanner` now calls `onTraversalError` callback instead of silently swallowing directory read errors (F-08)
- **Status write errors** — critical status file writes no longer silently fail; errors are logged (F-09)
- **Free space preflight** — restore checks available disk space before starting (F-10)
- **LaunchAgent scheduler** — migrated from deprecated `launchctl load/unload` to `launchctl bootstrap/bootout` (F-11)
- **Version string** — CLI `--version` now reads from `Bundle` instead of a hardcoded "2.0.0" (F-12)
- **`~/` directory in repo** — accidental `~/` directory committed to repo root removed; added to `.gitignore` (F-13)
- **HardLinker mtime tolerance** — reduced from 1 second to 1 millisecond to avoid false cache hits on fast filesystems (F-07)
- **README false claim** — removed statement that COPYFILE_CLONE (APFS cloning) is used; it is explicitly forbidden as it performs a destructive move across volumes (F-23)

### Added
- **Transient UI states** — `.stopping` and `.restoring` app states prevent status flickering during stop/restore transitions (F-14)
- **Diagnostics error card** — when last backup failed, popover shows localised error title, suggested action, and "Show Log" / "Retry" buttons (F-15)
- **VoiceOver / Accessibility** — status dot, progress bar, badge, and all action buttons have `accessibilityLabel` / `accessibilityHint` (F-16)
- **Update banner dismiss** — × button lets user dismiss the update notification; banner shows download/verify/install phase text during update (F-17)
- **Post-restore result card** — shows restored/overwritten/failed counts for 60 seconds after a restore completes (F-18)
- **Cached backup state** — `hasBackups` and `canUndo` are cached in `AppUIState`; no disk I/O on each SwiftUI render cycle (F-19)
- **Phase-coloured progress bar** — scanning=grey, copying=gold, finalising=green, cancelled=red (F-21)
- **Animated menu-bar icon** — 3-frame pulse: gold=running, orange=stopping, blue=restoring (F-22)
- **Unified error taxonomy** — `ErrorReporter` provides `localizedTitle(for:)` and `suggestedAction(for:)` for all error categories (F-06)

### UI
- **Popover restructured** — 4 stable zones: Header / Health / Actions / Context; width 300 → 320 px (F-20)
- **Primary action button** — context-aware filled button: gold "Start Backup" at rest, red "Stop Backup" while running, inline label during stopping/restoring
- **Italian labels** — action buttons localised to Italian (Ripristina, Annulla, Espelli, Esci, Pianificazione)

## [2.1.0] - 2026-03-20

### Fixed
- **Snapshot path structure (CRITICAL)** -- `FileScanner` now uses the home directory as the base path for all sources. Previously each source path was used as its own base, causing all files to be stored flat in the snapshot root (e.g. `~/GitHub/MyRepo/file.swift` → `snapshot/file.swift`). Now stored as `snapshot/GitHub/MyRepo/file.swift`. This fix is required for cross-machine restore to work correctly.
- **Restore on different Mac** -- replaced `ConfigDiscovery.discover()` (filters by file existence) with new `ConfigDiscovery.candidatesForRestore(snapshotTopLevels:)` that matches against snapshot contents without requiring files to exist on the target machine.
- **Restore `~/` path bug** -- `confirmRestore()` now strips `~/` prefix before passing paths to `RestoreEngine` (was causing `snapshot/~/.gitconfig` lookups that always failed).
- **Restore UI categories** -- restore tree now shows the same categories as backup (Shell, Git, SSH, etc.) instead of flat "Dotfiles / Folders & Repos".
- **Repo restore** -- GitHub/Developer/Projects repos are scanned directly from snapshot subdirectories and shown individually in the "Repos" category.
- **Restore destination display** -- each restore item now shows destination path and `✚ nuovo` / `⚠ sovrascrive` badge.
- **Restore order** -- Homebrew packages are now installed *before* restoring config files (tools must exist before their config).
- **Restore progress** -- popover reopens automatically during restore to show live `[X/N] filename` progress bar.
- **StatusManager auto-create** -- if backup disk is mounted but the `RustyMacBackup/` folder was deleted, it is recreated automatically instead of showing NO DISK.
- **Stale lock detection** -- StatusManager verifies PID liveness with `kill(pid, 0)` to remove locks left by crashed processes.
- **"No backups yet"** -- synthesizes `lastCompleted` from snapshot folder names on disk when `status.json` is missing.
- **Tailscale** -- added to Cloud category in ConfigDiscovery (`~/Library/Preferences/io.tailscale.ipn.macos.plist` + `~/Library/Application Support/Tailscale`).

### Added
- **Add custom paths to backup** -- "＋ Aggiungi cartella o file…" button in backup tree opens NSOpenPanel; selected paths added to "Custom" category and saved to config.
- **Custom restore destination** -- each restore item has an ↗ button to redirect it to a different folder on the target machine (e.g. restore `~/Downloads` to `~/Documents/OldDownloads`).
- **Snapshot picker** -- when multiple snapshots exist, shows a picker with human-readable dates and "Ultimo" badge before opening the restore tree.
- **Schedule UI** -- "Schedule: Off/ogni 1h/…" button in popover wired to `launchd` via `ScheduleManager`; options: disable, hourly, every 6h, nightly at 00:00/02:00/03:00.
- **Parallel backup workers** -- `withThrowingTaskGroup` with 8 concurrent workers replaces sequential `for-await` loop (~2x throughput improvement).
- **Adaptive I/O throttle** -- `IOPOL_DEFAULT` on AC power, `IOPOL_THROTTLE` on battery; bird-safe pause 5ms on AC vs 100ms on battery.
- **`install.sh` syncs to backup disk** -- copies `.app` and latest `.pkg` to backup destination after every install.



### Fixed
- **BackupEngine crash (EXC_BAD_ACCESS)** -- replaced `UnsafeMutablePointer<Int64>` + `defer { deallocate() }` with a heap-allocated `Counters` class; ARC now guarantees pointer lifetime matches the `Task.detached` walker closure, eliminating the use-after-free race condition that caused crashes during actual backup runs.

## [2.0.0] - 2026-03-20

### SwiftUI UI Rewrite + Auto-Update

Complete UI rewrite from AppKit (flat NSStackView of 400+ items) to SwiftUI tree view. Added GitHub-based auto-update pipeline.

### Added
- **SwiftUI tree view** -- collapsible categories (Shell, Git, SSH, Terminal, Editor, AI Tools, Auth, Cloud, macOS, Repos) with tri-state checkboxes (checked / unchecked / mixed via native `NSButton` `allowsMixedState`)
- **AppUIState** -- shared `ObservableObject` bridging AppKit `AppDelegate` and SwiftUI views
- **Auto-updater** -- checks `api.github.com/repos/roberdan/RustyMacBackup/releases/latest` on launch, downloads `.app.zip`, installs in-place via `rsync` (preserves FDA permissions), relaunches
- **Update banner** -- blue banner in popover shows available version + spinner during download
- **GitHub Release workflow** -- `.github/workflows/release.yml` produces `.pkg` + `.app.zip` artifacts on tag push
- **`install.sh`** -- in-place installer: `rsync Contents/` preserves `.app` path so macOS TCC keeps FDA grant

### Changed
- `TreeWindowController` -- replaced ~365 lines of AppKit with thin `NSHostingController<TreeView>` wrapper
- `PopoverViewController` -- replaced ~310 lines of AppKit with thin `NSHostingController<PopoverView>` wrapper
- `AppDelegate` -- removed `PopoverDelegate`/`TreeWindowDelegate` conformances; uses closure callbacks + `AppUIState`
- `build.sh` -- `VERSION` from env var, stamps `Info.plist` in bundle, added `-framework SwiftUI`
- `build-pkg.sh` -- produces both `.pkg` AND `.app.zip`
- Version bumped to 2.0.0

### Removed
- `TreeWindowDelegate` and `PopoverDelegate` protocols -- replaced by closure callbacks



### Safe Whitelist-Only Rewrite

Complete safety overhaul: switched from dangerous blacklist model (backup everything, exclude bad stuff) to whitelist-only (backup ONLY chosen folders). The previous version caused system instability by scanning TCC-protected directories, triggering tccd crashes and bird mass-eviction cascades.

### Added
- **Whitelist-only backup model** -- `source.paths = [...]` replaces recursive home directory scanning
- **ConfigDiscovery** -- auto-detects installed dev tools (shells, editors, terminals, Git, SSH, AI tools, etc.)
- **Forbidden path enforcement** -- hardcoded blocklist of system/TCC-protected paths that can never be backed up
- **`discover` CLI command** -- shows all detected dev tool configs on your Mac
- **NSPopover UI** -- modern popover with vibrancy, replacing NSMenu-based UI
- **Add Folder via NSOpenPanel** -- file picker with forbidden path validation
- **Symlink skipping** -- FileScanner skips symbolic links to prevent loops and indirect TCC access
- **Single-file backup** -- can back up individual files (e.g. `~/.zshrc`) not just directories
- **Legacy config migration** -- old `source.path` + `extra_paths` format auto-migrates to `source.paths`
- **Config file permissions** -- saved with 0600 (owner-only read/write)
- **Restore path restriction** -- restore limited to home directory by default

### Removed
- **Full Disk Access requirement** -- no longer needed (whitelist model accesses only user-chosen paths)
- **FDACheck** -- removed TCC probing that could crash tccd
- **System path defaults** -- removed `/Applications`, `/opt/homebrew`, `/usr/local`, `/etc`, `/Library` from defaults
- **SpeedometerView** -- replaced by clean progress bar
- **MenuBuilder** -- replaced by PopoverViewController
- **Insecure auto-updater** -- removed (downloaded without signature verification)
- **Ferrari/Maranello Luce design** -- replaced by system-standard colors

### Fixed
- **System stability** -- no longer scans Library/Mail, Library/Messages, Library/Safari, Library/Containers, Library/CloudStorage, Library/Mobile Documents (TCC-protected paths)
- **iCloud daemon conflicts** -- no longer triggers bird mass-eviction by touching cloud-managed directories
- **StatusWriter race condition** -- atomic write replaces separate remove+move
- **ScheduleManager hardcoded path** -- now uses actual bundle executable path
- **CCC-aligned exclusions** -- added .Spotlight-V100, .fseventsd, DocumentRevisions-V100, .Trash, .TemporaryItems
- **App cache exclusions** -- added Caches, Cache, GPUCache, CachedData, CachedExtensions (VS Code/Cursor)

### Breaking Changes
- **Config format changed**: `source.path` + `extra_paths` replaced by `source.paths = [...]` (auto-migration supported)
- **No more Full Disk Access**: app no longer requests or needs FDA
- **CLI `config` subcommands**: `source`/`dest`/`exclude`/`include` replaced by `add`/`remove`
- **Version bumped to 2.0.0**

## [1.0.0] - 2026-03-19

### Full Swift Native Rewrite

Complete rewrite from Rust + Swift dual-binary to a single native Swift `.app` bundle.

### Added
- Single .app bundle serves as both menu bar app and CLI tool
- Backup engine with `copyfile()` APFS clone support and hard links
- Parallel file processing via Swift `TaskGroup` (8 workers)
- Manual TOML config parser (zero external dependencies)
- Battery-aware I/O throttling via `setiopolicy_np`
- Stale mountpoint detection via `statfs` device comparison
- 25 unit tests (ExcludeFilter, Retention, Config, BackupEngine, HardLinker)

## [0.3.1] - 2026-03-19

### Fixed
- Backup failures now diagnosed with actionable guidance
- Proactive disk diagnostics
- Eject disk visual feedback

## [0.3.0] - 2026-03-19

### Fixed
- Stale mountpoint detection
- Instant disk connect/disconnect detection

## [0.2.0] - 2026-03-18

### Added
- Auto-resume backup on disk reconnect
- Auto-updater checking GitHub releases

## [0.1.0] - 2026-03-17

### Added
- Initial release

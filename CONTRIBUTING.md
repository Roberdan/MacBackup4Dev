# Contributing to MacBackup4Dev

Thanks for your interest. This is a personal tool I use daily — contributions are welcome, but the bar is high: correctness and safety over features.

## Before You Start

Read [`CLAUDE.md`](CLAUDE.md). It contains the architecture overview, critical traps (especially the `COPYFILE_CLONE` section — read it before touching anything backup-related), forbidden paths, and build commands.

## Ways to Contribute

**Bug reports** — open an issue with:
- macOS version + disk filesystem (APFS / ExFAT / HFS+)
- Relevant lines from `~/.config/rusty-mac-backup/logs/`
- Steps to reproduce

**Feature requests** — open an issue first. Describe the problem, not the solution. I'll let you know if it fits the scope.

**Pull requests** — for bug fixes and small improvements, open a PR directly. For larger changes, open an issue first to discuss.

## Development Setup

```bash
git clone https://github.com/Roberdan/MacBackup4Dev.git
cd MacBackup4Dev
xcode-select --install   # if not already installed
./run-tests.sh           # should show: 55 tests, 55 passed, 0 failed
```

No SPM, no Xcode project, no dependencies. Just `swiftc` and the files in `Sources/`.

## Code Style

- Swift standard style — no linter enforced, use common sense
- No `// TODO` or `// FIXME` in submitted code — fix it or don't include it
- Comments only where the *why* isn't obvious from the code
- Keep files focused; `PopoverView.swift` is already pushing it

## Testing

```bash
./run-tests.sh
```

All 55 tests must pass. If your change touches `BackupEngine`, `HardLinker`, `FileScanner`, or `RestoreEngine`, add or update the relevant test in `Tests/`.

Tests live in `Tests/` and are compiled + run by `run-tests.sh` (no XCTest — plain Swift assertions).

## Critical Rules

**Never use `COPYFILE_CLONE`** (flag `1<<24`) with `copyfile()`. On macOS, cloning across different filesystems (APFS → ExFAT/HFS+) silently performs a *move* instead of a copy — the source file is deleted. This has caused real data loss. The safe flag is `COPYFILE_ALL = 0x0F`. This is non-negotiable.

**Never add paths under** `~/Library/Mail`, `~/Library/Messages`, `~/Library/Containers`, `/Library`, `/System`, or any other TCC-protected path to the auto-discovery list. The forbidden path list in `BackupEngine+Helpers.swift` is a safety boundary, not a suggestion.

**Lock ordering**: always acquire the backup lock before writing status. See `CLAUDE.md` for the full lock protocol.

## Submitting a PR

1. Fork the repo, create a branch: `git checkout -b fix/describe-the-fix`
2. Make your changes
3. Run `./run-tests.sh` — all 55 must pass
4. Run `./build.sh` — must compile clean (warnings OK, errors not)
5. Open a PR with a clear description of what changed and why

I'll review PRs when I have time. This is a side project — please be patient.

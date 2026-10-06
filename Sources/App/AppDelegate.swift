import Cocoa
import UserNotifications
import SwiftUI

/// Main-actor isolated: every member touches AppKit or `uiState`, both of which are
/// main-thread-only. Without the annotation the class is non-Sendable and every
/// `Task`/`DispatchQueue.main.async` that captures `self` warns — the isolation was
/// always real, it just wasn't declared.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    var config: Config?
    var statusManager = StatusManager()
    private var iconManager: IconManager!
    private var pollTimer: Timer?
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var uiState: AppUIState!
    private var popoverVC: PopoverViewController!
    private var treeWindowController: TreeWindowController?
    private var snapshotPickerWC: SnapshotPickerWindowController?
    private var restoreCenterWC: RestoreCenterWindowController?
    private var lastProtectionRefresh = Date.distantPast

    func setInitialConfig(_ config: Config?) {
        self.config = config
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app must stay alive")
        ProcessInfo.processInfo.disableSuddenTermination()
        Log.info("App launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconManager = IconManager(statusItem: statusItem)
        iconManager.setState(.idle)

        // Create shared UI state and wire callbacks.
        uiState = AppUIState()
        wireCallbacks()

        // Setup popover with SwiftUI content.
        popoverVC = PopoverViewController(uiState: uiState)
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        DispatchQueue.main.async { [weak self] in self?.deferredInit() }
    }

    // MARK: - Callbacks

    private func wireCallbacks() {
        uiState.onRequestBackup = { [weak self] in self?.handleRequestBackup() }
        uiState.onRequestRestore = { [weak self] in self?.handleOpenRestoreCenter() }
        uiState.onRequestAdvancedRestore = { [weak self] in self?.handleRequestRestore() }
        uiState.onAddCoverage = { [weak self] gap in self?.handleCoverage(gap, ignore: false) }
        uiState.onIgnoreCoverage = { [weak self] gap in self?.handleCoverage(gap, ignore: true) }
        uiState.onRequestStop = { [weak self] in self?.handleStop() }
        uiState.onRequestEject = { [weak self] in self?.handleEject() }
        uiState.onRequestOpenFolder = { [weak self] in self?.handleOpenFolder() }
        uiState.onRequestQuit = { NSApplication.shared.terminate(nil) }
        uiState.onSelectDisk = { [weak self] url in self?.handleSelectDisk(url) }
        uiState.onRequestUndoRestore = { [weak self] in self?.handleUndoRestore() }
        uiState.onRequestUpdate = { [weak self] in self?.handleRequestUpdate() }
        uiState.onSetSchedule = { [weak self] option in self?.handleSetSchedule(option) }
        uiState.onRequestScheduleMenu = { [weak self] in self?.handleRequestScheduleMenu() }
        uiState.onRequestCleanupMenu = { [weak self] in self?.handleRequestCleanupMenu() }
        refreshScheduleLabel()
    }

    private func refreshScheduleLabel() {
        let s = ScheduleManager.scheduleStatus()
        if !s.installed {
            uiState.scheduleLabel = "Off"
        } else if let mins = s.intervalMinutes {
            uiState.scheduleLabel = mins >= 60 ? "ogni \(mins / 60)h" : "ogni \(mins)min"
        } else if let hour = s.dailyHour {
            uiState.scheduleLabel = hour == 0 ? "mezzanotte" : "notte \(hour):00"
        } else {
            uiState.scheduleLabel = "On"
        }
    }

    private func handleRequestScheduleMenu() {
        let menu = NSMenu()
        func item(_ title: String, opt: Int?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(scheduleMenuAction(_:)), keyEquivalent: "")
            i.target = self
            i.tag = opt ?? Int.min
            return i
        }
        menu.addItem(item("Disabilita schedule", opt: nil))
        menu.addItem(.separator())
        menu.addItem(item("Ogni ora",  opt: 60))
        menu.addItem(item("Ogni 6 ore", opt: 360))
        menu.addItem(.separator())
        menu.addItem(item("Ogni notte (00:00)", opt: 0))
        menu.addItem(item("Ogni notte (02:00)", opt: -2))
        menu.addItem(item("Ogni notte (03:00)", opt: -3))

        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.frame.height + 4),
                       in: button)
        }
    }

    @objc private func scheduleMenuAction(_ sender: NSMenuItem) {
        let opt: Int? = sender.tag == Int.min ? nil : sender.tag
        handleSetSchedule(opt)
    }

    private func handleSetSchedule(_ option: Int?) {
        do {
            if let opt = option {
                let plist: String
                if opt <= 0 {
                    plist = ScheduleManager.generatePlistDaily(hour: abs(opt))
                } else {
                    plist = ScheduleManager.generatePlist(intervalSeconds: opt * 60)
                }
                try ScheduleManager.installSchedule(plistContent: plist)
            } else {
                try ScheduleManager.removeSchedule()
            }
        } catch {
            sendNotification(title: "Schedule error", body: error.localizedDescription)
        }
        refreshScheduleLabel()
    }

    private func deferredInit() {
        if config == nil {
            config = try? Config.load(from: Config.defaultPath)
        }
        Log.info("Config loaded: \(config != nil ? "\(config!.source.paths.count) paths" : "none")")

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                Log.info("Notification auth: granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            }
        }

        let ws = NSWorkspace.shared
        ws.notificationCenter.addObserver(self, selector: #selector(volumeChanged),
                                          name: NSWorkspace.didMountNotification, object: nil)
        ws.notificationCenter.addObserver(self, selector: #selector(volumeChanged),
                                          name: NSWorkspace.didUnmountNotification, object: nil)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so this fires on the main thread already.
            MainActor.assumeIsolated { self?.pollStatus() }
        }
        pollTimer?.tolerance = 5.0
        pollStatus()

        // Check for updates 5s after launch (non-blocking).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task {
                if let version = await AutoUpdater.checkForUpdate() {
                    DispatchQueue.main.async { self?.uiState.updateAvailable = version }
                }
            }
        }
    }

    // MARK: - Popover

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            pollStatus()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            watchForOutsideClick()
        }
    }

    /// `.transient` dismisses the popover on a click the app itself receives, but this is an
    /// `LSUIElement` agent that never becomes active, so a click in *another* app is never
    /// delivered and the popover just stays there — floating over whatever the user moved on
    /// to. A global monitor sees exactly the events `.transient` cannot: those belonging to
    /// other applications. Clicks inside our own popover stay with `.transient`, which is why
    /// this is a global and not a local monitor.
    private func watchForOutsideClick() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    /// Paired with `watchForOutsideClick`. Hooked to `popoverDidClose` rather than to each
    /// call site because the popover is closed from a dozen action handlers, and a monitor
    /// left installed keeps observing every click on the machine for nothing.
    private func stopWatchingForOutsideClick() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Action handlers

    private func handleRequestCleanupMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Elimina backup più vecchi di:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for age in CleanupAge.allCases {
            let item = NSMenuItem(title: "\(age.label)…", action: #selector(cleanupMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = age.rawValue
            menu.addItem(item)
        }
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.frame.height + 4), in: button)
        }
    }

    @objc private func cleanupMenuAction(_ sender: NSMenuItem) {
        guard let age = CleanupAge(rawValue: sender.tag) else { return }
        handleRequestCleanup(age)
    }

    private func handleRequestCleanup(_ age: CleanupAge) {
        guard let config, !uiState.isRunning, !uiState.isCleaning else { return }
        let destination = URL(fileURLWithPath: config.destination.path)
        uiState.cleanupPhase = .reading
        popover.performClose(nil)

        DispatchQueue.global(qos: .utility).async {
            do {
                let cleanup = try SnapshotCleanup(at: destination, age: age)
                DispatchQueue.main.async {
                    guard !cleanup.candidates.isEmpty else {
                        self.finishCleanup(message: "Nessun backup più vecchio di \(age.label) da eliminare.")
                        return
                    }
                    self.uiState.cleanupPhase = .awaitingConfirmation
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Eliminare \(cleanup.candidates.count) vecchi backup?"
                    let examples = cleanup.candidates.prefix(5).map(\.name).joined(separator: "\n")
                    let more = cleanup.candidates.count > 5 ? "\n… e altri \(cleanup.candidates.count - 5)" : ""
                    alert.informativeText = """
                    Disco: \(destination.path)
                    Spazio libero ora: \(BackupEngine.formatBytes(cleanup.freeBytes))
                    Più vecchi di \(age.label), prima del \(cleanup.cutoff.formatted(date: .abbreviated, time: .shortened)).

                    \(examples)\(more)

                    L'ultimo backup viene sempre conservato. I file originali non vengono toccati.
                    L'eliminazione è definitiva. I file condivisi con altri backup liberano spazio solo quando non servono più a nessuno.
                    """
                    alert.addButton(withTitle: "Annulla")
                    alert.addButton(withTitle: "Elimina backup")
                    alert.buttons[1].hasDestructiveAction = true
                    NSApp.activate(ignoringOtherApps: true)
                    guard alert.runModal() == .alertSecondButtonReturn else {
                        self.uiState.cleanupPhase = nil
                        return
                    }
                    self.uiState.cleanupPhase = .deleting
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            let result = try cleanup.execute()
                            let freed = BackupEngine.formatBytes(result.freedBytes)
                            let free = BackupEngine.formatBytes(result.freeAfterBytes)
                            DispatchQueue.main.async {
                                self.finishCleanup(message: "Eliminati \(result.deleted.count) vecchi backup. "
                                    + "Spazio liberato: \(freed). Spazio libero ora: \(free). Ultimo backup conservato.")
                            }
                        } catch {
                            DispatchQueue.main.async {
                                self.finishCleanup(message: error.localizedDescription, failed: true)
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishCleanup(message: error.localizedDescription, failed: true)
                }
            }
        }
    }

    private func finishCleanup(message: String, failed: Bool = false) {
        uiState.cleanupPhase = nil
        if failed { Log.error("Cleanup failed: \(message)") }
        pollStatus()
        let alert = NSAlert()
        alert.alertStyle = failed ? .warning : .informational
        alert.messageText = failed ? "Pulizia non completata" : "Pulizia backup"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func handleRequestBackup() {
        guard !uiState.isCleaning else { return }
        guard let config = config else { return }
        popover.performClose(nil)

        let treeWC = TreeWindowController(
            mode: .backup,
            enabledPaths: Set(config.source.paths),
            includeRightsManagedFiles: config.protection.includeRightsManagedFiles,
            onConfirmBackup: { [weak self] selectedPaths, includeRightsManagedFiles in
                self?.treeWindowController = nil
                self?.startBackup(selectedPaths: selectedPaths, includeRightsManagedFiles: includeRightsManagedFiles)
            }
        )
        treeWC.showWindow(nil)
        treeWC.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        treeWindowController = treeWC
    }

    private func handleRequestRestore() {
        guard !uiState.isCleaning else { return }
        let backups = RestoreEngine.findBackupSnapshots()
        guard let first = backups.first, !first.snapshots.isEmpty else { return }
        popover.performClose(nil)

        let entries = first.snapshots.map {
            SnapshotEntry(url: first.backupDir.appendingPathComponent($0))
        }

        if entries.count == 1 {
            openRestoreTree(snapshotURL: entries[0].url)
            return
        }

        // Multiple snapshots — show picker first
        let picker = SnapshotPickerWindowController(
            entries: entries,
            onPick: { [weak self] url in
                self?.snapshotPickerWC = nil
                self?.openRestoreTree(snapshotURL: url)
            },
            onCancel: { [weak self] in self?.snapshotPickerWC = nil }
        )
        picker.showWindow(nil)
        picker.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        snapshotPickerWC = picker
    }

    private func openRestoreTree(snapshotURL: URL) {
        let treeWC = TreeWindowController(
            mode: .restore(snapshotURL: snapshotURL),
            onConfirmRestore: { [weak self] url, items, brewInstall, overrides in
                self?.treeWindowController = nil
                self?.startRestore(snapshotURL: url, items: items, brewInstall: brewInstall, overrides: overrides)
            }
        )
        treeWC.showWindow(nil)
        treeWC.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        treeWindowController = treeWC
    }

    private func startBackup(selectedPaths: [String], includeRightsManagedFiles: Bool) {
        guard !uiState.isCleaning else { return }
        guard var pending = config else { return }
        pending.source.paths = selectedPaths
        pending.protection.includeRightsManagedFiles = includeRightsManagedFiles
        do {
            try pending.save(to: Config.defaultPath)
        } catch {
            Log.error("Cannot save backup preferences: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Impossibile salvare le impostazioni"
            alert.informativeText = "Backup non avviato. \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        self.config = pending
        iconManager.setState(.running)
        uiState.appState = .running
        Log.info("Backup started: \(pending.source.paths.count) paths -> \(pending.destination.path)")

        // Captured by value: a `var` crossing into a detached task is an error under
        // Swift 6 concurrency checking.
        let config = pending

        Task.detached {
            do {
                let result = try await BackupEngine.run(config: config)
                await MainActor.run {
                    if let m = result?.manifest {
                        if m.complete {
                            Log.info("Backup completed: complete")
                            self.sendNotification(title: "Backup completo",
                                                  body: "\(m.filesProcessed) file salvati, 0 errori.")
                        } else {
                            Log.warn("Backup completed: INCOMPLETE")
                            self.sendNotification(title: "Backup incompleto",
                                                  body: m.incompleteReasons.first ?? "Apri il menu per i dettagli.")
                        }
                    }
                    self.pollStatus(forceProtection: true)
                }
            } catch {
                await MainActor.run {
                    Log.error("Backup failed: \(error.localizedDescription)")
                    self.iconManager.setState(.error)
                    self.uiState.appState = .error
                    self.sendNotification(title: "Backup non riuscito",
                                          body: error.localizedDescription)
                }
            }
        }
    }

    private func handleStop() {
        // F-14: .stopping shows "Stopping…" in UI until engine drain confirms idle
        uiState.appState = .stopping
        iconManager.setState(.stopping)
        BackupEngine.stop()
        pollStatus()
    }

    private func handleEject() {
        guard !uiState.isCleaning else { return }
        guard let config = config else { return }
        let volumePath = URL(fileURLWithPath: config.destination.path).deletingLastPathComponent()
        let volumeName = volumePath.lastPathComponent
        popover.performClose(nil)
        Log.info("Ejecting: \(volumePath.path)")

        DispatchQueue.global(qos: .userInitiated).async {
            let success = Self.runDiskutil(["eject", volumePath.path])
                || Self.runDiskutil(["unmount", "force", volumePath.path])
            DispatchQueue.main.async {
                if success {
                    Log.info("Disk ejected: \(volumeName)")
                    self.sendNotification(title: "Disco espulso",
                                          body: "\(volumeName) safely removed")
                    self.iconManager.setState(.diskAbsent)
                    self.pollStatus()
                } else {
                    Log.error("Eject failed: \(volumeName)")
                    self.sendNotification(title: "Eject failed",
                                          body: "Another app is using \(volumeName). Close it and retry.")
                }
            }
        }
    }

    private func handleOpenFolder() {
        guard let config = config else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: config.destination.path))
    }

    private func handleSelectDisk(_ volumeURL: URL) {
        let backupDir = volumeURL.appendingPathComponent("RustyMacBackup")
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            sendNotification(title: "Errore", body: "Non riesco a creare la cartella di backup: \(error.localizedDescription)")
            return
        }

        let newConfig = generateDefaultConfig(backupPath: backupDir.path)
        do {
            try newConfig.save(to: Config.defaultPath)
            config = try Config.load(from: Config.defaultPath)
        } catch {
            sendNotification(title: "Errore", body: "Non riesco a salvare la configurazione: \(error.localizedDescription)")
            return
        }

        sendNotification(title: "Setup complete",
                         body: "Backing up \(newConfig.source.paths.count) paths to \(volumeURL.lastPathComponent)")
        pollStatus()
    }

    private func startRestore(snapshotURL: URL, items: [String], brewInstall: Bool, overrides: [String: String] = [:]) {
        guard !uiState.isCleaning else { return }
        // F-10: Preflight free-space check (payload × 2 to account for pre-restore backup copy)
        let estimate = RestoreEngine.estimateRestoreSize(snapshotURL: snapshotURL, items: items)
        let required = estimate * 2
        let available = BackupEngine.diskFreeSpace(at: NSHomeDirectory())
        if required > available && required > 0 {
            let alert = NSAlert()
            alert.messageText = "Spazio insufficiente per il restore"
            alert.informativeText = "Servono circa \(Fmt.formatBytes(required)) liberi, disponibili \(Fmt.formatBytes(available))."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Annulla")
            alert.runModal()
            return
        }

        iconManager.setState(.running)
        uiState.appState = .restoring  // F-14: distinct state from backup .running
        Log.info("Restore started: \(items.count) items from \(snapshotURL.lastPathComponent)")
        sendNotification(title: "Ripristino avviato",
                         body: "Ripristino \(items.count) elementi da \(snapshotURL.lastPathComponent)…")

        // Reopen popover so user can see progress bar
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. Brew FIRST — installs missing tools before restoring their configs
            var brewOK = true
            if brewInstall {
                DispatchQueue.main.async {
                    self?.sendNotification(title: "Programmi Homebrew…",
                                           body: "Installazione in corso (qualche minuto)…")
                    if var s = self?.uiState.status {
                        s.currentFile = "Installing Homebrew packages…"
                        self?.uiState.status = s
                    }
                }
                brewOK = RestoreEngine.restoreHomebrew(snapshotURL: snapshotURL)
            }

            // 2. Restore files
            let result = RestoreEngine.restore(snapshotURL: snapshotURL, items: items,
                                               destinationOverrides: overrides) { item, done, total in
                Log.info("Restoring [\(done)/\(total)] \(item)")
                DispatchQueue.main.async {
                    guard var s = self?.uiState.status else { return }
                    s.state = "running"
                    s.currentFile = item
                    s.filesDone = UInt64(done)
                    s.filesTotal = UInt64(total)
                    s.bytesCopied = 0
                    self?.uiState.status = s
                }
            }

            DispatchQueue.main.async {
                self?.iconManager.setState(.idle)
                let brewMsg = brewInstall ? (brewOK ? "\nProgrammi Homebrew installati." : "\nHomebrew con errori.") : ""
                let backupMsg = result.backedUpTo.isEmpty ? "" : "\nLe versioni precedenti sono annullabili dal menu."
                Log.info("Restore complete: \(result.restored) restored, \(result.overwritten) overwritten, \(result.failed) failed")
                self?.sendNotification(
                    title: "Ripristino completato",
                    body: "\(result.restored) ripristinati, \(result.overwritten) sostituiti, \(result.failed) non riusciti\(brewMsg)\(backupMsg)")

                // F-18: Show restore result card for 60s
                self?.uiState.restoreResult = RestoreResultSummary(
                    restored: result.restored, overwritten: result.overwritten,
                    failed: result.failed, backedUpTo: result.backedUpTo)
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    self?.uiState.restoreResult = nil
                }

                let backupDir = snapshotURL.deletingLastPathComponent()
                let newConfig = generateDefaultConfig(backupPath: backupDir.path)
                try? newConfig.save(to: Config.defaultPath)
                self?.config = try? Config.load(from: Config.defaultPath)
                self?.pollStatus()
            }
        }
    }

    private func handleUndoRestore() {
        // 3.0 restores keep an exact record (undo.json): use it, it also removes files the
        // restore created. Older pre-restore folders keep the previous behaviour.
        if let undoDir = latestUndoDir() {
            popover.performClose(nil)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = (try? SelectiveRestore.undo(undoDir)) ?? RestoreResult(failed: 1)
                DispatchQueue.main.async {
                    self?.sendNotification(title: "Ripristino annullato",
                                           body: "\(result.restored) file rimessi com'erano, \(result.failed) non riusciti.")
                    self?.pollStatus()
                }
            }
            return
        }
        guard let backupDir = RestoreEngine.latestPreRestoreBackup() else { return }
        popover.performClose(nil)
        iconManager.setState(.running)
        uiState.appState = .running
        sendNotification(title: "Annullo il ripristino…", body: "Rimetto i file originali")
        Log.info("Undo restore started from \(backupDir.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RestoreEngine.undoRestore(from: backupDir)
            DispatchQueue.main.async {
                self?.iconManager.setState(.idle)
                Log.info("Undo complete: \(result.restored) restored, \(result.failed) failed")
                self?.sendNotification(
                    title: "Ripristino annullato",
                    body: "\(result.restored) file rimessi com'erano, \(result.failed) non riusciti")
                self?.pollStatus()
            }
        }
    }

    // MARK: - Auto-update

    private func handleRequestUpdate() {
        guard let version = uiState.updateAvailable else { return }
        uiState.isUpdating = true
        uiState.updatePhase = .downloading
        Task { [weak self] in
            do {
                try await AutoUpdater.downloadAndInstall(version: version) { [weak self] phase in
                    DispatchQueue.main.async { self?.uiState.updatePhase = phase }
                }
                DispatchQueue.main.async {
                    self?.uiState.isUpdating = false
                    self?.uiState.updatePhase = nil
                }
            } catch {
                Log.error("Update failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.uiState.isUpdating = false
                    self?.uiState.updatePhase = nil
                    self?.sendNotification(title: "Aggiornamento fallito", body: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Volume notifications

    @objc private func volumeChanged() { pollStatus() }

    // MARK: - Status polling

    private func pollStatus(forceProtection: Bool = false) {
        let newState = statusManager.poll(config: config)
        // F-14: don't clobber .stopping/.restoring set by action handlers
        if newState != .running || (uiState.appState != .stopping && uiState.appState != .restoring) {
            iconManager.setState(newState)
            uiState.appState = newState
        }
        uiState.status = statusManager.lastStatus
        uiState.config = config
        // F-19: update cached disk-state values (disk I/O here, not in SwiftUI render)
        uiState.cachedHasBackups = config != nil && !RestoreEngine.findBackupSnapshots().isEmpty
        uiState.cachedCanUndo = RestoreEngine.hasPreRestoreBackup() || latestUndoDir() != nil
        refreshProtection(force: forceProtection)
    }

    /// Snapshot manifests live on the backup disk: read them at most every 20 s (or right
    /// after a backup), never from SwiftUI's render path.
    private func refreshProtection(force: Bool) {
        guard let config, force || Date().timeIntervalSince(lastProtectionRefresh) > 20 else { return }
        lastProtectionRefresh = Date()
        let dest = URL(fileURLWithPath: config.destination.path)
        let cfg = config
        DispatchQueue.global(qos: .utility).async {
            let summary = FileManager.default.fileExists(atPath: dest.path) ? ProtectionSummary.build(destination: dest) : nil
            let sources = Set(cfg.source.paths.map { ConfigDiscovery.expand($0) })
            let ignored = Set(cfg.coverage.ignore.map { ConfigDiscovery.expand($0) })
            let dbs = Set(cfg.databases.sqlite.map { ConfigDiscovery.expand($0) })
            let gaps = (StatusWriter().readCoverage()?.gaps ?? []).filter { gap in
                let p = ConfigDiscovery.expand(gap.path)
                return !sources.contains(p) && !ignored.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) && !dbs.contains(p)
            }
            DispatchQueue.main.async {
                if let summary { self.uiState.protection = summary }
                self.uiState.coverageGaps = gaps
            }
        }
    }

    private func latestUndoDir() -> URL? {
        let base = RestoreEngine.preRestoreBaseURL
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).sorted()
        return names.reversed().map { base.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("undo.json").path) }
    }

    // MARK: - 3.0: restore center and coverage

    private func handleOpenRestoreCenter() {
        guard let config else { return }
        popover.performClose(nil)
        if let wc = restoreCenterWC, wc.window?.isVisible == true {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = RestoreCenterModel(destination: URL(fileURLWithPath: config.destination.path), config: config)
        model.onAdvanced = { [weak self] in
            self?.restoreCenterWC?.window?.close()
            self?.handleRequestRestore()
        }
        model.onDone = { [weak self] r in
            self?.uiState.restoreResult = RestoreResultSummary(restored: r.restored, overwritten: r.overwritten,
                                                               failed: r.failed, backedUpTo: r.backedUpTo)
            self?.pollStatus()
        }
        let wc = RestoreCenterWindowController(model: model)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        restoreCenterWC = wc
    }

    private func handleCoverage(_ gap: CoverageGap, ignore: Bool) {
        guard var pending = config else { return }
        if ignore {
            if !pending.coverage.ignore.contains(gap.path) { pending.coverage.ignore.append(gap.path) }
        } else if gap.kind == .database {
            if !pending.databases.sqlite.contains(gap.path) { pending.databases.sqlite.append(gap.path) }
        } else if !pending.source.paths.contains(gap.path) {
            pending.source.paths.append(gap.path)
        }
        do {
            try pending.save(to: Config.defaultPath)
            config = pending
            uiState.config = pending
            uiState.coverageGaps.removeAll { $0.path == gap.path }
            Log.info("Coverage: \(ignore ? "ignored" : "added") \(gap.path)")
        } catch {
            Log.error("Cannot save coverage change: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Deliberately off the main actor: it spawns `diskutil` and blocks until it exits,
    /// and `handleEject` calls it from a background queue for exactly that reason.
    nonisolated private static func runDiskutil(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    private func sendNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopWatchingForOutsideClick()
    }
}

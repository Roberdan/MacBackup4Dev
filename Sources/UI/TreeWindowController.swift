import Cocoa
import SwiftUI

// MARK: - Mode

enum TreeWindowMode {
    case backup
    case restore(snapshotURL: URL)

    var isBackup: Bool {
        if case .backup = self { return true }
        return false
    }
}

// MARK: - Controller

/// Thin NSWindowController wrapping a SwiftUI TreeView via NSHostingController.
/// Callers pass completion closures instead of using a delegate.
class TreeWindowController: NSWindowController {

    init(mode: TreeWindowMode,
         enabledPaths: Set<String> = [],
         includeRightsManagedFiles: Bool = false,
         onConfirmBackup: @escaping ([String], Bool) -> Void = { _, _ in },
         onConfirmRestore: @escaping (URL, [String], Bool, [String: String]) -> Void = { _, _, _, _ in }) {

        let model = TreeSelectionModel(mode: mode, enabledPaths: enabledPaths,
                                       includeRightsManagedFiles: includeRightsManagedFiles)
        model.onConfirmBackup = onConfirmBackup
        model.onConfirmRestore = onConfirmRestore

        let hosting = NSHostingController(rootView: TreeView(model: model))

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 540, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 460)

        switch mode {
        case .backup:
            window.title = "Backup — scegli cosa salvare"
        case .restore(let url):
            window.title = "Ripristina — \(url.lastPathComponent)"
        }

        super.init(window: window)

        // Wire cancel to close the window.
        model.onCancel = { [weak self] in self?.window?.close() }

        // After confirm, close the window then call through.
        model.onConfirmBackup = { [weak self, onConfirmBackup] paths, includeRightsManagedFiles in
            self?.window?.close()
            onConfirmBackup(paths, includeRightsManagedFiles)
        }
        model.onConfirmRestore = { [weak self, onConfirmRestore] url, items, brew, overrides in
            self?.window?.close()
            onConfirmRestore(url, items, brew, overrides)
        }

        model.onRequestAddPath = { [weak window] in
            guard let win = window else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.message = "Seleziona cartelle o file da aggiungere al backup"
            panel.prompt = "Aggiungi"
            panel.beginSheetModal(for: win) { result in
                guard result == .OK else { return }
                for url in panel.urls {
                    let contracted = ConfigDiscovery.contract(url.path)
                    Task { @MainActor in model.addCustomPath(contracted) }
                }
            }
        }

        model.onRequestChangeDestination = { [weak window] _, completion in
            guard let win = window else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Scegli dove ripristinare questo elemento"
            panel.prompt = "Scegli"
            panel.beginSheetModal(for: win) { result in
                guard result == .OK, let url = panel.url else { return }
                completion(ConfigDiscovery.contract(url.path))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

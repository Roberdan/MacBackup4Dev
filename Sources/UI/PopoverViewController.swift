import Cocoa
import SwiftUI

/// Thin wrapper that hosts PopoverView (SwiftUI) inside an NSViewController.
/// AppDelegate owns `uiState` and passes it in; this class just hosts the view.
class PopoverViewController: NSViewController {

    private let uiState: AppUIState
    private var hostingController: NSHostingController<AnyView>?

    init(uiState: AppUIState) {
        self.uiState = uiState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let hosting = NSHostingController(
            rootView: AnyView(PopoverView().environmentObject(uiState))
        )
        // Let the popover grow/shrink with its content instead of clipping rows under each other.
        hosting.sizingOptions = [.preferredContentSize]
        hostingController = hosting
        addChild(hosting)
        view = hosting.view
    }

    /// The popover sizes itself from THIS controller's preferredContentSize, not the hosted
    /// child's: forward every change, or the popover keeps the size it had when it opened and
    /// clips the content when a backup starts (seen 2026-10-07: header and last rows cut).
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        preferredContentSize = viewController.preferredContentSize
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if let hosting = hostingController { preferredContentSize = hosting.view.fittingSize }
    }

    /// Called by AppDelegate after updating uiState — SwiftUI observes changes automatically.
    func refresh() {
        // No manual refresh needed; SwiftUI reacts to @Published properties on uiState.
    }
}


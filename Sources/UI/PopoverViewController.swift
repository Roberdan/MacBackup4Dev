import Cocoa
import SwiftUI

/// The popover's content controller IS the SwiftUI hosting controller: NSPopover sizes itself
/// from its content controller's preferredContentSize, which the hosting controller keeps in
/// sync with the SwiftUI layout. The previous wrapper (a plain NSViewController around a
/// child hosting controller) never passed the size on, so the popover stayed at macOS's
/// default 320×320 and clipped the content on every side (seen 2026-10-07, measured with
/// `RustyMacBackup measure-menu`).
final class PopoverViewController: NSHostingController<AnyView> {
    init(uiState: AppUIState) {
        super.init(rootView: AnyView(PopoverView().environmentObject(uiState)))
        sizingOptions = [.preferredContentSize]
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    /// Called by AppDelegate after updating uiState — SwiftUI observes changes automatically.
    func refresh() {}
}

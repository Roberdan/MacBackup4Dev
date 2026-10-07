import Foundation
import IOKit.ps

/// Where the Mac is drawing power from. `unknown` means the reader could not tell.
enum PowerSource: Equatable {
    case ac
    case battery
    case unknown
}

/// Battery is priority 1: scheduled (launchd) backups run only on wall power.
/// Fail-closed: anything other than a positive "AC" answer skips the run.
enum PowerGate {
    static let skipMessage = "skipped: on battery"

    /// Reads the providing power source through IOKit (no shelling out).
    static func currentSource() -> PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String?
        else { return .unknown }
        if type == kIOPMACPowerKey { return .ac }
        if type == kIOPMBatteryPowerKey || type == kIOPMUPSPowerKey { return .battery }
        return .unknown
    }

    /// True when a scheduled backup may run. Only a positive AC reading allows it.
    static func scheduledBackupAllowed(reader: () -> PowerSource = PowerGate.currentSource) -> Bool {
        reader() == .ac
    }
}

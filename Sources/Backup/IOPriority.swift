import Foundation
import Darwin
import IOKit
import IOKit.ps

enum IOPriority {
    static func backupPolicy(onBattery: Bool, previous: Int32) -> Int32 {
        if onBattery || previous == IOPOL_THROTTLE { return IOPOL_THROTTLE }
        if previous == IOPOL_PASSIVE { return IOPOL_PASSIVE }
        return IOPOL_UTILITY
    }

    /// Never raise a schedule's existing low priority; restore it when the backup ends.
    static func beginBackup(onBattery: Bool) throws -> Int32 {
        let previous = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS)
        guard previous >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try setDiskPolicy(backupPolicy(onBattery: onBattery, previous: previous))
        return previous
    }

    static func setDiskPolicy(_ policy: Int32) throws {
        guard setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, policy) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    /// Detect if running on battery power. Returns false on desktop Macs or when undeterminable.
    static func isOnBattery() -> Bool {
        guard let psInfoRaw = IOPSCopyPowerSourcesInfo() else { return false }
        let psInfo = psInfoRaw.takeRetainedValue()

        guard let listRaw = IOPSCopyPowerSourcesList(psInfo) else { return false }
        let sources = listRaw.takeRetainedValue() as [AnyObject]
        guard !sources.isEmpty else { return false }

        for source in sources {
            guard let descRaw = IOPSGetPowerSourceDescription(psInfo, source as CFTypeRef) else { continue }
            let desc = descRaw.takeUnretainedValue() as? [String: Any]
            if let state = desc?[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue {
                return true
            }
        }
        return false
    }
}

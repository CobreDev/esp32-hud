import Foundation
import IOKit.ps

struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
}

/// Reads the Mac's internal battery through IOKit. Returns nil on Macs without one.
/// The value is cached briefly: percent changes slowly and the HUD asks every second.
@MainActor
final class BatteryMonitor {
    private var cached: BatteryInfo?
    private var lastRead = Date.distantPast
    private let maxAge: TimeInterval = 20

    func current(now: Date = Date()) -> BatteryInfo? {
        if now.timeIntervalSince(lastRead) >= maxAge {
            cached = Self.read()
            lastRead = now
        }
        return cached
    }

    private static func read() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) == true
                || (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return BatteryInfo(percent: Int((Double(cur) / Double(max) * 100).rounded()), charging: charging)
        }
        return nil
    }
}

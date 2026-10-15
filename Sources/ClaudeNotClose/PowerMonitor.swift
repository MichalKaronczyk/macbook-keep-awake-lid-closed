import Foundation
import IOKit.ps

struct PowerInfo {
    var onACPower: Bool
    var batteryPercent: Int?
    var isCharging: Bool
    var minutesRemaining: Int?

    var summary: String {
        var parts: [String] = []
        parts.append(onACPower ? "AC power" : "battery")
        if let pct = batteryPercent {
            parts.append("\(pct)%")
        }
        if let mins = minutesRemaining, mins > 0, !onACPower {
            parts.append("~\(Format.duration(TimeInterval(mins * 60)))")
        } else if isCharging {
            parts.append("charging")
        }
        return parts.joined(separator: " · ")
    }
}

enum PowerMonitor {

    static func snapshot() -> PowerInfo {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerInfo(onACPower: true, batteryPercent: nil, isCharging: false, minutesRemaining: nil)
        }

        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        let onAC = providing != (kIOPSBatteryPowerValue as String)

        var percent: Int?
        var charging = false
        var minutes: Int?

        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
                guard (desc[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String)
                        || desc[kIOPSCurrentCapacityKey as String] != nil else { continue }

                if let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
                   let max = desc[kIOPSMaxCapacityKey as String] as? Int, max > 0 {
                    percent = Int((Double(current) / Double(max) * 100).rounded())
                }
                charging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
                if let toEmpty = desc[kIOPSTimeToEmptyKey as String] as? Int, toEmpty > 0 {
                    minutes = toEmpty
                }
                break
            }
        }

        return PowerInfo(onACPower: onAC, batteryPercent: percent,
                         isCharging: charging, minutesRemaining: minutes)
    }
}

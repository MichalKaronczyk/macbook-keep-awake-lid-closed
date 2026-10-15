import Foundation
import IOKit

/// Reads real power draw from the battery controller and tracks the drain rate.
///
/// `AppleSmartBattery` reports `Amperage` (mA, negative while discharging) and
/// `Voltage` (mV). Their product is the instantaneous draw in watts — the same
/// quantity behind Activity Monitor's "Energy Impact", only measured, not guessed.
enum EnergyMonitor {

    struct Reading {
        var watts: Double?
        var voltage: Double?
        var amperage: Double?
        var temperature: Double?
        var cycleCount: Int?
        var health: Int?
    }

    struct Sample {
        var date: Date
        var percent: Double?
        var watts: Double?
    }

    // MARK: - Hardware read

    static func read() -> Reading {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return Reading() }
        defer { IOObjectRelease(service) }

        func number(_ key: String) -> Double? {
            guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                            kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber else { return nil }
            // Amperage is sometimes stored as a UInt64 wrapping a negative value.
            let value = raw.int64Value
            return Double(value)
        }

        let amperage = number("Amperage").map(unwrapSigned)
        let voltage = number("Voltage")
        var watts: Double?
        if let amperage, let voltage {
            watts = abs(amperage) * voltage / 1_000_000.0   // mA * mV -> W
        }

        return Reading(
            watts: watts,
            voltage: voltage.map { $0 / 1000.0 },
            amperage: amperage,
            temperature: number("Temperature").map { $0 / 100.0 },
            cycleCount: number("CycleCount").map { Int($0) },
            health: number("MaxCapacity").map { Int($0) }
        )
    }

    /// Unwraps a wrapped UInt64 back into a proper negative number.
    private static func unwrapSigned(_ value: Double) -> Double {
        // int64Value already unwraps correctly; this guards the case where IOKit
        // hands the value over unsigned.
        if value > 9_000_000_000_000_000_000 {
            return value - 18_446_744_073_709_551_616
        }
        return value
    }

    // MARK: - History and statistics

    private static var samples: [Sample] = []
    private static let maxSamples = 240

    /// Baseline draw captured before power saving engaged (to compute the saving).
    private(set) static var baselineWatts: Double?

    static func record(percent: Int?, watts: Double?) {
        samples.append(Sample(date: Date(),
                              percent: percent.map(Double.init),
                              watts: watts))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    static func reset() {
        samples.removeAll()
        baselineWatts = nil
    }

    /// Smoothed draw — the mean over the last ~30 s, since instant readings jump.
    static func smoothedWatts(window: TimeInterval = 30) -> Double? {
        let cutoff = Date().addingTimeInterval(-window)
        let values = samples.filter { $0.date >= cutoff }.compactMap(\.watts)
        guard !values.isEmpty else { return samples.compactMap(\.watts).last }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Stores the current draw as the reference point.
    static func captureBaseline() {
        baselineWatts = smoothedWatts(window: 60) ?? smoothedWatts(window: 300)
    }

    static func clearBaseline() {
        baselineWatts = nil
    }

    /// How many watts were saved relative to the reference point.
    static func savedWatts() -> Double? {
        guard let baseline = baselineWatts, let now = smoothedWatts() else { return nil }
        let delta = baseline - now
        return delta > 0.1 ? delta : nil
    }

    /// Drain rate in percentage points per hour.
    static func drainPercentPerHour() -> Double? {
        let withPercent = samples.filter { $0.percent != nil }
        guard let first = withPercent.first, let last = withPercent.last,
              let p0 = first.percent, let p1 = last.percent else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0.05 else { return nil }     // need at least ~3 minutes of data
        let drop = p0 - p1
        guard drop > 0 else { return nil }
        return drop / hours
    }

    /// Time left until the given threshold at the current rate.
    static func projectedRuntime(currentPercent: Int?, floorPercent: Int) -> TimeInterval? {
        guard let current = currentPercent, let rate = drainPercentPerHour(), rate > 0 else { return nil }
        let usable = Double(current - floorPercent)
        guard usable > 0 else { return 0 }
        return usable / rate * 3600
    }

    static func formatWatts(_ watts: Double?) -> String {
        guard let watts else { return "—" }
        return String(format: "%.1f W", watts)
    }
}

import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac alive.
///
/// Layers:
///  1. `PreventUserIdleSystemSleep` – blocks idle sleep.
///  2. `NetworkClientActive`        – the assertion Apple documents as providing "CPU,
///                                    disk, and network connectivity". This is the one
///                                    that keeps a streaming API call from being torn
///                                    down when the display sleeps. On AC it holds the
///                                    system in dark or full wake; on battery it only
///                                    prevents *idle* sleep.
///  3. `PreventSystemSleep`         – what `caffeinate -s` takes. IOPMLib.h marks it
///                                    deprecated since 10.9 and "not supported in any
///                                    OS X releases", so it is a belt-and-braces extra,
///                                    never the thing we rely on.
///  4. `PreventUserIdleDisplaySleep`– optional: keep the display on too.
///  5. `pmset -a disablesleep 1`    – the "hard" mode and the *only* thing that stops a
///                                    lid close from sleeping the Mac on battery. Needs
///                                    admin rights, so opt-in.
///
/// Every IOKit assertion is a suggestion: Apple's own docs say the system may sleep
/// anyway under battery, thermal or user circumstances. Closing the lid on battery is
/// exactly such a circumstance — only layer 5 survives it.
final class SleepManager {

    private var idleAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var systemAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var networkAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var displayAssertion: IOPMAssertionID = IOPMAssertionID(0)

    private(set) var holdsDisplay = false
    private(set) var clamshellOverrideActive = false

    var isHolding: Bool { systemAssertion != 0 }

    // The "PreventSystemSleep" constant is exposed inconsistently across IOKit
    // headers, so use the literal — it has been stable API for years.
    private let preventSystemSleepType = "PreventSystemSleep" as CFString
    private let networkClientActiveType = kIOPMAssertNetworkClientActive as CFString
    private let preventIdleSleepType = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
    private let preventDisplaySleepType = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString

    // Plain ASCII — this name shows up in `pmset -g assertions`, which mangles UTF-8.
    private let reason = "Claude Not Close: Claude Code is working" as CFString

    // MARK: - Power assertions

    /// Starts holding the Mac awake. Idempotent.
    func beginHold(keepDisplayAwake: Bool) {
        if systemAssertion == 0 {
            IOPMAssertionCreateWithName(preventSystemSleepType, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        reason, &systemAssertion)
        }
        if networkAssertion == 0 {
            IOPMAssertionCreateWithName(networkClientActiveType, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        reason, &networkAssertion)
        }
        if idleAssertion == 0 {
            IOPMAssertionCreateWithName(preventIdleSleepType, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        reason, &idleAssertion)
        }
        setDisplayHold(keepDisplayAwake)
    }

    /// Releases every assertion. Idempotent.
    func endHold() {
        setDisplayHold(false)
        if idleAssertion != 0 {
            IOPMAssertionRelease(idleAssertion)
            idleAssertion = IOPMAssertionID(0)
        }
        if networkAssertion != 0 {
            IOPMAssertionRelease(networkAssertion)
            networkAssertion = IOPMAssertionID(0)
        }
        if systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = IOPMAssertionID(0)
        }
    }

    /// Toggles the separate display assertion without touching the others.
    func setDisplayHold(_ enabled: Bool) {
        if enabled, displayAssertion == 0 {
            IOPMAssertionCreateWithName(preventDisplaySleepType, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        reason, &displayAssertion)
        } else if !enabled, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = IOPMAssertionID(0)
        }
        holdsDisplay = displayAssertion != 0
    }

    // MARK: - Hard mode (lid close on battery too)

    /// Reads the current `SleepDisabled` state from pmset.
    /// Note: pmset only prints this line when the flag is set to 1 — a missing line
    /// means 0.
    static func readSystemSleepDisabled() -> Bool {
        guard let out = Shell.run("/usr/bin/pmset", ["-g"]) else { return false }
        for line in out.split(whereSeparator: \.isNewline)
        where line.localizedCaseInsensitiveContains("SleepDisabled") {
            let lastToken = line.split(whereSeparator: \.isWhitespace).last
            return lastToken == "1"
        }
        return false
    }

    /// Sets `pmset -a disablesleep`. Prompts for the admin password (once per
    /// authorization session).
    /// - Returns: `true` if the requested state was applied.
    @discardableResult
    func setClamshellOverride(_ enabled: Bool) -> Bool {
        let value = enabled ? "1" : "0"
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        let ok = Shell.run("/usr/bin/osascript", ["-e", script]) != nil
        if ok {
            clamshellOverrideActive = enabled
        }
        return ok
    }

    /// Called at launch to mirror the system state after a possible crash.
    func syncClamshellOverrideState() {
        clamshellOverrideActive = SleepManager.readSystemSleepDisabled()
    }

    /// Emergency restore of system settings — called when the app quits.
    func restoreSystemDefaultsIfNeeded() {
        if clamshellOverrideActive {
            setClamshellOverride(false)
        }
    }
}

// MARK: - Small process helper

enum Shell {
    /// Runs a process and returns stdout, or `nil` if it exited with an error.
    static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

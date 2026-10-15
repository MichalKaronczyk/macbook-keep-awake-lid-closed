import Foundation

/// System-wide power-saving switches. Some need root — those are batched into a
/// single call so the user types their password only once.
final class SystemTweaks {

    private(set) var lowPowerModeActive = false
    private(set) var spotlightPaused = false
    /// What we turned on ourselves — only that gets restored on exit.
    private var weEnabledLowPower = false
    private var weePausedSpotlight = false

    // MARK: - Reading state

    func syncState() {
        lowPowerModeActive = SystemTweaks.readLowPowerMode()
        spotlightPaused = SystemTweaks.readSpotlightDisabled()
    }

    static func readLowPowerMode() -> Bool {
        guard let out = Shell.run("/usr/bin/pmset", ["-g"]) else { return false }
        for line in out.split(whereSeparator: \.isNewline)
        where line.localizedCaseInsensitiveContains("lowpowermode") {
            return line.split(whereSeparator: \.isWhitespace).last == "1"
        }
        return false
    }

    static func readSpotlightDisabled() -> Bool {
        guard let out = Shell.run("/usr/bin/mdutil", ["-a", "-s"]) else { return false }
        // We care about the boot volume; "Indexing disabled." == paused.
        return out.localizedCaseInsensitiveContains("Indexing disabled")
    }

    // MARK: - Toggling (a single password prompt)

    /// Applies the selected system options in one `osascript` call.
    /// - Returns: `true` when the command ran (the user entered their password).
    @discardableResult
    func applyPrivileged(lowPowerMode: Bool?, pauseSpotlight: Bool?) -> Bool {
        var commands: [String] = []

        if let lowPowerMode {
            commands.append("/usr/bin/pmset -a lowpowermode \(lowPowerMode ? 1 : 0)")
        }
        if let pauseSpotlight {
            commands.append("/usr/bin/mdutil -a -i \(pauseSpotlight ? "off" : "on")")
        }
        guard !commands.isEmpty else { return true }

        let joined = commands.joined(separator: " ; ")
        let script = "do shell script \"\(joined)\" with administrator privileges"
        guard Shell.run("/usr/bin/osascript", ["-e", script]) != nil else { return false }

        if let lowPowerMode {
            lowPowerModeActive = lowPowerMode
            if lowPowerMode { weEnabledLowPower = true } else { weEnabledLowPower = false }
        }
        if let pauseSpotlight {
            spotlightPaused = pauseSpotlight
            if pauseSpotlight { weePausedSpotlight = true } else { weePausedSpotlight = false }
        }
        return true
    }

    // MARK: - No root needed

    /// Turns the display off immediately. Irrelevant with the lid shut, but with the
    /// lid open it is the single biggest win — the panel is usually 2-6 W.
    static func sleepDisplayNow() {
        _ = Shell.run("/usr/bin/pmset", ["displaysleepnow"])
    }

    // MARK: - Restoring

    /// Undoes only what we turned on. Needs a password, so it runs on explicit
    /// request or when the app quits.
    func restoreIfNeeded() {
        guard weEnabledLowPower || weePausedSpotlight else { return }
        applyPrivileged(lowPowerMode: weEnabledLowPower ? false : nil,
                        pauseSpotlight: weePausedSpotlight ? false : nil)
    }

    var hasPendingRestores: Bool { weEnabledLowPower || weePausedSpotlight }
}

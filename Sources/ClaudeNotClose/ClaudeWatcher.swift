import Foundation

/// Checks whether Claude Code (or another watched process) is running.
enum ClaudeWatcher {

    /// Process names treated as "work in progress".
    static var watchedProcessNames: [String] {
        let stored = Preferences.watchedProcesses
        return stored.isEmpty ? ["claude"] : stored
    }

    /// Number of matching processes. 0 == nothing running.
    static func runningCount() -> Int {
        var total = 0
        for name in watchedProcessNames {
            guard let out = Shell.run("/usr/bin/pgrep", ["-x", name]) else { continue }
            total += out.split(whereSeparator: \.isNewline).count
        }
        return total
    }

    static func isRunning() -> Bool { runningCount() > 0 }
}

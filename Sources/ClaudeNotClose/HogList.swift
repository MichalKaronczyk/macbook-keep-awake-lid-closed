import AppKit

/// CPU usage per app, with helper processes rolled up.
///
/// Raw `ps` shows "Slack Helper (Renderer)" and "Cursor Helper", which tells you
/// nothing. Here the whole tree's CPU is summed and attributed to the parent app.
enum HogList {

    struct AppLoad {
        var app: NSRunningApplication
        var bundleId: String
        var name: String
        var cpu: Double
        var processCount: Int
        var policy: AppPolicy
    }

    /// Total CPU per PID from a single `ps` call.
    private static func cpuByPID() -> [Int32: Double] {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,pcpu="]) else { return [:] }
        var map: [Int32: Double] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]) else { continue }
            map[pid] = cpu
        }
        return map
    }

    /// Apps sorted by CPU usage, descending.
    static func topApps(limit: Int = 6, aggressive: Bool) -> [AppLoad] {
        let cpuMap = cpuByPID()
        let tree = ProcessTree()

        var loads: [AppLoad] = []
        for app in AppCatalog.candidates() {
            guard let bundleId = app.bundleIdentifier else { continue }
            let pids = tree.descendants(of: app.processIdentifier)
            let cpu = pids.reduce(0.0) { $0 + (cpuMap[$1] ?? 0) }
            loads.append(AppLoad(app: app,
                                 bundleId: bundleId,
                                 name: AppCatalog.displayName(app),
                                 cpu: cpu,
                                 processCount: pids.count,
                                 policy: AppCatalog.policy(for: bundleId, aggressive: aggressive)))
        }

        return loads
            .sorted { $0.cpu > $1.cpu }
            .prefix(limit)
            .map { $0 }
    }
}

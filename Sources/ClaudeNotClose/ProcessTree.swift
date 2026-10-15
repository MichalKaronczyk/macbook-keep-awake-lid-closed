import Foundation

/// Parent -> children map, built once from a single `ps` call.
///
/// Essential, because Electron apps (Slack, Telegram, Cursor, VS Code, Discord) burn
/// all their CPU in helper processes that are invisible as `NSRunningApplication`.
/// Throttling the main process alone would achieve nothing — the whole tree has to be
/// covered.
struct ProcessTree {

    private var children: [Int32: [Int32]] = [:]

    init() {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid="]) else { return }
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            children[ppid, default: []].append(pid)
        }
    }

    /// The root plus every descendant, ordered from the root down (BFS).
    func descendants(of root: Int32) -> [Int32] {
        var result: [Int32] = []
        var queue: [Int32] = [root]
        var seen = Set<Int32>()

        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            if let kids = children[pid] {
                queue.append(contentsOf: kids)
            }
        }
        return result
    }
}

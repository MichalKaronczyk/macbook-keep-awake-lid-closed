import Foundation

/// Tells apart the Claude Code windows that talk to the same bot: which session, project
/// and branch a message belongs to. Hook payloads carry no terminal or window id, so this
/// is built from what they do carry.
enum SessionContext {

    private static let lock = NSLock()
    private static var titles: [String: String] = [:]

    /// `SessionStart` is the only event that reports the session title (`--name`, `/rename`).
    static func remember(_ payload: [String: Any]) {
        guard let id = payload["session_id"] as? String, !id.isEmpty else { return }
        let title = (payload["session_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock(); defer { lock.unlock() }
        titles[id] = title.isEmpty ? nil : title
    }

    static func title(for payload: [String: Any]) -> String? {
        guard let id = payload["session_id"] as? String else { return nil }
        lock.lock(); defer { lock.unlock() }
        return titles[id]
    }

    /// HTML footer such as `🏷 <b>auth</b> · 📁 <code>app</code> · 🌿 <code>main</code> · #a3f9`.
    static func line(_ payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let escape = TelegramClient.escape
        var parts: [String] = []
        if let title = title(for: payload) { parts.append("🏷 <b>\(escape(title))</b>") }
        if let project = AgentBridge.projectName(payload) { parts.append("📁 <code>\(escape(project))</code>") }
        if let cwd = payload["cwd"] as? String, let branch = gitBranch(in: cwd) {
            parts.append("🌿 <code>\(escape(branch))</code>")
        }
        if let agent = payload["agent_type"] as? String, !agent.isEmpty { parts.append("🤖 \(escape(agent))") }
        if let id = payload["session_id"] as? String, !id.isEmpty { parts.append("#\(escape(String(id.prefix(4))))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Branch name (or short hash when detached) of the repository containing `cwd`.
    /// Reads `.git/HEAD` directly, also for worktrees where `.git` is a file.
    static func gitBranch(in cwd: String) -> String? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd, isDirectory: true)
        for _ in 0..<16 {
            let git = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                var gitDir = git
                if !isDirectory.boolValue {
                    guard let text = try? String(contentsOf: git, encoding: .utf8),
                          let first = text.split(separator: "\n").first, first.hasPrefix("gitdir:") else { return nil }
                    let path = first.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: path, isDirectory: true, relativeTo: dir)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                else { return nil }
                let value = head.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : String(value.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }
}

import Foundation

/// Adds / removes the Claude Code hooks that forward events to this app.
/// Only runs when the user asks for it from the menu; a backup is kept next to the file.
enum HooksInstaller {

    static let events: [(name: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("PreToolUse", "AskUserQuestion"),
        ("PermissionRequest", nil),
        ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"),
        ("Stop", nil),
        ("StopFailure", nil),
    ]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var command: String {
        "curl -s -m 600 -H 'Content-Type: application/json' --data-binary @- "
            + "http://127.0.0.1:\(Preferences.hookPort)\(HookServer.secretPath) || true"
    }

    /// Ours are recognised by the loopback hook URL.
    static func isOurs(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains {
            guard let command = $0["command"] as? String else { return false }
            return command.contains("127.0.0.1:") && command.contains("/hook/")
        }
    }

    /// Returns `settings` with our hooks added (replacing any older copy of them).
    static func installed(into settings: [String: Any], command: String) -> [String: Any] {
        var result = removed(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var list = hooks[event.name] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 600]]]
            if let matcher = event.matcher { entry["matcher"] = matcher }
            list.append(entry)
            hooks[event.name] = list
        }
        result["hooks"] = hooks
        return result
    }

    /// Returns `settings` without any of our hooks; other hooks stay untouched.
    static func removed(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for (name, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let kept = list.filter { !isOurs($0) }
            hooks[name] = kept.isEmpty ? nil : kept
        }
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    static func isInstalled() -> Bool {
        guard let settings = read(), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: isOurs) == true }
    }

    struct Unreadable: Error {}

    /// Current settings, `[:]` when the file does not exist; throws when it exists but is not JSON.
    private static func current() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let settings = read() else { throw Unreadable() }
        return settings
    }

    static func install() throws { try write(installed(into: try current(), command: command)) }
    static func uninstall() throws { try write(removed(from: try current())) }

    private static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func write(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("cnc-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}

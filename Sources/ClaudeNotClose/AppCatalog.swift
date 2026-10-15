import AppKit

/// What to do with an app while power saving is engaged.
enum AppPolicy: String, CaseIterable, Codable {
    /// Leave it alone — tools the agent relies on.
    case protected
    /// `taskpolicy -b` — background: CPU and I/O throttling. Reversible, safe.
    case throttle
    /// SIGSTOP — process frozen outright. Saves the most, but needs care.
    case suspend
    /// Graceful quit (same as ⌘Q).
    case quit

    var label: String {
        switch self {
        case .protected: return "Protected (full speed)"
        case .throttle:  return "Throttle (background)"
        case .suspend:   return "Freeze (SIGSTOP)"
        case .quit:      return "Quit"
        }
    }

    var shortLabel: String {
        switch self {
        case .protected: return "full speed"
        case .throttle:  return "background"
        case .suspend:   return "freeze"
        case .quit:      return "quit"
        }
    }

    var symbol: String {
        switch self {
        case .protected: return "shield.lefthalf.filled"
        case .throttle:  return "tortoise"
        case .suspend:   return "snowflake"
        case .quit:      return "xmark.circle"
        }
    }
}

enum AppCatalog {

    /// Tools the agent needs at full speed. Never throttled.
    static let defaultProtected: Set<String> = [
        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        // Editors / IDEs
        "com.todesktop.230313mzl4w4u92",          // Cursor
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.exafunction.windsurf",
        // Apple dev tooling
        "com.apple.dt.Xcode",
        "com.apple.iphonesimulator",
        "com.apple.CoreSimulator.SimulatorTrampoline",
        "com.apple.Simulator",
        // Claude
        "com.anthropic.claudefordesktop",
        "com.anthropic.claude",
        // Browsers agents drive (Claude in Chrome, DevTools, previews)
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        // Containers / databases
        "com.docker.docker",
        "com.orbstack.OrbStack",
    ]

    /// Prefixes treated as protected (whole app families).
    static let protectedPrefixes: [String] = [
        "com.jetbrains.",             // IntelliJ, PyCharm, WebStorm…
        "com.apple.CoreSimulator",
        "com.apple.dt.",
    ]

    /// Apps that must never be touched — the system trips over them.
    static let neverTouch: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.systempreferences",
        "com.apple.SecurityAgent",
        "com.apple.ActivityMonitor",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    /// The apps we consider at all: ordinary windowed apps with a bundle id,
    /// excluding ourselves and the never-touch list.
    ///
    /// The `activationPolicy == .regular` filter is the key safety measure here —
    /// it screens out every daemon, agent and system process without a Dock icon.
    static func candidates() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { return false }
            guard app.processIdentifier != ownPID else { return false }
            guard !app.isTerminated else { return false }
            guard !neverTouch.contains(bundleId) else { return false }
            return true
        }
    }

    static func isProtectedByDefault(_ bundleId: String) -> Bool {
        if defaultProtected.contains(bundleId) { return true }
        return protectedPrefixes.contains { bundleId.hasPrefix($0) }
    }

    /// Policy for an app: the user's override first, then the default rules.
    static func policy(for bundleId: String, aggressive: Bool) -> AppPolicy {
        if let override = AppPolicyStore.policy(for: bundleId) {
            return override
        }
        if isProtectedByDefault(bundleId) { return .protected }
        return aggressive ? .suspend : .throttle
    }

    static func displayName(_ app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
    }
}

/// Stored user overrides: bundle id -> policy.
enum AppPolicyStore {

    private static let key = "appPolicyOverrides"

    static func all() -> [String: AppPolicy] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else {
            return [:]
        }
        return raw.compactMapValues(AppPolicy.init(rawValue:))
    }

    static func policy(for bundleId: String) -> AppPolicy? {
        all()[bundleId]
    }

    static func set(_ policy: AppPolicy?, for bundleId: String) {
        var raw = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        if let policy {
            raw[bundleId] = policy.rawValue
        } else {
            raw.removeValue(forKey: bundleId)
        }
        UserDefaults.standard.set(raw, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

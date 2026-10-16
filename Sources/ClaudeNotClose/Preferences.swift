import Foundation

enum Preferences {

    private static let d = UserDefaults.standard

    private enum Key {
        static let keepDisplayAwake = "keepDisplayAwake"
        static let autoFollowClaude = "autoFollowClaude"
        static let batteryGuardEnabled = "batteryGuardEnabled"
        static let batteryGuardThreshold = "batteryGuardThreshold"
        static let notificationsEnabled = "notificationsEnabled"
        static let showCountdownInMenuBar = "showCountdownInMenuBar"
        static let defaultDuration = "defaultDuration"
        static let clamshellOverride = "clamshellOverride"
        static let watchedProcesses = "watchedProcesses"
        static let graceMinutes = "graceMinutes"
        static let aggressiveSaving = "aggressiveSaving"
        static let autoArmOnLidClose = "autoArmOnLidClose"
        static let displayOffOnEngage = "displayOffOnEngage"
        static let showRuntimeInMenuBar = "showRuntimeInMenuBar"
        static let useLowPowerMode = "useLowPowerMode"
        static let pauseSpotlight = "pauseSpotlight"
        static let remotePushEnabled = "remotePushEnabled"
        static let answerFromPhone = "answerFromPhone"
        static let pushOnFinish = "pushOnFinish"
        static let pushOnAttention = "pushOnAttention"
        static let hookPort = "hookPort"
        static let hookToken = "hookToken"
        static let telegramChatId = "telegramChatId"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.keepDisplayAwake: false,
            Key.autoFollowClaude: false,
            Key.batteryGuardEnabled: true,
            Key.batteryGuardThreshold: 20,
            Key.notificationsEnabled: true,
            Key.showCountdownInMenuBar: true,
            Key.defaultDuration: 0,            // 0 == no limit
            Key.clamshellOverride: false,
            Key.watchedProcesses: ["claude"],
            Key.graceMinutes: 2,
            Key.aggressiveSaving: false,       // throttle only by default, no SIGSTOP
            Key.autoArmOnLidClose: true,
            Key.displayOffOnEngage: false,
            Key.showRuntimeInMenuBar: true,
            Key.useLowPowerMode: false,        // needs a password, so opt-in
            Key.pauseSpotlight: false,
            Key.remotePushEnabled: false,
            Key.answerFromPhone: true,
            Key.pushOnFinish: true,
            Key.pushOnAttention: true,
            Key.hookPort: 47821,
            Key.telegramChatId: "",
        ])
    }

    /// `true` = freeze apps (SIGSTOP), `false` = throttle only.
    static var aggressiveSaving: Bool {
        get { d.bool(forKey: Key.aggressiveSaving) }
        set { d.set(newValue, forKey: Key.aggressiveSaving) }
    }

    /// Automatically engage power saving when the display sleeps / the lid closes.
    static var autoArmOnLidClose: Bool {
        get { d.bool(forKey: Key.autoArmOnLidClose) }
        set { d.set(newValue, forKey: Key.autoArmOnLidClose) }
    }

    /// Turn the display off as soon as agent mode starts.
    static var displayOffOnEngage: Bool {
        get { d.bool(forKey: Key.displayOffOnEngage) }
        set { d.set(newValue, forKey: Key.displayOffOnEngage) }
    }

    /// Show the estimated remaining work time in the menu bar.
    static var showRuntimeInMenuBar: Bool {
        get { d.bool(forKey: Key.showRuntimeInMenuBar) }
        set { d.set(newValue, forKey: Key.showRuntimeInMenuBar) }
    }

    /// Turn on the system Low Power Mode together with agent mode.
    static var useLowPowerMode: Bool {
        get { d.bool(forKey: Key.useLowPowerMode) }
        set { d.set(newValue, forKey: Key.useLowPowerMode) }
    }

    /// Pause Spotlight indexing together with agent mode.
    static var pauseSpotlight: Bool {
        get { d.bool(forKey: Key.pauseSpotlight) }
        set { d.set(newValue, forKey: Key.pauseSpotlight) }
    }

    /// Push a message to the phone when the lid closes.
    static var remotePushEnabled: Bool {
        get { d.bool(forKey: Key.remotePushEnabled) }
        set { d.set(newValue, forKey: Key.remotePushEnabled) }
    }

    /// Answer questions and approvals from Telegram while the user is away.
    static var answerFromPhone: Bool {
        get { d.bool(forKey: Key.answerFromPhone) }
        set { d.set(newValue, forKey: Key.answerFromPhone) }
    }

    static var pushOnFinish: Bool {
        get { d.bool(forKey: Key.pushOnFinish) }
        set { d.set(newValue, forKey: Key.pushOnFinish) }
    }

    /// Notifications, questions while at the Mac, and failures.
    static var pushOnAttention: Bool {
        get { d.bool(forKey: Key.pushOnAttention) }
        set { d.set(newValue, forKey: Key.pushOnAttention) }
    }

    static var hookPort: Int {
        get { d.integer(forKey: Key.hookPort) }
        set { d.set(newValue, forKey: Key.hookPort) }
    }

    /// Random path segment so other local processes cannot post to the hook endpoint.
    static var hookToken: String {
        if let t = d.string(forKey: Key.hookToken), !t.isEmpty { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        d.set(t, forKey: Key.hookToken)
        return t
    }

    static var telegramChatId: String {
        get { d.string(forKey: Key.telegramChatId) ?? "" }
        set { d.set(newValue, forKey: Key.telegramChatId) }
    }

    /// Keep the display on as well.
    static var keepDisplayAwake: Bool {
        get { d.bool(forKey: Key.keepDisplayAwake) }
        set { d.set(newValue, forKey: Key.keepDisplayAwake) }
    }

    /// Keep the Mac awake automatically while Claude Code is running.
    static var autoFollowClaude: Bool {
        get { d.bool(forKey: Key.autoFollowClaude) }
        set { d.set(newValue, forKey: Key.autoFollowClaude) }
    }

    /// Release the hold when the battery drops below the threshold.
    static var batteryGuardEnabled: Bool {
        get { d.bool(forKey: Key.batteryGuardEnabled) }
        set { d.set(newValue, forKey: Key.batteryGuardEnabled) }
    }

    static var batteryGuardThreshold: Int {
        get { d.integer(forKey: Key.batteryGuardThreshold) }
        set { d.set(newValue, forKey: Key.batteryGuardThreshold) }
    }

    static var notificationsEnabled: Bool {
        get { d.bool(forKey: Key.notificationsEnabled) }
        set { d.set(newValue, forKey: Key.notificationsEnabled) }
    }

    static var showCountdownInMenuBar: Bool {
        get { d.bool(forKey: Key.showCountdownInMenuBar) }
        set { d.set(newValue, forKey: Key.showCountdownInMenuBar) }
    }

    /// Default duration in seconds (0 == no limit).
    static var defaultDuration: TimeInterval {
        get { d.double(forKey: Key.defaultDuration) }
        set { d.set(newValue, forKey: Key.defaultDuration) }
    }

    /// Whether the user wants the hard mode (`pmset disablesleep`).
    static var clamshellOverride: Bool {
        get { d.bool(forKey: Key.clamshellOverride) }
        set { d.set(newValue, forKey: Key.clamshellOverride) }
    }

    static var watchedProcesses: [String] {
        get { d.stringArray(forKey: Key.watchedProcesses) ?? ["claude"] }
        set { d.set(newValue, forKey: Key.watchedProcesses) }
    }

    /// How many minutes to hold after the Claude Code process disappears.
    static var graceMinutes: Int {
        get { d.integer(forKey: Key.graceMinutes) }
        set { d.set(newValue, forKey: Key.graceMinutes) }
    }
}

enum Format {

    /// 3661 -> "1h 1m", 90 -> "1m", 45 -> "45s"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes)m" }
        return "\(secs)s"
    }

    /// 3661 -> "1:01:01", 90 -> "1:30"
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Compact form for the menu bar: "1:04", "12m"
    static func compact(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d", total / 3600, (total % 3600) / 60)
        }
        return "\(max(1, total / 60))m"
    }
}

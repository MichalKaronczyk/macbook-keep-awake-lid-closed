import AppKit
import ServiceManagement

/// Carries a per-app policy choice through a menu item's `representedObject`.
final class PolicyChoice: NSObject {
    let bundleId: String
    let policy: AppPolicy?
    init(bundleId: String, policy: AppPolicy?) {
        self.bundleId = bundleId
        self.policy = policy
    }
}

/// Carries an app from the energy-hogs list.
final class HogChoice: NSObject {
    let pid: Int32
    let bundleId: String
    let name: String
    init(pid: Int32, bundleId: String, name: String) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Subsystems

    private let sleepManager = SleepManager()
    private let powerSaver = PowerSaver()
    private let systemTweaks = SystemTweaks()

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    // MARK: - Keep-awake state

    private var manualHold = false
    private var manualExpiry: Date?
    private var holdStartedAt: Date?
    private var autoHold = false
    private var autoGraceUntil: Date?
    private var batteryGuardTripped = false

    /// Whether power saving was armed automatically when the display slept, so that
    /// on wake we only lift what we put in place ourselves.
    private var powerSaveAutoArmed = false

    // MARK: - Telemetry and session

    private var lastClaudeCount = 0
    private var cachedPower = PowerMonitor.snapshot()
    private var cachedReading = EnergyMonitor.read()

    private var sessionStart: Date?
    private var sessionStartPercent: Int?

    private var tickTimer: Timer?
    private var watchTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    private var effectiveHold: Bool { (manualHold || autoHold) && !batteryGuardTripped }
    private var agentModeOn: Bool { manualHold || powerSaver.isEngaged }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        sleepManager.syncClamshellOverrideState()
        systemTweaks.syncState()
        Notifier.requestAuthorizationIfNeeded()

        // Safety net: resume anything left frozen by a previous instance that crashed.
        let recovered = powerSaver.recoverFromPreviousRun()
        if recovered > 0 {
            Notifier.post(title: "Apps restored",
                          body: "Resumed \(recovered) processes left over from the previous run.")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self

        installSignalHandlers()
        installWorkspaceObservers()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollEnvironment()
        }
        pollEnvironment()
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdownCleanly()
    }

    /// Single cleanup path — called from termination and from the signal handlers.
    private func shutdownCleanly() {
        powerSaver.releaseSynchronously()
        sleepManager.endHold()
        sleepManager.restoreSystemDefaultsIfNeeded()
        systemTweaks.restoreIfNeeded()
    }

    /// SIGTERM/SIGINT/SIGHUP via DispatchSource — unlike a classic `signal()` handler,
    /// this one runs on a queue, so it is allowed to do real work.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutdownCleanly()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - Lid reaction

    /// The display went dark — usually that means the lid just closed. This is the
    /// moment power saving pays off most: nobody is looking, the agent is working.
    @objc private func screensDidSleep() {
        guard Preferences.autoArmOnLidClose else { return }
        guard effectiveHold else { return }
        guard !powerSaver.isEngaged else { return }
        powerSaveAutoArmed = true
        startPowerSaving(announce: true)
    }

    /// Lid open — hand everything back to the user immediately.
    @objc private func screensDidWake() {
        guard powerSaveAutoArmed, powerSaver.isEngaged else { return }
        powerSaveAutoArmed = false
        stopPowerSaving(announce: true)
    }

    @objc private func systemDidWake() {
        pollEnvironment()
    }

    // MARK: - Loop

    private func tick() {
        if manualHold, let expiry = manualExpiry, Date() >= expiry {
            stopAgentMode(reason: "Time is up")
        }

        if let grace = autoGraceUntil, Date() >= grace {
            autoGraceUntil = nil
            autoHold = false
            if powerSaver.isEngaged, powerSaveAutoArmed {
                powerSaveAutoArmed = false
                stopPowerSaving(announce: false)
            }
            Notifier.post(title: "Claude Code finished",
                          body: "Sleep hold released automatically.")
        }

        applyState()
        updateButton()
    }

    private func pollEnvironment() {
        cachedPower = PowerMonitor.snapshot()
        cachedReading = EnergyMonitor.read()
        EnergyMonitor.record(percent: cachedPower.batteryPercent, watts: cachedReading.watts)
        lastClaudeCount = ClaudeWatcher.runningCount()

        if Preferences.autoFollowClaude {
            if lastClaudeCount > 0 {
                if !autoHold {
                    Notifier.post(title: "Claude Code started",
                                  body: "Keeping the Mac awake.")
                }
                autoHold = true
                autoGraceUntil = nil
            } else if autoHold, autoGraceUntil == nil {
                let grace = TimeInterval(max(0, Preferences.graceMinutes) * 60)
                if grace > 0 {
                    autoGraceUntil = Date().addingTimeInterval(grace)
                } else {
                    autoHold = false
                }
            }
        } else {
            autoHold = false
            autoGraceUntil = nil
        }

        evaluateBatteryGuard()
        applyState()
        updateButton()
    }

    private func evaluateBatteryGuard() {
        guard Preferences.batteryGuardEnabled else {
            batteryGuardTripped = false
            return
        }
        let threshold = Preferences.batteryGuardThreshold
        let low = !cachedPower.onACPower && (cachedPower.batteryPercent ?? 100) < threshold

        if low, !batteryGuardTripped, manualHold || autoHold {
            batteryGuardTripped = true
            // Hand the apps back too — nobody should find a frozen Slack after
            // waking up from a low battery.
            if powerSaver.isEngaged {
                stopPowerSaving(announce: false)
            }
            Notifier.post(title: "Low battery",
                          body: "Battery below \(threshold)% — releasing the hold and restoring apps.")
        } else if !low, batteryGuardTripped {
            batteryGuardTripped = false
        }
    }

    private func applyState() {
        if effectiveHold {
            sleepManager.beginHold(keepDisplayAwake: Preferences.keepDisplayAwake)
        } else {
            sleepManager.endHold()
        }
    }

    // MARK: - Agent mode (master switch)

    @objc private func toggleAgentMode() {
        if agentModeOn {
            stopAgentMode(reason: nil)
        } else {
            startAgentMode()
        }
    }

    private func startAgentMode() {
        batteryGuardTripped = false
        powerSaveAutoArmed = false      // manual start: waking up must not lift power saving
        manualHold = true
        holdStartedAt = Date()
        let duration = Preferences.defaultDuration
        manualExpiry = duration > 0 ? Date().addingTimeInterval(duration) : nil

        sessionStart = Date()
        sessionStartPercent = cachedPower.batteryPercent

        evaluateBatteryGuard()
        applyState()
        startPowerSaving(announce: false)

        let timing = manualExpiry == nil ? "indefinitely" : "for \(Format.duration(duration))"
        Notifier.post(title: "Agent mode on",
                      body: "The Mac will stay awake \(timing). Power saving is active.")
        refreshUI()
    }

    private func stopAgentMode(reason: String?) {
        manualHold = false
        manualExpiry = nil
        holdStartedAt = nil
        powerSaveAutoArmed = false
        stopPowerSaving(announce: false)
        applyState()

        if let reason {
            Notifier.post(title: reason, body: sessionReportLine())
        }
        sessionStart = nil
        sessionStartPercent = nil
        refreshUI()
    }

    // MARK: - Power saving

    private func startPowerSaving(announce: Bool) {
        guard !powerSaver.isEngaged else { return }
        EnergyMonitor.captureBaseline()

        powerSaver.engage(aggressive: Preferences.aggressiveSaving) { [weak self] result in
            guard let self else { return }
            if announce, !result.isEmpty {
                Notifier.post(title: "Power saving",
                              body: "Restricted: \(result.summary).")
            }
            self.refreshUI()
        }

        if Preferences.useLowPowerMode || Preferences.pauseSpotlight {
            systemTweaks.applyPrivileged(
                lowPowerMode: Preferences.useLowPowerMode ? true : nil,
                pauseSpotlight: Preferences.pauseSpotlight ? true : nil)
        }
        if Preferences.displayOffOnEngage {
            SystemTweaks.sleepDisplayNow()
        }
    }

    private func stopPowerSaving(announce: Bool) {
        let wasEngaged = powerSaver.isEngaged
        powerSaver.release { [weak self] in
            self?.refreshUI()
        }
        EnergyMonitor.clearBaseline()
        systemTweaks.restoreIfNeeded()
        if announce, wasEngaged {
            Notifier.post(title: "Apps restored",
                          body: "Everything is back at full speed.")
        }
    }

    @objc private func togglePowerSaving() {
        if powerSaver.isEngaged {
            powerSaveAutoArmed = false
            stopPowerSaving(announce: true)
        } else {
            startPowerSaving(announce: true)
        }
        refreshUI()
    }

    @objc private func toggleAggressive() {
        Preferences.aggressiveSaving.toggle()
        // Reload so the new policy takes effect right away.
        if powerSaver.isEngaged {
            powerSaver.release { [weak self] in
                guard let self else { return }
                self.powerSaver.engage(aggressive: Preferences.aggressiveSaving) { result in
                    Notifier.post(title: Preferences.aggressiveSaving
                                    ? "Aggressive mode" : "Gentle mode",
                                  body: "Restricted: \(result.summary).")
                    self.refreshUI()
                }
            }
        }
        refreshUI()
    }

    // MARK: - Menu bar

    private func updateButton() {
        guard let button = statusItem.button else { return }

        let symbol: String
        if batteryGuardTripped {
            symbol = "exclamationmark.triangle"
        } else if powerSaver.isEngaged, effectiveHold {
            symbol = "leaf.fill"
        } else if effectiveHold {
            symbol = "cup.and.saucer.fill"
        } else if Preferences.autoFollowClaude {
            symbol = "cup.and.saucer"
        } else {
            symbol = "moon.zzz"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Not Close")
        image?.isTemplate = true
        button.image = image

        var bits: [String] = []
        if Preferences.showCountdownInMenuBar, effectiveHold, let expiry = manualExpiry {
            bits.append(Format.compact(expiry.timeIntervalSinceNow))
        }
        if Preferences.showRuntimeInMenuBar, let left = projectedRuntime() {
            bits.append("~" + Format.compact(left))
        }
        button.title = bits.isEmpty ? "" : " " + bits.joined(separator: " · ")
        button.toolTip = statusLine()
    }

    /// Estimated time left on battery: our own drain-rate forecast first, the macOS
    /// estimate as a fallback while there is not enough history yet.
    private func projectedRuntime() -> TimeInterval? {
        guard !cachedPower.onACPower else { return nil }
        if let projected = EnergyMonitor.projectedRuntime(
            currentPercent: cachedPower.batteryPercent,
            floorPercent: Preferences.batteryGuardEnabled ? Preferences.batteryGuardThreshold : 0),
           projected > 0 {
            return projected
        }
        if let minutes = cachedPower.minutesRemaining, minutes > 0 {
            return TimeInterval(minutes * 60)
        }
        return nil
    }

    private func statusLine() -> String {
        if batteryGuardTripped { return "Paused — low battery" }

        var base: String
        if !effectiveHold {
            return Preferences.autoFollowClaude
                ? "Standing by — waiting for Claude Code"
                : "Off — the Mac will sleep when the lid closes"
        } else if autoHold, !manualHold {
            if let grace = autoGraceUntil {
                base = "Active (grace period \(Format.clock(grace.timeIntervalSinceNow)))"
            } else {
                base = "Active — Claude Code is working (\(lastClaudeCount))"
            }
        } else {
            base = "Agent mode"
        }

        // Watts alone say little, so the headline is the thing you actually care
        // about: how much working time is left. The draw itself lives in the
        // Power saving submenu.
        if let left = projectedRuntime() {
            base += " · ~\(Format.duration(left)) of work left"
        } else if cachedPower.onACPower {
            base += " · on AC power"
        }
        return base
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            toggleAgentMode()
            return
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        cachedPower = PowerMonitor.snapshot()
        cachedReading = EnergyMonitor.read()
        lastClaudeCount = ClaudeWatcher.runningCount()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // --- Header
        menu.addItem(bold(statusLine()))
        if manualHold, let expiry = manualExpiry {
            menu.addItem(info("Timer: \(Format.clock(expiry.timeIntervalSinceNow)) left"))
        } else if effectiveHold, let started = holdStartedAt {
            menu.addItem(info("Running for \(Format.duration(Date().timeIntervalSince(started)))"))
        }

        menu.addItem(.separator())

        // --- Master
        let master = item("Agent mode", #selector(toggleAgentMode), symbol: "leaf.fill")
        master.state = agentModeOn ? .on : .off
        master.keyEquivalent = "k"
        menu.addItem(master)

        if manualHold, manualExpiry != nil {
            menu.addItem(item("Extend by 30 minutes", #selector(extendThirty), symbol: "plus.circle"))
        }

        menu.addItem(.separator())

        // --- Submenus
        let saving = NSMenuItem(title: "Power saving", action: nil, keyEquivalent: "")
        saving.image = symbolImage("bolt.badge.clock")
        saving.submenu = savingSubmenu()
        menu.addItem(saving)

        let awake = NSMenuItem(title: "Keep awake", action: nil, keyEquivalent: "")
        awake.image = symbolImage("macbook.and.visionpro")
        awake.submenu = awakeSubmenu()
        menu.addItem(awake)

        let hogs = NSMenuItem(title: "Energy hogs", action: nil, keyEquivalent: "")
        hogs.image = symbolImage("flame")
        hogs.submenu = hogsSubmenu()
        menu.addItem(hogs)

        menu.addItem(.separator())

        // --- Info
        menu.addItem(info(cachedPower.summary))
        menu.addItem(info(lastClaudeCount > 0
                          ? "Claude Code: \(lastClaudeCount) \(lastClaudeCount == 1 ? "process" : "processes")"
                          : "Claude Code: not running"))
        if powerSaver.isEngaged {
            menu.addItem(info("Restricted: \(powerSaver.lastResult.summary)"))
        }
        if !cachedPower.onACPower, effectiveHold, !sleepManager.clamshellOverrideActive {
            menu.addItem(warning("On battery the lid will still sleep the Mac — enable forced mode"))
        }

        menu.addItem(.separator())

        menu.addItem(item("Session report", #selector(showSessionReport), symbol: "chart.bar"))

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settings.submenu = settingsSubmenu()
        menu.addItem(settings)

        menu.addItem(item("About", #selector(showAbout), symbol: "info.circle"))

        let quit = item("Quit", #selector(quit), symbol: "power")
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func savingSubmenu() -> NSMenu {
        let sub = NSMenu()

        // The actual power draw lives here rather than in the headline — the number
        // only means something next to the before/after comparison.
        if let watts = EnergyMonitor.smoothedWatts() {
            var line = "Power draw: \(EnergyMonitor.formatWatts(watts))"
            if let saved = EnergyMonitor.savedWatts() {
                line += String(format: " (−%.1f W)", saved)
            }
            sub.addItem(info(line))
            if let baseline = EnergyMonitor.baselineWatts {
                sub.addItem(info("Before power saving: \(EnergyMonitor.formatWatts(baseline))"))
            }
            sub.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Power saving on",
                                action: #selector(togglePowerSaving), keyEquivalent: "")
        toggle.target = self
        toggle.state = powerSaver.isEngaged ? .on : .off
        sub.addItem(toggle)

        let aggressive = NSMenuItem(title: "Aggressive mode (freeze apps)",
                                    action: #selector(toggleAggressive), keyEquivalent: "")
        aggressive.target = self
        aggressive.state = Preferences.aggressiveSaving ? .on : .off
        sub.addItem(aggressive)
        sub.addItem(info(Preferences.aggressiveSaving
                         ? "SIGSTOP: app completely frozen"
                         : "taskpolicy: efficiency cores, ~2x slower"))

        sub.addItem(.separator())

        let manage = NSMenuItem(title: "Manage apps", action: nil, keyEquivalent: "")
        manage.submenu = manageAppsSubmenu()
        sub.addItem(manage)

        sub.addItem(.separator())

        let autoArm = NSMenuItem(title: "Arm when the lid closes",
                                 action: #selector(toggleAutoArm), keyEquivalent: "")
        autoArm.target = self
        autoArm.state = Preferences.autoArmOnLidClose ? .on : .off
        sub.addItem(autoArm)

        let displayOff = NSMenuItem(title: "Turn the display off on start",
                                    action: #selector(toggleDisplayOff), keyEquivalent: "")
        displayOff.target = self
        displayOff.state = Preferences.displayOffOnEngage ? .on : .off
        sub.addItem(displayOff)

        sub.addItem(item("Turn the display off now", #selector(sleepDisplayNow), symbol: "display.slash"))

        sub.addItem(.separator())

        let lpm = NSMenuItem(title: "Low Power Mode (admin password)",
                             action: #selector(toggleLowPowerMode), keyEquivalent: "")
        lpm.target = self
        lpm.state = Preferences.useLowPowerMode ? .on : .off
        sub.addItem(lpm)

        let spotlight = NSMenuItem(title: "Pause Spotlight (admin password)",
                                   action: #selector(toggleSpotlight), keyEquivalent: "")
        spotlight.target = self
        spotlight.state = Preferences.pauseSpotlight ? .on : .off
        sub.addItem(spotlight)

        if systemTweaks.lowPowerModeActive || systemTweaks.spotlightPaused {
            var active: [String] = []
            if systemTweaks.lowPowerModeActive { active.append("Low Power Mode") }
            if systemTweaks.spotlightPaused { active.append("Spotlight paused") }
            sub.addItem(info("Active system-wide: " + active.joined(separator: ", ")))
        }

        return sub
    }

    private func manageAppsSubmenu() -> NSMenu {
        let sub = NSMenu()
        let aggressive = Preferences.aggressiveSaving
        let apps = AppCatalog.candidates()
            .sorted { AppCatalog.displayName($0).localizedCaseInsensitiveCompare(
                        AppCatalog.displayName($1)) == .orderedAscending }

        if apps.isEmpty {
            sub.addItem(info("No running apps"))
            return sub
        }

        for app in apps {
            guard let bundleId = app.bundleIdentifier else { continue }
            let current = AppCatalog.policy(for: bundleId, aggressive: aggressive)
            let parent = NSMenuItem(title: AppCatalog.displayName(app), action: nil, keyEquivalent: "")
            parent.image = app.icon.map { icon in
                let copy = icon.copy() as! NSImage
                copy.size = NSSize(width: 16, height: 16)
                return copy
            }

            let policyMenu = NSMenu()
            for policy in AppPolicy.allCases {
                let mi = NSMenuItem(title: policy.label, action: #selector(setAppPolicy(_:)),
                                    keyEquivalent: "")
                mi.target = self
                mi.image = symbolImage(policy.symbol)
                mi.state = current == policy ? .on : .off
                mi.representedObject = PolicyChoice(bundleId: bundleId, policy: policy)
                policyMenu.addItem(mi)
            }
            policyMenu.addItem(.separator())
            let reset = NSMenuItem(title: "Default (\(AppCatalog.policy(for: bundleId, aggressive: aggressive).shortLabel))",
                                   action: #selector(setAppPolicy(_:)), keyEquivalent: "")
            reset.target = self
            reset.representedObject = PolicyChoice(bundleId: bundleId, policy: nil)
            reset.state = AppPolicyStore.policy(for: bundleId) == nil ? .on : .off
            policyMenu.addItem(reset)

            parent.submenu = policyMenu
            sub.addItem(parent)
        }

        sub.addItem(.separator())
        sub.addItem(item("Reset all to default", #selector(resetPolicies),
                         symbol: "arrow.counterclockwise"))
        return sub
    }

    private func hogsSubmenu() -> NSMenu {
        let sub = NSMenu()
        let loads = HogList.topApps(limit: 7, aggressive: Preferences.aggressiveSaving)

        if loads.isEmpty {
            sub.addItem(info("No data"))
            return sub
        }

        sub.addItem(info("CPU including helper processes"))
        for load in loads {
            let suffix = load.processCount > 1 ? " · \(load.processCount) proc." : ""
            let title = String(format: "%@ — %.1f%%%@", load.name, load.cpu, suffix)
            let mi = NSMenuItem(title: title, action: #selector(suspendHog(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = HogChoice(pid: load.app.processIdentifier,
                                             bundleId: load.bundleId,
                                             name: load.name)
            if load.policy == .protected {
                mi.image = symbolImage("shield.lefthalf.filled")
                mi.isEnabled = false
                mi.toolTip = "Protected — agent tool"
            } else if powerSaver.isManaged(pid: load.app.processIdentifier) {
                mi.image = symbolImage("snowflake")
                mi.isEnabled = false
                mi.toolTip = "Already restricted"
            } else {
                mi.image = symbolImage("snowflake")
                mi.toolTip = "Click to freeze"
            }
            sub.addItem(mi)
        }
        return sub
    }

    private func awakeSubmenu() -> NSMenu {
        let sub = NSMenu()

        let hold = NSMenuItem(title: "Don't sleep with the lid closed",
                              action: #selector(toggleKeepAwake), keyEquivalent: "")
        hold.target = self
        hold.state = manualHold ? .on : .off
        sub.addItem(hold)

        let duration = NSMenuItem(title: "Duration", action: nil, keyEquivalent: "")
        duration.submenu = durationSubmenu()
        sub.addItem(duration)

        sub.addItem(.separator())

        let display = NSMenuItem(title: "Keep the display on",
                                 action: #selector(toggleDisplay), keyEquivalent: "")
        display.target = self
        display.state = Preferences.keepDisplayAwake ? .on : .off
        sub.addItem(display)

        let auto = NSMenuItem(title: "Auto: while Claude Code is running",
                              action: #selector(toggleAutoFollow), keyEquivalent: "")
        auto.target = self
        auto.state = Preferences.autoFollowClaude ? .on : .off
        sub.addItem(auto)

        let hard = NSMenuItem(title: "Force on battery too (admin password)",
                              action: #selector(toggleClamshellOverride), keyEquivalent: "")
        hard.target = self
        hard.state = sleepManager.clamshellOverrideActive ? .on : .off
        sub.addItem(hard)

        return sub
    }

    private func durationSubmenu() -> NSMenu {
        let sub = NSMenu()
        let presets: [(String, TimeInterval)] = [
            ("No limit", 0), ("15 minutes", 900), ("30 minutes", 1800),
            ("1 hour", 3600), ("2 hours", 7200),
            ("4 hours", 14400), ("8 hours", 28800),
        ]
        let current = Preferences.defaultDuration
        for (label, seconds) in presets {
            let mi = NSMenuItem(title: label, action: #selector(selectDuration(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = Int(seconds)
            mi.state = (current == seconds) ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: #selector(customDuration), keyEquivalent: "")
        custom.target = self
        custom.state = presets.contains(where: { $0.1 == current }) ? .off : .on
        sub.addItem(custom)
        return sub
    }

    private func settingsSubmenu() -> NSMenu {
        let sub = NSMenu()

        let guardItem = NSMenuItem(title: "Release the hold on low battery",
                                   action: #selector(toggleBatteryGuard), keyEquivalent: "")
        guardItem.target = self
        guardItem.state = Preferences.batteryGuardEnabled ? .on : .off
        sub.addItem(guardItem)

        let thresholdItem = NSMenuItem(title: "Battery threshold", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()
        for value in [10, 15, 20, 30, 40, 50] {
            let mi = NSMenuItem(title: "\(value)%", action: #selector(selectThreshold(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = value
            mi.state = Preferences.batteryGuardThreshold == value ? .on : .off
            thresholdMenu.addItem(mi)
        }
        thresholdItem.submenu = thresholdMenu
        sub.addItem(thresholdItem)

        sub.addItem(.separator())

        let graceItem = NSMenuItem(title: "Grace period after it finishes", action: nil, keyEquivalent: "")
        let graceMenu = NSMenu()
        for value in [0, 1, 2, 5, 10, 30] {
            let mi = NSMenuItem(title: value == 0 ? "immediately" : "\(value) min",
                                action: #selector(selectGrace(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = value
            mi.state = Preferences.graceMinutes == value ? .on : .off
            graceMenu.addItem(mi)
        }
        graceItem.submenu = graceMenu
        sub.addItem(graceItem)

        sub.addItem(item("Watched processes…", #selector(editProcesses)))

        sub.addItem(.separator())

        let notif = NSMenuItem(title: "Notifications", action: #selector(toggleNotifications), keyEquivalent: "")
        notif.target = self
        notif.state = Preferences.notificationsEnabled ? .on : .off
        sub.addItem(notif)

        let countdown = NSMenuItem(title: "Countdown in the menu bar",
                                   action: #selector(toggleCountdown), keyEquivalent: "")
        countdown.target = self
        countdown.state = Preferences.showCountdownInMenuBar ? .on : .off
        sub.addItem(countdown)

        let runtimeItem = NSMenuItem(title: "Time left in the menu bar",
                                     action: #selector(toggleRuntime), keyEquivalent: "")
        runtimeItem.target = self
        runtimeItem.state = Preferences.showRuntimeInMenuBar ? .on : .off
        sub.addItem(runtimeItem)

        sub.addItem(.separator())

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = isLaunchAtLoginEnabled() ? .on : .off
        sub.addItem(login)

        return sub
    }

    // MARK: - Menu helpers

    private func symbolImage(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        image.isTemplate = true
        return image
    }

    private func item(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        if let symbol { mi.image = symbolImage(symbol) }
        return mi
    }

    private func bold(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        mi.isEnabled = false
        return mi
    }

    private func info(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                       .foregroundColor: NSColor.secondaryLabelColor])
        mi.isEnabled = false
        return mi
    }

    private func warning(_ text: String) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.attributedTitle = NSAttributedString(
            string: "⚠︎ " + text, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                               .foregroundColor: NSColor.systemOrange])
        mi.isEnabled = false
        return mi
    }

    private func refreshUI() {
        applyState()
        updateButton()
    }

    // MARK: - Actions: keep awake

    @objc private func toggleKeepAwake() {
        if manualHold {
            manualHold = false
            manualExpiry = nil
            holdStartedAt = nil
        } else {
            batteryGuardTripped = false
            manualHold = true
            holdStartedAt = Date()
            let duration = Preferences.defaultDuration
            manualExpiry = duration > 0 ? Date().addingTimeInterval(duration) : nil
            evaluateBatteryGuard()
        }
        refreshUI()
    }

    @objc private func extendThirty() {
        guard let expiry = manualExpiry else { return }
        manualExpiry = max(expiry, Date()).addingTimeInterval(1800)
        refreshUI()
    }

    @objc private func toggleDisplay() {
        Preferences.keepDisplayAwake.toggle()
        sleepManager.setDisplayHold(effectiveHold && Preferences.keepDisplayAwake)
        refreshUI()
    }

    @objc private func toggleAutoFollow() {
        Preferences.autoFollowClaude.toggle()
        if !Preferences.autoFollowClaude {
            autoHold = false
            autoGraceUntil = nil
        }
        pollEnvironment()
    }

    @objc private func toggleClamshellOverride() {
        let target = !sleepManager.clamshellOverrideActive
        if sleepManager.setClamshellOverride(target) {
            Preferences.clamshellOverride = target
            Notifier.post(title: target ? "Forced mode on" : "Forced mode off",
                          body: target
                            ? "Closing the lid will not sleep the Mac, even on battery."
                            : "System default behaviour restored.")
        } else {
            showAlert("Could not change the system setting",
                      "The pmset command requires administrator privileges. "
                      + "If you cancelled the password prompt, try again.")
        }
        refreshUI()
    }

    @objc private func selectDuration(_ sender: NSMenuItem) {
        Preferences.defaultDuration = TimeInterval(sender.tag)
        if manualHold {
            manualExpiry = sender.tag > 0 ? Date().addingTimeInterval(TimeInterval(sender.tag)) : nil
        }
        refreshUI()
    }

    @objc private func customDuration() {
        guard let minutes = promptForNumber(
            title: "Custom duration",
            message: "Enter a number of minutes (0 = no limit).",
            initial: String(Int(Preferences.defaultDuration / 60))) else { return }
        Preferences.defaultDuration = TimeInterval(minutes * 60)
        if manualHold {
            manualExpiry = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        }
        refreshUI()
    }

    // MARK: - Actions: power saving

    @objc private func toggleAutoArm() {
        Preferences.autoArmOnLidClose.toggle()
    }

    @objc private func toggleDisplayOff() {
        Preferences.displayOffOnEngage.toggle()
    }

    @objc private func sleepDisplayNow() {
        SystemTweaks.sleepDisplayNow()
    }

    @objc private func toggleLowPowerMode() {
        let target = !Preferences.useLowPowerMode
        if systemTweaks.applyPrivileged(lowPowerMode: target, pauseSpotlight: nil) {
            Preferences.useLowPowerMode = target
        } else {
            showAlert("Could not change Low Power Mode",
                      "The pmset command requires administrator privileges.")
        }
        systemTweaks.syncState()
        refreshUI()
    }

    @objc private func toggleSpotlight() {
        let target = !Preferences.pauseSpotlight
        if systemTweaks.applyPrivileged(lowPowerMode: nil, pauseSpotlight: target) {
            Preferences.pauseSpotlight = target
        } else {
            showAlert("Could not change Spotlight indexing",
                      "The mdutil command requires administrator privileges.")
        }
        systemTweaks.syncState()
        refreshUI()
    }

    @objc private func setAppPolicy(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PolicyChoice else { return }
        AppPolicyStore.set(choice.policy, for: choice.bundleId)
    }

    @objc private func resetPolicies() {
        AppPolicyStore.reset()
    }

    @objc private func suspendHog(_ sender: NSMenuItem) {
        guard let hog = sender.representedObject as? HogChoice else { return }
        if powerSaver.suspendTree(rootPID: hog.pid, bundleId: hog.bundleId, name: hog.name) {
            Notifier.post(title: "Froze \(hog.name)",
                          body: "It will resume when power saving is turned off.")
        } else {
            showAlert("Could not freeze \(hog.name)",
                      "The system refused to stop those processes.")
        }
        refreshUI()
    }

    // MARK: - Actions: settings

    @objc private func toggleBatteryGuard() {
        Preferences.batteryGuardEnabled.toggle()
        if !Preferences.batteryGuardEnabled { batteryGuardTripped = false }
        pollEnvironment()
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        Preferences.batteryGuardThreshold = sender.tag
        pollEnvironment()
    }

    @objc private func selectGrace(_ sender: NSMenuItem) {
        Preferences.graceMinutes = sender.tag
    }

    @objc private func editProcesses() {
        let alert = NSAlert()
        alert.messageText = "Watched processes"
        alert.informativeText = "Comma-separated process names. Auto mode keeps the Mac "
            + "awake for as long as any of them is running."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = Preferences.watchedProcesses.joined(separator: ", ")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let names = field.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Preferences.watchedProcesses = names.isEmpty ? ["claude"] : names
        pollEnvironment()
    }

    @objc private func toggleNotifications() {
        Preferences.notificationsEnabled.toggle()
        if Preferences.notificationsEnabled { Notifier.requestAuthorizationIfNeeded() }
    }

    @objc private func toggleCountdown() {
        Preferences.showCountdownInMenuBar.toggle()
        updateButton()
    }

    @objc private func toggleRuntime() {
        Preferences.showRuntimeInMenuBar.toggle()
        updateButton()
    }

    // MARK: - Launch at login

    private func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled() {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Could not change launch at login",
                      "\(error.localizedDescription)\n\nThe app has to live in /Applications "
                      + "for macOS to allow registering it.")
        }
    }

    // MARK: - Report

    private func sessionReportLine() -> String {
        guard let start = sessionStart else { return "No active session." }
        let elapsed = Date().timeIntervalSince(start)
        var text = "Time: \(Format.duration(elapsed))"
        if let from = sessionStartPercent, let now = cachedPower.batteryPercent {
            text += " · battery \(from)% → \(now)%"
        }
        return text
    }

    @objc private func showSessionReport() {
        var lines: [String] = []

        if let start = sessionStart {
            lines.append("Duration: \(Format.duration(Date().timeIntervalSince(start)))")
            if let from = sessionStartPercent, let now = cachedPower.batteryPercent {
                lines.append("Battery: \(from)% → \(now)% (used \(max(0, from - now)) pp)")
            }
        } else {
            lines.append("Agent mode is not active.")
        }

        if let watts = EnergyMonitor.smoothedWatts() {
            lines.append("Draw now: \(EnergyMonitor.formatWatts(watts))")
        }
        if let baseline = EnergyMonitor.baselineWatts {
            lines.append("Draw before power saving: \(EnergyMonitor.formatWatts(baseline))")
        }
        if let saved = EnergyMonitor.savedWatts() {
            lines.append(String(format: "Saved: %.1f W", saved))
        }
        if let rate = EnergyMonitor.drainPercentPerHour() {
            lines.append(String(format: "Drain rate: %.1f %%/h", rate))
        }
        if let projected = EnergyMonitor.projectedRuntime(
            currentPercent: cachedPower.batteryPercent,
            floorPercent: Preferences.batteryGuardEnabled ? Preferences.batteryGuardThreshold : 0) {
            lines.append("Runtime left: ~\(Format.duration(projected))")
        }

        lines.append("")
        if powerSaver.isEngaged {
            lines.append("Restricted apps: \(powerSaver.lastResult.summary)")
            let names = powerSaver.managedRecords.map(\.name).sorted()
            if !names.isEmpty {
                lines.append(names.joined(separator: ", "))
            }
        } else {
            lines.append("Power saving is off.")
        }

        if let temp = cachedReading.temperature {
            lines.append(String(format: "Battery temperature: %.1f °C", temp))
        }
        if let cycles = cachedReading.cycleCount, let health = cachedReading.health {
            lines.append("Cycles: \(cycles) · health: \(health)%")
        }

        showAlert("Session report", lines.joined(separator: "\n"))
    }

    // MARK: - Dialogs

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func promptForNumber(title: String, message: String, initial: String) -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return max(0, Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    @objc private func showAbout() {
        showAlert("Claude Not Close", """
        Keeps your MacBook awake with the lid closed while cutting power to \
        everything the agent doesn't need.

        • ⌥ + click the icon — instant agent mode
        • Gentle mode pushes apps onto the efficiency cores (taskpolicy)
        • Aggressive mode freezes them outright (SIGSTOP)
        • Terminals, Cursor, VS Code, Xcode, Simulator and browsers are protected
        • Throttling covers Electron helper processes too
        • On battery macOS sleeps the Mac when the lid closes — the workaround is
          under "Keep awake → Force on battery too"

        Everything is restored when the mode is turned off and when the app quits.
        If the app ever crashes, it resumes whatever was left frozen on next launch.
        """)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

# How it works

The long version of the [README](../README.md).

## The menu

Clicking the icon pops the menu directly underneath it.

```
🍃 Agent mode · ~5h 10m of work left
   Timer: 2:14:03 left
   ─────────────────────────────
 ✓ Agent mode                               ⌘K
   Extend by 30 minutes
   ─────────────────────────────
   Power saving                              ▸
   Keep awake                                ▸
   Energy hogs                               ▸
   ─────────────────────────────
   battery · 53% · ~5h 20m
   Claude Code: 2 processes
   Restricted: 9 frozen (20 processes)
   ─────────────────────────────
   Session report
   Settings                                  ▸
   About
   Quit                                      ⌘Q
```

The icon reflects state: 🌙 off · ☕ outline = standing by in auto mode ·
☕ filled = keeping awake · 🍃 = agent mode with power saving · ⚠️ = battery guard.

## Throttling

| Mode | Mechanism | Effect |
|---|---|---|
| **Gentle** (default) | `taskpolicy -b` → darwinbg | The app lands on the efficiency cores and gets I/O throttling. Measured: a CPU-bound task slows ~2×. It keeps running, just slower and cheaper. |
| **Aggressive** | `SIGSTOP` | The app is frozen completely, zero CPU. `SIGCONT` resumes it when the mode is turned off. |

Both are fully reversible without root.

> `renice` was deliberately rejected: an unprivileged user can only lower a priority,
> never raise it back — restoring would be impossible.

`setpriority(PRIO_DARWIN_PROCESS, …)` looks like a cheaper option than spawning
`taskpolicy`, but on other processes it returns success and does nothing. Verified —
hence the subprocess.

### Helper processes

This is the part that's easy to miss: Slack, Telegram, Cursor, VS Code and Discord are
Electron, and all of their CPU sits in helper processes that are **not** visible as
`NSRunningApplication`. Throttling the main process alone would achieve nothing.

The app builds a process tree (`ps -axo pid=,ppid=`) and covers the whole subtree.
Measured on a real Slack: 1 main process + 5 helpers = 6 frozen.

Freezing goes leaves-to-root (otherwise the parent respawns a stopped child); resuming
goes the other way.

### Protected by default (full speed)

Terminals (Terminal, iTerm2, Warp, kitty, Alacritty, WezTerm, Ghostty) ·
editors and IDEs (Cursor, VS Code, Zed, Sublime, Windsurf, the whole JetBrains family) ·
Apple dev tooling (Xcode, Simulator, CoreSimulator) · Claude Desktop ·
browsers (Chrome, Brave) · Docker, OrbStack

Override any app under **Power saving → Manage apps**:
*Protected / Throttle / Freeze / Quit*.

### Never touched

Finder, Dock, Control Center, SystemUIServer, loginwindow, SecurityAgent, Passwords and
the app itself. On top of that, an `activationPolicy == .regular` filter screens out
every daemon and system process without a Dock icon — that's the main safety net.

## Everything else

| Feature | Detail |
|---|---|
| **Live power draw** | Real watts from the battery controller (`AppleSmartBattery`: `Amperage` × `Voltage`), not a guess. Shown under **Power saving** — watts on their own say little, so the headline carries the time estimate instead. |
| **Savings counter** | Remembers the draw from before power saving and shows the delta: `4.2 W (−3.1 W)`. |
| **Runtime forecast** | Drain rate (%/h) from sample history → "~5h 10m of work left" down to your battery floor, shown in the headline and the menu bar. Falls back to the macOS estimate until there is enough history. |
| **Energy hogs** | Top 7 apps by CPU, **helpers included**. One click freezes one. |
| **Auto on lid close** | `screensDidSleep` → engages power saving; `screensDidWake` → restores immediately. |
| **Auto with Claude Code** | Holds the Mac awake while a `claude` process is alive, plus a configurable grace period (2 min by default) for gaps between prompts. |
| **Battery guard** | Below the threshold (20% by default) it drops the hold **and restores the apps** — you won't come back to a frozen Slack. |
| **Display off now** | `pmset displaysleepnow`. With the lid open the panel is usually 2–6 W, the biggest single win. |
| **Low Power Mode** | System `pmset lowpowermode` (admin password). Note: it also lowers CPU clocks, so builds get slower. |
| **Pause Spotlight** | `mdutil -a -i off` (admin password) — no more background indexing. |
| **Duration** | No limit / 15 min / 30 min / 1 h / 2 h / 4 h / 8 h / custom, with a menu bar countdown. |
| **Session report** | Duration, battery used, draw now vs. before, watts saved, drain rate, list of restricted apps, battery temperature and health. |
| **Notifications** | Start/stop, timer expiry, Claude Code start/stop, low battery, crash recovery. |
| **⌥ + click** | Instant agent mode without opening the menu. |

## Crash safety

A frozen process nobody resumes is a hung app for the rest of the session. So:

- state (PIDs + policy) is written to disk on **every** change
  (`~/Library/Application Support/ClaudeNotClose/throttled.json`),
- at launch the app resumes anything left over from a previous instance,
- restore is called from `applicationWillTerminate` **and** from the SIGTERM/SIGINT/SIGHUP
  handlers (via `DispatchSource`, so the handler is allowed to do real work),
- `SIGSTOP` is opt-in — the default gentle mode only uses reversible `taskpolicy`.

The recovery path was tested: 20 processes frozen, a fresh `PowerSaver` instance read
the state file and restored all of them.

## The assertions

| Assertion | What it buys |
|---|---|
| `PreventUserIdleSystemSleep` | Blocks idle sleep. |
| `NetworkClientActive` | Apple documents this one as providing "CPU, disk, and network connectivity" — it is what keeps a streaming API call from being torn down when the display sleeps. On AC it holds the system in dark or full wake; on battery it only prevents *idle* sleep. |
| `PreventSystemSleep` | What `caffeinate -s` takes. `IOPMLib.h` marks it **deprecated since 10.9** and "not supported in any OS X releases", so it is a belt-and-braces extra here, never the thing to rely on. |
| `PreventUserIdleDisplaySleep` | Optional: keeps the display on too. |

Apple is explicit that assertions are suggestions — the system may sleep anyway "under
battery, thermal, or user circumstances". Closing the lid on battery is exactly such a
circumstance.

## The lid-and-power limitation

This is macOS, not the app:

- **On AC power** — the assertions are enough. Close the lid, the Mac keeps working.
- **On battery** — macOS sleeps the Mac on lid close regardless of what is asserted.
  The network goes down with it. The only workaround requires root and sits under
  **Keep awake → Force on battery too** (`pmset -a disablesleep 1`).

Because a passive warning is easy to walk away from, the app also:

- asks outright when you start agent mode on battery without forced mode,
- turns the orange menu warning into a one-click fix,
- notices (via `NSWorkspace.willSleepNotification`) when the Mac slept while the hold
  was active, and tells you on wake why your connection dropped.

Forced mode is reverted when the toggle is turned off and when the app quits.
Emergency reset:

```bash
sudo pmset -a disablesleep 0
```

## Troubleshooting: the agent's connection dropped

Symptom: the agent fails with something like `API Error: Connection closed
mid-response` shortly after the lid was closed.

Check whether the Mac actually slept:

```bash
pmset -g log | grep -E "Entering Sleep state|Wake from" | tail -10
```

A line such as

```
Entering Sleep state due to 'Clamshell Sleep' ... Using Batt (Charge:26%)
```

means the machine slept, which takes Wi-Fi and every TCP connection with it. Confirm
forced mode is what's missing — `pmset -g | grep -i sleepdisabled` prints nothing when
it is off — then enable **Keep awake → Force on battery too**, or stay on AC power.

Related settings worth knowing about (`pmset -g`): `tcpkeepalive 0` tears down TCP
connections during sleep, and `standby`/`hibernatemode` decide how deep that sleep
goes. None of them keep a streaming HTTPS response alive — only not sleeping does.

## Verifying it works

```bash
pmset -g assertions | grep ClaudeNotClose     # the keep-awake hold
ps -axo pid=,stat=,comm= | awk '$2 ~ /^T/'    # frozen processes (state T)
```

## Layout

```
Sources/ClaudeNotClose/
  main.swift          — bootstrap, .accessory (no Dock icon)
  AppDelegate.swift   — status item, menu, state machine, lid observers
  SleepManager.swift  — IOKit assertions + pmset disablesleep mode
  PowerSaver.swift    — throttle/freeze engine + on-disk state
  ProcessTree.swift   — parent→children map (Electron helpers)
  AppCatalog.swift    — allowlist, never-touch list, per-app policies
  HogList.swift       — CPU per app with helpers rolled up
  EnergyMonitor.swift — watts from AppleSmartBattery, rate, forecast
  PowerMonitor.swift  — AC/battery state from IOKit.ps
  SystemTweaks.swift  — Low Power Mode, Spotlight, display off
  ClaudeWatcher.swift — pgrep over the watched processes
  Preferences.swift   — UserDefaults + formatting
  Notifier.swift      — system notifications
tools/
  make-art.swift      — regenerates docs/*.png and the app icon
```

Artwork is generated, not hand-drawn — `swift tools/make-art.swift`, then
`iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`.

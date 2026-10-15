import AppKit

/// The power-saving engine: throttles / freezes apps outside the allowlist and can
/// put everything back.
///
/// Safety matters most here — a frozen process nobody resumes is a hung app for the
/// rest of the session. So:
///  • state is written to disk on every change,
///  • on launch the app restores whatever a previous instance left behind,
///  • restore runs from `applicationWillTerminate` and from the signal handlers,
///  • SIGSTOP is opt-in; the default mode uses reversible `taskpolicy -b`.
///
/// The throttling mechanism is `taskpolicy -b` (darwinbg). Measured on Apple Silicon:
/// a CPU-bound task slows down ~2x as it lands on the efficiency cores.
final class PowerSaver {

    struct Record: Codable {
        var pids: [Int32]
        var bundleId: String
        var name: String
        var policy: AppPolicy
    }

    struct Result {
        var throttled: [String] = []
        var suspended: [String] = []
        var quit: [String] = []
        var processCount = 0

        var isEmpty: Bool { throttled.isEmpty && suspended.isEmpty && quit.isEmpty }
        var appCount: Int { throttled.count + suspended.count + quit.count }

        var summary: String {
            var parts: [String] = []
            if !throttled.isEmpty { parts.append("\(throttled.count) backgrounded") }
            if !suspended.isEmpty { parts.append("\(suspended.count) frozen") }
            if !quit.isEmpty { parts.append("\(quit.count) quit") }
            guard !parts.isEmpty else { return "nothing to do" }
            return parts.joined(separator: ", ") + " (\(processCount) processes)"
        }
    }

    private(set) var isEngaged = false
    private(set) var lastResult = Result()
    private var records: [Record] = []

    /// Process work happens off the main thread — `taskpolicy` is a subprocess and a
    /// Slack or Cursor tree is a dozen-plus PIDs.
    private let queue = DispatchQueue(label: "com.michalkaronczyk.ClaudeNotClose.powersaver",
                                      qos: .userInitiated)

    private let stateURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeNotClose", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("throttled.json")
    }()

    // MARK: - Engage

    /// - Parameters:
    ///   - aggressive: `true` freezes (SIGSTOP) everything outside the allowlist,
    ///     `false` only throttles via `taskpolicy -b`.
    ///   - completion: called on the main thread when done.
    func engage(aggressive: Bool, completion: @escaping (Result) -> Void) {
        // Phase 1 (main thread): collect targets via NSWorkspace.
        struct Target {
            var app: NSRunningApplication
            var bundleId: String
            var name: String
            var policy: AppPolicy
        }

        var targets: [Target] = []
        for app in AppCatalog.candidates() {
            guard let bundleId = app.bundleIdentifier else { continue }
            let policy = AppCatalog.policy(for: bundleId, aggressive: aggressive)
            guard policy != .protected else { continue }
            targets.append(Target(app: app, bundleId: bundleId,
                                  name: AppCatalog.displayName(app), policy: policy))
        }

        // Graceful quit has to go through AppKit, so it happens here.
        var result = Result()
        var pending: [(pids: [Int32], bundleId: String, name: String, policy: AppPolicy)] = []

        let tree = ProcessTree()
        for target in targets {
            switch target.policy {
            case .protected:
                continue
            case .quit:
                target.app.terminate()
                result.quit.append(target.name)
            case .throttle, .suspend:
                let pids = tree.descendants(of: target.app.processIdentifier)
                pending.append((pids, target.bundleId, target.name, target.policy))
            }
        }

        // Phase 2 (background): taskpolicy and signals.
        queue.async { [weak self] in
            guard let self else { return }
            var newRecords: [Record] = []
            var localResult = result

            for item in pending {
                switch item.policy {
                case .throttle:
                    var touched: [Int32] = []
                    for pid in item.pids where self.setBackground(true, pid: pid) {
                        touched.append(pid)
                    }
                    guard !touched.isEmpty else { continue }
                    localResult.throttled.append(item.name)
                    localResult.processCount += touched.count
                    newRecords.append(Record(pids: touched, bundleId: item.bundleId,
                                             name: item.name, policy: .throttle))

                case .suspend:
                    // Background first (so they do not grab the CPU on resume),
                    // then STOP from leaves to root — otherwise the parent would
                    // respawn a stopped child.
                    for pid in item.pids { _ = self.setBackground(true, pid: pid) }
                    var stopped: [Int32] = []
                    for pid in item.pids.reversed() where kill(pid, SIGSTOP) == 0 {
                        stopped.append(pid)
                    }
                    guard !stopped.isEmpty else {
                        for pid in item.pids { _ = self.setBackground(false, pid: pid) }
                        continue
                    }
                    localResult.suspended.append(item.name)
                    localResult.processCount += stopped.count
                    newRecords.append(Record(pids: stopped, bundleId: item.bundleId,
                                             name: item.name, policy: .suspend))

                case .protected, .quit:
                    continue
                }
            }

            DispatchQueue.main.async {
                self.records = newRecords
                self.persist()
                self.isEngaged = true
                self.lastResult = localResult
                completion(localResult)
            }
        }
    }

    // MARK: - Release

    func release(completion: (() -> Void)? = nil) {
        let snapshot = records
        records = []
        persist()
        isEngaged = false
        lastResult = Result()

        queue.async { [weak self] in
            guard let self else { return }
            for record in snapshot {
                self.restore(record)
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Synchronous restore — for app termination, where there is no time left to
    /// bounce between queues.
    func releaseSynchronously() {
        for record in records {
            restore(record)
        }
        records = []
        persist()
        isEngaged = false
        lastResult = Result()
    }

    private func restore(_ record: Record) {
        // Resume from the root down, the reverse of how we froze.
        if record.policy == .suspend {
            for pid in record.pids {
                _ = kill(pid, SIGCONT)
            }
        }
        for pid in record.pids {
            _ = setBackground(false, pid: pid)
        }
    }

    // MARK: - Single apps

    /// Freezes the given process tree ad hoc (e.g. from the energy-hogs list).
    @discardableResult
    func suspendTree(rootPID: Int32, bundleId: String, name: String) -> Bool {
        guard !isManaged(pid: rootPID) else { return false }
        let pids = ProcessTree().descendants(of: rootPID)
        for pid in pids { _ = setBackground(true, pid: pid) }
        var stopped: [Int32] = []
        for pid in pids.reversed() where kill(pid, SIGSTOP) == 0 {
            stopped.append(pid)
        }
        guard !stopped.isEmpty else {
            for pid in pids { _ = setBackground(false, pid: pid) }
            return false
        }
        records.append(Record(pids: stopped, bundleId: bundleId, name: name, policy: .suspend))
        persist()
        return true
    }

    func isManaged(pid: Int32) -> Bool {
        records.contains { $0.pids.contains(pid) }
    }

    var managedRecords: [Record] { records }

    // MARK: - Crash recovery

    /// Called at launch: anything a previous instance froze gets resumed.
    /// - Returns: the number of restored processes.
    @discardableResult
    func recoverFromPreviousRun() -> Int {
        guard let data = try? Data(contentsOf: stateURL),
              let stale = try? JSONDecoder().decode([Record].self, from: data),
              !stale.isEmpty else { return 0 }

        var restored = 0
        for record in stale {
            let alive = record.pids.filter(PowerSaver.processExists)
            guard !alive.isEmpty else { continue }
            restore(Record(pids: alive, bundleId: record.bundleId,
                           name: record.name, policy: record.policy))
            restored += alive.count
        }
        records = []
        persist()
        return restored
    }

    private static func processExists(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func persist() {
        if records.isEmpty {
            try? FileManager.default.removeItem(at: stateURL)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: - Low level

    /// `taskpolicy -b -p <pid>` puts a task into darwinbg (efficiency cores + I/O
    /// throttling), `-B` restores normal priority. Unlike `renice` it is fully
    /// reversible without root.
    ///
    /// Note: `setpriority(PRIO_DARWIN_PROCESS, …)` looks like the cheaper option (a
    /// plain syscall), but on other processes it returns success and does nothing —
    /// verified. Hence `taskpolicy`, subprocess cost and all.
    private func setBackground(_ enabled: Bool, pid: Int32) -> Bool {
        let flag = enabled ? "-b" : "-B"
        return Shell.run("/usr/sbin/taskpolicy", [flag, "-p", String(pid)]) != nil
    }
}

import Foundation
import Testing
@testable import ClaudeNotClose

@Suite(.serialized)
struct AgentBridgeTests {

    // MARK: Text

    @Test func finishedCardUsesLastMessage() {
        let text = AgentBridge.finishedCard(["last_assistant_message": "All tests pass."])
        #expect(text.hasPrefix("✅ <b>Claude finished</b>"))
        #expect(text.contains("<blockquote>All tests pass.</blockquote>"))
    }

    @Test func finishedCardIsClipped() {
        let long = String(repeating: "a", count: 2000)
        let text = AgentBridge.finishedCard(["last_assistant_message": long])
        #expect(text.count < 700)
        #expect(text.contains("…</blockquote>"))
    }

    @Test func finishedCardWithoutMessageHasNoQuote() {
        let text = AgentBridge.finishedCard([:])
        #expect(text == "✅ <b>Claude finished</b>")
    }

    @Test func cardEscapesHTML() {
        let text = AgentBridge.card(icon: "🔐", title: "Bash", code: "echo <a> && b")
        #expect(text.contains("<pre>echo &lt;a&gt; &amp;&amp; b</pre>"))
    }

    @Test func cardShowsProjectFromCwd() {
        let text = AgentBridge.card(icon: "✅", title: "Done", payload: ["cwd": "/Users/me/work/my-app"])
        #expect(text.hasSuffix("📁 <code>my-app</code>"))
    }

    @Test func attentionCardJoinsTitleAndMessage() {
        let text = AgentBridge.attentionCard(["title": "Permission needed", "message": "Run tests?"])
        #expect(text.contains("<b>Permission needed</b>"))
        #expect(text.contains("Run tests?"))
    }

    @Test func failureCardIncludesErrorType() {
        let text = AgentBridge.failureCard(["error": "rate_limit", "last_assistant_message": "API Error"])
        #expect(text.contains("rate_limit"))
        #expect(text.contains("API Error"))
    }

    @Test func plainFromHTMLStripsTagsAndEntities() {
        let html = "<b>Hi</b>\n<pre>a &lt; b &amp;&amp; c</pre>"
        #expect(TelegramClient.plain(fromHTML: html) == "Hi\na < b && c")
    }

    @Test func toolSummaryPrefersCommand() {
        #expect(AgentBridge.toolSummary(["command": "npm test", "description": "x"]) == "npm test")
        #expect(AgentBridge.toolSummary(nil) == "")
    }

    // MARK: Gating

    @Test func nothingHappensWhenPushIsOff() async {
        let saved = Preferences.remotePushEnabled
        defer { Preferences.remotePushEnabled = saved }
        Preferences.remotePushEnabled = false
        let out = await AgentBridge.handle(["hook_event_name": "Stop", "last_assistant_message": "x"])
        #expect(out == "")
    }

    @Test func nothingHappensOutsideAgentMode() async {
        let saved = AgentBridge.agentModeActive
        defer { AgentBridge.agentModeActive = saved }
        AgentBridge.agentModeActive = { false }
        #expect(!AgentBridge.isEnabled)
        let out = await AgentBridge.handle(["hook_event_name": "PermissionRequest", "tool_name": "Bash"])
        #expect(out == "")
    }

    // MARK: Finish only when really done

    @Test func stopWithRunningBackgroundTaskIsNotFinal() {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "background_tasks": [["id": "t1", "type": "shell", "status": "running"]],
            "session_crons": [],
        ]
        #expect(!AgentBridge.isFinalStop(payload))
    }

    @Test func stopWithOneShotWakeupIsNotFinal() {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "background_tasks": [],
            "session_crons": [["id": "c1", "schedule": "0 9 * * *", "recurring": false]],
        ]
        #expect(!AgentBridge.isFinalStop(payload))
    }

    @Test func stopWithNothingInFlightIsFinal() {
        let payload: [String: Any] = ["hook_event_name": "Stop", "background_tasks": [], "session_crons": []]
        #expect(AgentBridge.isFinalStop(payload))
    }

    @Test func stopWithoutRegistryFieldsIsFinal() {
        #expect(AgentBridge.isFinalStop(["hook_event_name": "Stop"]))
    }

    @Test func idleNotificationIsNotAnActionMoment() {
        #expect(!AgentBridge.actionTypes.contains("idle_prompt"))
        #expect(AgentBridge.actionTypes.contains("permission_prompt"))
    }

    // MARK: Hook server parsing

    @Test func parsesCompleteRequest() throws {
        let raw = "POST /hook/abc HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
        let request = try #require(HookServer.parse(Data(raw.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/hook/abc")
        #expect(String(data: request.body, encoding: .utf8) == "hello")
    }

    @Test func waitsForFullBody() {
        let raw = "POST /hook/abc HTTP/1.1\r\nContent-Length: 10\r\n\r\nhello"
        #expect(HookServer.parse(Data(raw.utf8)) == nil)
    }

    @Test func waitsForHeaders() {
        #expect(HookServer.parse(Data("POST /hook/abc HTTP/1.1\r\nContent-Le".utf8)) == nil)
    }

    // MARK: Hooks installer

    @Test func installAddsAllEventsAndKeepsOthers() {
        let existing: [String: Any] = [
            "theme": "dark",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo mine"]]]]],
        ]
        let cmd = "curl http://127.0.0.1:47821/hook/tok"
        let result = HooksInstaller.installed(into: existing, command: cmd)
        #expect(result["theme"] as? String == "dark")
        let hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in HooksInstaller.events { #expect(hooks[event.name] != nil) }
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        #expect(stop.count == 2)
        #expect(stop.contains { !HooksInstaller.isOurs($0) })
    }

    @Test func installTwiceDoesNotDuplicate() {
        let cmd = "curl http://127.0.0.1:47821/hook/tok"
        let once = HooksInstaller.installed(into: [:], command: cmd)
        let twice = HooksInstaller.installed(into: once, command: cmd)
        let stop = (twice["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        #expect(stop.count == 1)
    }

    @Test func askUserQuestionUsesMatcher() {
        let result = HooksInstaller.installed(into: [:], command: "curl http://127.0.0.1:1/hook/t")
        let pre = (result["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        #expect(pre.first?["matcher"] as? String == "AskUserQuestion")
    }

    @Test func removeLeavesOtherHooksAndDropsEmpty() {
        let mine: [String: Any] = ["hooks": [["type": "command", "command": "curl http://127.0.0.1:1/hook/t"]]]
        let other: [String: Any] = ["hooks": [["type": "command", "command": "echo mine"]]]
        let settings: [String: Any] = ["hooks": ["Stop": [mine, other], "Notification": [mine]]]
        let result = HooksInstaller.removed(from: settings)
        let hooks = result["hooks"] as? [String: Any] ?? [:]
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 1)
        #expect(hooks["Notification"] == nil)
    }

    @Test func removeFromEmptyIsNoOp() {
        #expect(HooksInstaller.removed(from: ["a": 1]).count == 1)
    }

    // MARK: Chat cleanup

    private func entry(_ id: Int, _ project: String, minutesAgo: Double, pending: Bool = false,
                       now: Date) -> MessageLog.Entry {
        MessageLog.Entry(id: id, project: project, sent: now.addingTimeInterval(-minutesAgo * 60), pending: pending)
    }

    @Test func messagesOlderThanEightHoursAreStale() {
        let now = Date()
        let entries = [entry(1, "a", minutesAgo: 481, now: now), entry(2, "a", minutesAgo: 479, now: now)]
        #expect(MessageLog.staleIds(entries, now: now, readUpTo: nil) == [1])
    }

    @Test func readMessagesNeedThreeNewerFromSameProject() {
        let now = Date()
        let entries = (1...4).map { entry($0, "a", minutesAgo: Double(10 - $0), now: now) }
        // ids 1...4 oldest to newest: only id 1 has three newer ones.
        #expect(MessageLog.staleIds(entries, now: now, readUpTo: now) == [1])
    }

    @Test func otherProjectsDoNotCountAsNewer() {
        let now = Date()
        let entries = [entry(1, "a", minutesAgo: 10, now: now), entry(2, "b", minutesAgo: 9, now: now),
                       entry(3, "b", minutesAgo: 8, now: now), entry(4, "b", minutesAgo: 7, now: now)]
        #expect(MessageLog.staleIds(entries, now: now, readUpTo: now).isEmpty)
    }

    @Test func nothingIsReadWithoutAReadEvent() {
        let now = Date()
        let entries = (1...5).map { entry($0, "a", minutesAgo: Double(10 - $0), now: now) }
        #expect(MessageLog.staleIds(entries, now: now, readUpTo: nil).isEmpty)
    }

    @Test func messagesSentAfterTheReadAreKept() {
        let now = Date()
        let entries = (1...5).map { entry($0, "a", minutesAgo: Double(10 - $0), now: now) }
        let readAt = now.addingTimeInterval(-(10 - 1.5) * 60)   // between id 1 and id 2
        #expect(MessageLog.staleIds(entries, now: now, readUpTo: readAt) == [1])
    }

    @Test func pendingQuestionIsNeverCleanedAsRead() {
        let now = Date()
        var entries = (1...4).map { entry($0, "a", minutesAgo: Double(10 - $0), now: now) }
        entries[0].pending = true
        #expect(MessageLog.staleIds(entries, now: now, readUpTo: now).isEmpty)
    }

    // MARK: Session context

    @Test func footerNamesSessionProjectAndAgent() {
        let payload: [String: Any] = ["cwd": "/nowhere/my-app", "session_id": "a3f9c1d2-0000", "agent_type": "Explore"]
        let text = AgentBridge.card(icon: "🔐", title: "Bash", payload: payload)
        #expect(text.hasSuffix("📁 <code>my-app</code> · 🤖 Explore · #a3f9"))
    }

    @Test func sessionTitleComesFromSessionStart() {
        SessionContext.remember(["session_id": "t1t1", "session_title": "refactor auth"])
        let text = AgentBridge.card(icon: "✅", title: "Done", payload: ["session_id": "t1t1"])
        #expect(text.contains("🏷 <b>refactor auth</b>"))
        SessionContext.remember(["session_id": "t1t1"])
        #expect(!AgentBridge.card(icon: "✅", title: "Done", payload: ["session_id": "t1t1"]).contains("🏷"))
    }

    @Test func gitBranchIsReadFromParentRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/feature/x\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SessionContext.gitBranch(in: sub.path) == "feature/x")
    }

    @Test func gitBranchFollowsWorktreeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gitDir = root.appendingPathComponent("main/.git/worktrees/w")
        let work = root.appendingPathComponent("w")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "ref: refs/heads/hotfix\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(gitDir.path)\n".write(to: work.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SessionContext.gitBranch(in: work.path) == "hotfix")
    }

    @Test func gitBranchIsNilOutsideRepositories() {
        #expect(SessionContext.gitBranch(in: "/nonexistent/path") == nil)
    }
}

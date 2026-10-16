import Foundation
import CoreGraphics
import IOKit

/// Turns Claude Code hook events into Telegram messages and, while the user is away
/// from the Mac, lets them answer questions and approvals with buttons.
enum AgentBridge {

    /// How long a question waits for a phone answer before falling back to the terminal.
    static let answerTimeout: TimeInterval = 540

    /// Set by the app: `true` while the lid is shut, the screen is locked or the display is
    /// asleep. Plain messages and phone prompts both go out only then.
    static var userAway: () -> Bool = { macIsAway() }

    /// Notification types where the user has to do something. Everything else
    /// (idle reminders, auth, quota and completion notes) stays off the phone.
    static let actionTypes: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]

    /// Set by the app: `true` while agent mode is on. Outside it nothing goes to the phone.
    static var agentModeActive: () -> Bool = { true }

    /// Everything the bridge does is off unless push is configured and agent mode is on.
    static var isEnabled: Bool {
        Preferences.remotePushEnabled && TelegramClient.isConfigured && agentModeActive()
    }

    // MARK: - Entry point

    /// Handles one hook payload and returns the JSON for Claude Code ("" = no decision).
    static func handle(_ payload: [String: Any]) async -> String {
        guard isEnabled, let event = payload["hook_event_name"] as? String else { return "" }

        switch event {
        case "SessionStart":
            SessionContext.remember(payload)
        case "PreToolUse":
            guard payload["tool_name"] as? String == "AskUserQuestion" else { return "" }
            return await askQuestions(payload)
        case "PermissionRequest":
            return await askPermission(payload)
        case "Stop":
            guard Preferences.pushOnFinish, isFinalStop(payload) else { return "" }
            await notify(finishedCard(payload), project: projectName(payload))
        case "Notification":
            guard Preferences.pushOnAttention else { return "" }
            let type = payload["notification_type"] as? String ?? ""
            guard actionTypes.contains(type) else { return "" }
            if type == "permission_prompt", Preferences.answerFromPhone { return "" }
            await notify(attentionCard(payload), project: projectName(payload))
        case "StopFailure":
            guard Preferences.pushOnAttention else { return "" }
            await notify(failureCard(payload), project: projectName(payload))
        default:
            break
        }
        return ""
    }

    private static func notify(_ html: String, project: String?) async {
        guard userAway() else { return }
        guard let id = try? await TelegramClient.send(html) else { return }
        await MessageLog.shared.record(id: id, project: project)
    }

    // MARK: - Interactive

    private static func askQuestions(_ payload: [String: Any]) async -> String {
        guard var input = payload["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { return "" }
        let away = Preferences.answerFromPhone && userAway()

        // Not away: the terminal prompt must stay usable, so only tell the phone.
        guard away, !questions.contains(where: { $0["multiSelect"] as? Bool == true }) else {
            let text = questions.compactMap { $0["question"] as? String }.joined(separator: "\n\n")
            if Preferences.pushOnAttention {
                await notify(card(icon: "❓", title: "Claude asks", body: text, payload: payload),
                             project: projectName(payload))
            }
            return ""
        }

        var answers: [String: String] = [:]
        for q in questions {
            guard let question = q["question"] as? String,
                  let options = q["options"] as? [[String: Any]] else { return "" }
            let labels = options.compactMap { $0["label"] as? String }
            guard let index = await choose(title: card(icon: "❓", title: "Claude asks", body: question, payload: payload),
                                       options: labels, project: projectName(payload)) else {
                return ""
            }
            answers[question] = labels[index]
        }
        input["answers"] = answers
        return encode(["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": input,
        ] as [String: Any]])
    }

    private static func askPermission(_ payload: [String: Any]) async -> String {
        let tool = payload["tool_name"] as? String ?? "tool"
        guard tool != "AskUserQuestion", Preferences.answerFromPhone, userAway() else { return "" }
        let summary = toolSummary(payload["tool_input"] as? [String: Any])
        let title = card(icon: "🔐", title: "Claude wants to use \(tool)", code: summary, payload: payload)
        guard let index = await choose(title: title, options: ["Allow", "Deny"],
                                       project: projectName(payload)) else { return "" }
        var decision: [String: Any] = ["behavior": index == 0 ? "allow" : "deny"]
        if index != 0 { decision["message"] = "Denied from Telegram" }
        return encode(["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": decision,
        ] as [String: Any]])
    }

    /// Shows buttons and waits for the answer. One prompt at a time. `title` is HTML.
    private static func choose(title: String, options: [String], project: String?) async -> Int? {
        await PromptGate.shared.enter()
        defer { Task { await PromptGate.shared.leave() } }

        let id = String(UUID().uuidString.prefix(8))
        let buttons = options.enumerated().map { ["text": $1, "callback_data": "\(id):\($0)"] }
        guard let messageId = try? await TelegramClient.send(title, buttons: buttons) else { return nil }
        await MessageLog.shared.record(id: messageId, project: project, pending: true)
        let deadline = Date().addingTimeInterval(answerTimeout)
        guard let raw = await TelegramClient.waitForCallback(prefix: id + ":", deadline: deadline),
              let index = Int(raw), options.indices.contains(index) else {
            await TelegramClient.edit(messageId: messageId,
                                      html: title + "\n\n⏱ <i>No answer, asked in the terminal</i>")
            await MessageLog.shared.resolve(id: messageId, answered: false)
            return nil
        }
        let chosen = TelegramClient.escape(options[index])
        await TelegramClient.edit(messageId: messageId, html: title + "\n\n✅ Answer: <b>\(chosen)</b>")
        await MessageLog.shared.resolve(id: messageId, answered: true)
        return index
    }

    // MARK: - Text

    /// `Stop` fires at the end of every turn, also when the session is only paused until a
    /// background task or a one-shot wakeup resumes it. Only the last one means "finished".
    static func isFinalStop(_ payload: [String: Any]) -> Bool {
        let tasks = payload["background_tasks"] as? [[String: Any]] ?? []
        let crons = payload["session_crons"] as? [[String: Any]] ?? []
        let pendingWakeup = crons.contains { $0["recurring"] as? Bool == false }
        return tasks.isEmpty && !pendingWakeup
    }

    /// Builds one message: a bold header line, the body as a quote, an optional code block
    /// and a line naming the session, project and branch. Telegram has no embeds; this is the closest it gets.
    static func card(icon: String, title: String, body: String = "", code: String = "",
                     payload: [String: Any]? = nil) -> String {
        let escape = TelegramClient.escape
        var parts = ["\(icon) <b>\(escape(title))</b>"]
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append("<blockquote>\(escape(text))</blockquote>") }
        if !code.isEmpty { parts.append("<pre>\(escape(code))</pre>") }
        if let context = SessionContext.line(payload) { parts.append(context) }
        return parts.joined(separator: "\n")
    }

    static func projectName(_ payload: [String: Any]?) -> String? {
        guard let cwd = payload?["cwd"] as? String, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    static func finishedCard(_ payload: [String: Any]) -> String {
        let last = (payload["last_assistant_message"] as? String) ?? ""
        let body = TelegramClient.clip(last.trimmingCharacters(in: .whitespacesAndNewlines), 600)
        return card(icon: "✅", title: "Claude finished", body: body, payload: payload)
    }

    static func attentionCard(_ payload: [String: Any]) -> String {
        let message = payload["message"] as? String ?? "Claude needs your attention."
        let title = (payload["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Needs your attention"
        return card(icon: "🔔", title: title, body: message, payload: payload)
    }

    static func failureCard(_ payload: [String: Any]) -> String {
        let error = payload["error"] as? String ?? "unknown"
        let details = payload["last_assistant_message"] as? String ?? ""
        return card(icon: "⚠️", title: "Claude stopped (\(error))",
                    body: TelegramClient.clip(details, 300), payload: payload)
    }

    static func toolSummary(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["command", "file_path", "url", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return TelegramClient.clip(value, 400) }
        }
        return ""
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    // MARK: - Presence

    /// Lid shut or screen locked. The display being asleep is tracked by the app delegate.
    static func macIsAway() -> Bool {
        lidClosed() == true || screenLocked()
    }

    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// `true` when the lid is shut, `nil` when the system does not report it.
    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let prop = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                   kCFAllocatorDefault, 0)?.takeRetainedValue()
        return prop as? Bool
    }
}

/// Serialises interactive prompts: Telegram hands each update to one poller only.
actor PromptGate {
    static let shared = PromptGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

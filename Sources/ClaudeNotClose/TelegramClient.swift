import Foundation

/// Minimal Telegram Bot API client: send, inline keyboards, callback polling.
enum TelegramClient {

    struct Failure: Error { let text: String }

    /// Kept in the app's preferences. The Keychain is not used: an ad-hoc signed app makes
    /// macOS ask for permission on every new build.
    static var token: String? {
        get { UserDefaults.standard.string(forKey: "telegramBotToken") }
        set {
            let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: "telegramBotToken")
            } else {
                UserDefaults.standard.set(value, forKey: "telegramBotToken")
            }
        }
    }

    static var isConfigured: Bool {
        !(token ?? "").isEmpty && !Preferences.telegramChatId.isEmpty
    }

    // MARK: - API

    /// Calls a Bot API method and returns its `result`.
    @discardableResult
    static func call(_ method: String, _ params: [String: Any], token override: String? = nil,
                     timeout: TimeInterval = 15) async throws -> Any {
        guard let token = override ?? self.token, !token.isEmpty,
              let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw Failure(text: "Not configured")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, _) = try await URLSession.shared.data(for: request)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard obj?["ok"] as? Bool == true else {
            throw Failure(text: obj?["description"] as? String ?? "Telegram rejected the request")
        }
        return obj?["result"] ?? [:]
    }

    /// Sends an HTML-formatted message to the configured chat. Returns the message id.
    /// Callers escape user text with `escape`; if Telegram still rejects the markup the
    /// message goes out as plain text instead of being lost.
    @discardableResult
    static func send(_ html: String, buttons: [[String: String]] = []) async throws -> Int {
        var params: [String: Any] = ["chat_id": Preferences.telegramChatId]
        if !buttons.isEmpty {
            // One button per row keeps long option labels readable.
            params["reply_markup"] = ["inline_keyboard": buttons.map { [$0] }]
        }
        let result = try await callFormatted("sendMessage", params, html: html) as? [String: Any]
        return result?["message_id"] as? Int ?? 0
    }

    static func edit(messageId: Int, html: String) async {
        let params: [String: Any] = ["chat_id": Preferences.telegramChatId, "message_id": messageId]
        _ = try? await callFormatted("editMessageText", params, html: html)
    }

    private static func callFormatted(_ method: String, _ params: [String: Any], html: String) async throws -> Any {
        var withText = params
        withText["text"] = clip(html, 3800)
        withText["parse_mode"] = "HTML"
        withText["link_preview_options"] = ["is_disabled": true]
        do {
            return try await call(method, withText)
        } catch let failure as Failure where failure.text.contains("parse entities") {
            withText["text"] = clip(plain(fromHTML: html), 3800)
            withText.removeValue(forKey: "parse_mode")
            return try await call(method, withText)
        }
    }

    // MARK: - Formatting

    /// Escapes text for use inside HTML-formatted messages.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func plain(fromHTML html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Removes one of the bot's messages. `false` means the network failed and a retry
    /// makes sense; an API refusal (already deleted, too old) counts as gone.
    static func delete(messageId: Int) async -> Bool {
        do {
            _ = try await call("deleteMessage", ["chat_id": Preferences.telegramChatId,
                                                 "message_id": messageId])
            return true
        } catch is Failure {
            return true
        } catch {
            return false
        }
    }

    // MARK: - Updates

    /// What one `getUpdates` round brought from the configured chat.
    struct Batch {
        var callbacks: [(id: String, data: String)] = []
        /// When the user last wrote to the bot.
        var lastMessage: Date?
    }

    /// Only one caller may poll at a time (hold `PromptGate`); this is also what makes the
    /// shared offset safe.
    private static var updateOffset = 0

    static func poll(timeout: Int) async -> Batch? {
        let params: [String: Any] = ["offset": updateOffset, "timeout": timeout,
                                     "allowed_updates": ["callback_query", "message"]]
        guard let updates = try? await call("getUpdates", params, timeout: TimeInterval(timeout + 10))
                as? [[String: Any]] else { return nil }
        var batch = Batch()
        for update in updates {
            if let id = update["update_id"] as? Int { updateOffset = max(updateOffset, id + 1) }
            if let cb = update["callback_query"] as? [String: Any],
               let data = cb["data"] as? String, let id = cb["id"] as? String,
               isFromConfiguredChat(cb["message"] as? [String: Any]) {
                batch.callbacks.append((id, data))
            } else if let message = update["message"] as? [String: Any],
                      isFromConfiguredChat(message), let date = message["date"] as? Double {
                batch.lastMessage = max(batch.lastMessage ?? .distantPast, Date(timeIntervalSince1970: date))
            }
        }
        return batch
    }

    private static func isFromConfiguredChat(_ message: [String: Any]?) -> Bool {
        guard let chat = message?["chat"] as? [String: Any], let id = chat["id"] as? Int64 else { return false }
        return String(id) == Preferences.telegramChatId
    }

    /// Waits for a button press carrying `prefix`. Returns the suffix after the prefix.
    /// Messages the user writes meanwhile are treated as "read" for the chat cleanup.
    static func waitForCallback(prefix: String, deadline: Date) async -> String? {
        while Date() < deadline, !Task.isCancelled {
            let remaining = max(1, min(20, Int(deadline.timeIntervalSinceNow)))
            guard let batch = await poll(timeout: remaining) else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            if let read = batch.lastMessage { await MessageLog.shared.sweep(readUpTo: read) }
            if let hit = batch.callbacks.first(where: { $0.data.hasPrefix(prefix) }) {
                _ = try? await call("answerCallbackQuery", ["callback_query_id": hit.id])
                return String(hit.data.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// Chat id of the latest message sent to the bot.
    static func detectChatId(token: String) async -> (id: String?, error: String?) {
        do {
            let result = try await call("getUpdates", [:], token: token) as? [[String: Any]] ?? []
            for update in result.reversed() {
                let msg = (update["message"] ?? update["channel_post"]) as? [String: Any]
                if let chat = msg?["chat"] as? [String: Any], let n = chat["id"] as? Int64 {
                    return (String(n), nil)
                }
            }
            return (nil, "No messages yet. Send any message to your bot, then retry.")
        } catch let failure as Failure {
            return (nil, failure.text)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

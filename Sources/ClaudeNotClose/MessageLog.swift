import Foundation

/// Remembers the messages the bot sent so the chat can be kept tidy.
///
/// A message is deleted when it is older than `maxAge`, or when it has been read and at
/// least `keepNewest` newer messages from the same project exist. Telegram does not report
/// reads, so "read" means: a question was answered or the user wrote to the bot.
actor MessageLog {
    static let shared = MessageLog()

    static let maxAge: TimeInterval = 8 * 3600
    static let keepNewest = 3
    /// How often the idle watcher looks for a message from the user.
    static let watchInterval: UInt64 = 15 * 1_000_000_000

    struct Entry: Codable, Equatable {
        var id: Int
        var project: String
        var sent: Date
        /// An unanswered question: must stay until it is answered or times out.
        var pending: Bool
    }

    private static let defaultsKey = "telegramMessageLog"

    private var entries: [Entry]
    private var watcher: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    // MARK: - Pure rules

    /// Ids to delete. `readUpTo` is the moment the user last looked at the chat, if known.
    static func staleIds(_ entries: [Entry], now: Date, readUpTo: Date?) -> Set<Int> {
        var stale = Set(entries.filter { now.timeIntervalSince($0.sent) > maxAge }.map(\.id))
        guard let readUpTo else { return stale }
        for (_, group) in Dictionary(grouping: entries, by: \.project) {
            let newestFirst = group.sorted { $0.sent > $1.sent }
            for entry in newestFirst.dropFirst(keepNewest) where !entry.pending && entry.sent <= readUpTo {
                stale.insert(entry.id)
            }
        }
        return stale
    }

    // MARK: - Tracking

    func record(id: Int, project: String?, pending: Bool = false) {
        guard id != 0 else { return }
        entries.append(Entry(id: id, project: project ?? "", sent: Date(), pending: pending))
        save()
        watch()
    }

    /// A question stopped waiting. `answered` means the user did read the chat.
    func resolve(id: Int, answered: Bool) async {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].pending = false
            save()
        }
        if answered { await sweep(readUpTo: Date()) }
    }

    /// Deletes what the rules mark as stale. An entry stays when the network failed, so the
    /// next sweep retries it.
    func sweep(readUpTo: Date?) async {
        let stale = Self.staleIds(entries, now: Date(), readUpTo: readUpTo)
        guard !stale.isEmpty else { return }
        for id in stale where await TelegramClient.delete(messageId: id) {
            entries.removeAll { $0.id == id }
        }
        save()
    }

    // MARK: - Idle watcher

    /// Polls for messages from the user while there is something to clean up. Prompts take
    /// over polling through `PromptGate` and handle reads themselves.
    func watch() {
        guard watcher == nil, TelegramClient.isConfigured else { return }
        watcher = Task {
            await self.watchLoop()
        }
    }

    private func watchLoop() async {
        while !Task.isCancelled {
            await sweep(readUpTo: nil)
            if entries.isEmpty || !TelegramClient.isConfigured { break }

            await PromptGate.shared.enter()
            let batch = await TelegramClient.poll(timeout: 0)
            await PromptGate.shared.leave()
            if let read = batch?.lastMessage { await sweep(readUpTo: read) }

            try? await Task.sleep(nanoseconds: Self.watchInterval)
        }
        watcher = nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

import Foundation

/// A key spotted in a session: the kinds and where, never any of the key.
public struct KeyAlert: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable { case prompt, command, file }

    public var id: Int
    /// Every new kind in the message, in first-seen order.
    public var kinds: [KeyKind]
    public var session: String
    public var agent: String
    public var source: Source
    public var at: Date
    public var cwd: String?
    public var transcript: String?
}

/// Watches hook agents' prompts, Bash commands and file writes for text shaped
/// like a key (`KeyShapes`). Each key alerts once per session: a match is
/// hashed at once with a per-instance salt (on top of `Hasher`'s per-process
/// seed) and dropped, so neither the key nor the text is kept. Nothing is
/// logged or written anywhere. Memory is capped: 256 hashes per session (the
/// oldest goes first), 64 sessions (the one seen least recently goes) and 20
/// alerts; a repeat alert after an eviction is accepted.
public struct KeyWatch: Sendable {
    static let maxHashes = 256
    static let maxSessions = 64
    static let maxAlerts = 20
    /// Bytes scanned per event, across all its fields.
    static let maxBytesPerEvent = 65_536

    private struct Seen: Sendable {
        var hashes: Set<Int> = []
        /// The same hashes in insertion order, for dropping the oldest.
        var order: [Int] = []
        var touched: UInt64 = 0
    }

    private let salt = UInt64.random(in: .min ... .max)
    private var seen: [String: Seen] = [:]
    private var tick: UInt64 = 0
    private var nextID = 0
    /// Standing alerts, newest first, until Got it.
    public private(set) var alerts: [KeyAlert] = []
    /// Moves whenever an alert is added or dismissed.
    public private(set) var generation = 0

    public init() {}

    /// Scans one hook event; returns an alert when it holds a key new to the session.
    public mutating func record(_ message: HookMessage, agent: String, at now: Date) -> KeyAlert? {
        guard let session = message.sessionID else { return nil }
        if message.event == "SessionEnd" {
            seen[session] = nil
            return nil
        }
        let fields = Self.fields(message)
        guard !fields.isEmpty else { return nil }
        var kinds: [KeyKind] = []
        var source: KeyAlert.Source?
        var matched = false
        var entry = seen[session] ?? Seen()
        var budget = Self.maxBytesPerEvent
        for (text, from) in fields {
            guard budget > 0 else { break }
            budget -= min(text.utf8.count, 2 * KeyShapes.window)
            KeyShapes.scan(text) { kind, match in
                var hasher = Hasher()
                hasher.combine(salt)
                hasher.combine(kind.rawValue)
                hasher.combine(match)
                let hash = hasher.finalize()
                matched = true
                guard entry.hashes.insert(hash).inserted else { return }
                entry.order.append(hash)
                if entry.order.count > Self.maxHashes { entry.hashes.remove(entry.order.removeFirst()) }
                if !kinds.contains(kind) { kinds.append(kind) }
                if source == nil { source = from }
            }
        }
        guard matched else { return nil }
        // Any match, new or repeat, counts as the session being seen.
        tick += 1
        entry.touched = tick
        if seen[session] == nil, seen.count >= Self.maxSessions,
           let stalest = seen.min(by: { $0.value.touched < $1.value.touched })?.key {
            seen[stalest] = nil
        }
        seen[session] = entry
        guard let source, !kinds.isEmpty else { return nil }
        nextID += 1
        let alert = KeyAlert(id: nextID, kinds: kinds, session: session, agent: agent, source: source, at: now,
                             cwd: message.cwd, transcript: message.payload["transcript_path"] as? String)
        alerts.insert(alert, at: 0)
        if alerts.count > Self.maxAlerts { alerts.removeLast(alerts.count - Self.maxAlerts) }
        generation += 1
        return alert
    }

    /// Got it: removes one alert.
    public mutating func dismiss(_ id: Int) {
        guard let index = alerts.firstIndex(where: { $0.id == id }) else { return }
        alerts.remove(at: index)
        generation += 1
    }

    /// Drops the hashes of every session not in `sessions` (their agents exited).
    public mutating func forget(keeping sessions: Set<String>) {
        seen = seen.filter { sessions.contains($0.key) }
    }

    var sessionCount: Int { seen.count }
    func hashCount(session: String) -> Int { seen[session]?.hashes.count ?? 0 }

    // MARK: Fields

    /// The text an event carries that the agent sends or writes: the prompt,
    /// a subagent's prompt, a Bash command, or new file text. Nothing else is read.
    static func fields(_ message: HookMessage) -> [(String, KeyAlert.Source)] {
        switch message.event {
        case "UserPromptSubmit":
            guard let prompt = message.payload["prompt"] as? String else { return [] }
            return [(prompt, .prompt)]
        case "PreToolUse":
            guard let tool = message.toolName?.lowercased() else { return [] }
            if message.provider == "antigravity", let antigravity = antigravityFields(message, tool: tool) { return antigravity }
            let input = message.toolInput
            func strings(_ keys: String...) -> [String] { keys.compactMap { input[$0] as? String } }
            switch tool {
            case "bash":
                return strings("command").map { ($0, .command) }
            case "write":
                // Copilot's create keeps its text in `file_text`.
                return strings("content", "file_text").map { ($0, .file) }
            case "edit":
                // Copilot's edit keeps its text in `new_str`.
                return strings("new_string", "new_str").map { ($0, .file) }
            case "multiedit":
                let edits = input["edits"] as? [[String: Any]] ?? []
                return edits.compactMap { $0["new_string"] as? String }.map { ($0, .file) }
            case "notebookedit":
                return strings("new_source").map { ($0, .file) }
            case "agent", "task":
                // A subagent's prompt (Claude Code's Agent/Task, Copilot's task) is sent to the model too.
                return strings("description", "prompt").map { ($0, .prompt) }
            default:
                return []
            }
        default:
            return []
        }
    }

    /// Antigravity's argument names aren't verified from a live run, so for its
    /// command and write tools every string in the raw `toolCall.args` is read,
    /// except the text an edit replaces (removing a key is no new key).
    static func antigravityFields(_ message: HookMessage, tool: String) -> [(String, KeyAlert.Source)]? {
        let source: KeyAlert.Source
        switch tool {
        case "bash": source = .command
        case "write", "edit", "multiedit": source = .file
        default:
            // A write tool HookMessage doesn't map yet (`write_to_file` and the like).
            let name = ((message.payload["toolCall"] as? [String: Any])?["name"] as? String ?? tool).lowercased()
            guard ["write", "replace", "edit", "create"].contains(where: name.contains) else { return nil }
            source = .file
        }
        guard let args = (message.payload["toolCall"] as? [String: Any])?["args"] else { return nil }
        var out: [(String, KeyAlert.Source)] = []
        collectStrings(args, depth: 0, skipping: isOldText) { out.append(($0, source)) }
        return out
    }

    /// An argument holding the text an edit replaces: `TargetContent`, `old_string`, `old_str` and the like.
    static func isOldText(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("target") || lower.hasPrefix("old") || lower.contains("original") || lower.contains("search")
    }

    /// Every string in a JSON value, nested ones included, at most 8 levels and
    /// 256 strings deep, leaving out strings under keys `skipping` names.
    static func collectStrings(_ value: Any, depth: Int, skipping: (String) -> Bool, _ add: (String) -> Void) {
        var count = 0
        func walk(_ value: Any, _ depth: Int) {
            guard depth <= 8, count < 256 else { return }
            if let text = value as? String { count += 1; add(text) }
            else if let object = value as? [String: Any] {
                // Sorted, so the same message is always read in the same order.
                // Only a string under an old-text name is skipped; containers are always walked.
                for (key, item) in object.sorted(by: { $0.key < $1.key }) where !(item is String && skipping(key)) { walk(item, depth + 1) }
            }
            else if let array = value as? [Any] { for item in array { walk(item, depth + 1) } }
        }
        walk(value, depth)
    }
}

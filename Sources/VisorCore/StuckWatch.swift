import Foundation

/// An agent going round in circles: the same call failing again and again, or
/// run over and over with no edit in between.
public struct Stuck: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// The same call failed `count` times in a row.
        case failing
        /// The same call ran `count` times with no edit in between.
        case looping
    }

    public var session: String
    /// The session plus its subagent, if the loop is a subagent's.
    public var actor: String
    public var agent: String
    /// What it keeps running: the command's first line, or the tool and file.
    public var label: String
    public var kind: Kind
    public var count: Int
    /// The latest failure's first line, if the agent gave one.
    public var error: String?
    /// The first run of the call that is going round.
    public var since: Date
    /// The latest run.
    public var last: Date
    var key: Int

    public var id: String { actor }

    /// For the closed notch: "failed 3x" or "4x, no edits".
    public var short: String { kind == .failing ? "failed \(count)x" : "\(count)x, no edits" }
    /// For the card: "failed 3x in a row" or "ran 4x with no edits".
    public var long: String { kind == .failing ? "failed \(count)x in a row" : "ran \(count)x with no edits" }
}

/// Watches hook agents' tool events for loops: the same call failing 3 times in
/// a row (reads in between don't count), or the same call 4 times with no edit
/// in between and its last run not a success. Everything is derived from the
/// events, per session (and per subagent), so a stuck warning clears by itself:
/// the call succeeds, the agent runs something else or edits a file, a new
/// prompt, Stop, SessionEnd, or the agent exits (`forget(keeping:)`). A
/// 15-minute timeout after the last failure is only a fallback. Each event is a
/// couple of dictionary lookups; nothing is kept once a session ends, and
/// command text stays in memory only.
public struct StuckWatch: Sendable {
    public static let failuresInARow = 3
    public static let repeatsWithoutEdit = 4
    /// For agents that don't say whether a call worked (Antigravity).
    public static let backToBackWithoutOutcome = 5
    /// Fallback only: a warning no event has touched for this long goes.
    public static let timeout: TimeInterval = 900
    /// Calls remembered per session between edits.
    static let maxCalls = 64

    private struct Seen: Sendable { var count: Int; var since: Date }

    private struct Actor: Sendable {
        var session: String
        var rowKey: Int?
        var row = 0
        var rowSince: Date?
        var calls: [Int: Seen] = [:]
        var ignored: Set<Int> = []
        var peeked: Set<Int> = []
        var stuck: Stuck?
    }

    private enum Outcome { case success, failure, unknown }

    private var actors: [String: Actor] = [:]
    /// Moves whenever a warning starts, changes, clears or is ignored, so the
    /// app republishes only then.
    public private(set) var generation = 0

    public init() {}

    /// Drops the actors `remove` picks; moves `generation` if one had a warning.
    private mutating func drop(where remove: (Actor) -> Bool) {
        guard actors.values.contains(where: remove) else { return }
        if actors.values.contains(where: { remove($0) && $0.stuck != nil }) { generation += 1 }
        actors = actors.filter { !remove($0.value) }
    }

    /// Counts one hook event; returns a warning when this event starts one that should peek.
    public mutating func record(_ message: HookMessage, agent: String, at now: Date) -> Stuck? {
        guard let session = message.sessionID else { return nil }
        let subagent = message.payload["agent_id"] as? String
        let id = session + "|" + (subagent ?? "")
        switch message.event {
        case "SessionStart" where message.payload["source"] as? String == "compact":
            // Claude Code compacting mid-turn: the same turn goes on.
            return nil
        case "UserPromptSubmit", "SessionStart", "Stop", "SessionEnd":
            // A new turn or the end of one: everything starts over, subagents included.
            drop { $0.session == session }
            return nil
        case "SubagentStop":
            if actors[id]?.stuck != nil { generation += 1 }
            actors[id] = nil
            return nil
        case "PreToolUse":
            guard let tool = message.toolName, !Self.isNeutral(tool) else { return nil }
            let key = Self.key(tool: tool, input: message.toolInput)
            var actor = actors[id] ?? Actor(session: session)
            if actor.rowKey != key { actor.rowKey = key; actor.row = 0; actor.rowSince = nil }
            // Running something else is moving on.
            if let stuck = actor.stuck, stuck.key != key { actor.stuck = nil; generation += 1 }
            if actor.calls[key] == nil, actor.calls.count >= Self.maxCalls { actor.calls.removeAll() }
            actor.calls[key, default: Seen(count: 0, since: now)].count += 1
            actors[id] = actor
            return nil
        case "PostToolUse", "PostToolUseFailure":
            guard let tool = message.toolName, !Self.isNeutral(tool) else { return nil }
            let outcome = Self.outcome(message)
            // A change that went through is progress: start over, for the
            // session's main agent too when a subagent made it.
            if Self.isEdit(tool), outcome != .failure {
                let main = session + "|"
                if actors[id]?.stuck != nil || (id != main && actors[main]?.stuck != nil) { generation += 1 }
                actors[id] = Actor(session: session)
                if id != main, actors[main] != nil { actors[main] = Actor(session: session) }
                return nil
            }
            let input = message.toolInput
            let key = Self.key(tool: tool, input: input)
            var actor = actors[id] ?? Actor(session: session)
            defer { actors[id] = actor }
            switch outcome {
            case .success:
                if actor.rowKey == key { actor.row = 0; actor.rowSince = nil }
                actor.calls[key] = nil
                // It worked: Ignore is over, and a new loop may peek again.
                actor.ignored.remove(key)
                actor.peeked.remove(key)
                if actor.stuck?.key == key { actor.stuck = nil; generation += 1 }
                return nil
            case .failure, .unknown:
                if actor.rowKey != key { actor.rowKey = key; actor.row = 0; actor.rowSince = nil }
                actor.row += 1
                if actor.rowSince == nil { actor.rowSince = now }
            }
            let seen = actor.calls[key]
            let kind: Stuck.Kind, count: Int, since: Date
            if outcome == .failure, actor.row >= Self.failuresInARow {
                (kind, count, since) = (.failing, actor.row, actor.rowSince ?? now)
            } else if outcome == .unknown {
                // No outcome to go on (Antigravity): only back-to-back runs, five of them,
                // so polling a build or a server with other calls between is no loop.
                guard actor.row >= Self.backToBackWithoutOutcome else { return nil }
                (kind, count, since) = (.looping, actor.row, actor.rowSince ?? now)
            } else if let seen, seen.count >= Self.repeatsWithoutEdit {
                (kind, count, since) = (.looping, seen.count, seen.since)
            } else {
                return nil
            }
            let error = outcome == .failure ? Self.errorLine(Self.errorText(message)) : nil
            actor.stuck = Stuck(session: session, actor: id, agent: agent, label: Self.label(tool: tool, input: input), kind: kind,
                                count: count, error: error, since: since, last: now, key: key)
            generation += 1
            guard !actor.ignored.contains(key), actor.peeked.insert(key).inserted else { return nil }
            return actor.stuck
        default:
            return nil
        }
    }

    /// Warnings still standing, newest first.
    public func active(at now: Date) -> [Stuck] {
        actors.values.compactMap { actor in
            actor.stuck.flatMap { !actor.ignored.contains($0.key) && now.timeIntervalSince($0.last) <= Self.timeout ? $0 : nil }
        }
        .sorted { $0.last > $1.last }
    }

    /// When the next warning times out, for one wake-up then (no polling).
    public func nextChange(after now: Date) -> Date? {
        active(at: now).map { $0.last.addingTimeInterval(Self.timeout) }.min()
    }

    /// Hides a warning until the agent makes progress.
    public mutating func ignore(_ stuck: Stuck) {
        guard actors[stuck.actor]?.ignored.insert(stuck.key).inserted == true else { return }
        generation += 1
    }

    /// Drops every session not in `sessions` (their agents exited).
    public mutating func forget(keeping sessions: Set<String>) {
        drop { !sessions.contains($0.session) }
    }

    var actorCount: Int { actors.count }
    func repeatCount(actor: String) -> Int { actors[actor]?.calls.count ?? 0 }

    // MARK: Reading events

    /// Reading, searching and planning: neither a step forward nor a different attempt.
    static let neutralTools: Set<String> = ["read", "grep", "glob", "ls", "view", "todowrite", "notebookread"]
    static let editTools: Set<String> = ["edit", "str_replace_editor", "replace", "multiedit", "write", "create", "write_file", "notebookedit"]

    static func isNeutral(_ tool: String) -> Bool { neutralTools.contains(tool.lowercased()) }
    static func isEdit(_ tool: String) -> Bool { editTools.contains(tool.lowercased()) }

    /// The part of the input that makes two calls the same.
    private static func subject(_ input: [String: Any]) -> String {
        if let known = knownSubject(input) { return known }
        // Task, MCP and other tools: the whole input, keys sorted, so different calls differ.
        guard !input.isEmpty, JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func knownSubject(_ input: [String: Any]) -> String? {
        for field in ["command", "file_path", "path", "pattern", "url", "query"] {
            if let value = input[field] as? String { return value }
        }
        return nil
    }

    static func key(tool: String, input: [String: Any]) -> Int {
        var hasher = Hasher()
        hasher.combine(tool.lowercased())
        hasher.combine(subject(input))
        return hasher.finalize()
    }

    /// Claude Code and Copilot report failures; Copilot may also mark a
    /// `postToolUse` as one. Antigravity says nothing about the outcome.
    private static func outcome(_ message: HookMessage) -> Outcome {
        if message.event == "PostToolUseFailure" { return .failure }
        if let result = message.payload["toolResult"] as? [String: Any], result["resultType"] as? String == "failure" { return .failure }
        return message.provider == "antigravity" ? .unknown : .success
    }

    private static func errorText(_ message: HookMessage) -> String? {
        if let error = message.payload["error"] as? String { return error }
        return (message.payload["toolResult"] as? [String: Any])?["textResultForLlm"] as? String
    }

    /// The first non-empty line, at most 120 characters; a key in it reads as its kind.
    static func errorLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in KeyShapes.redacted(text).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        }
        return nil
    }

    /// What the card names: the command's first line (at most 60 characters), or the tool and file name.
    /// A key reads as its kind, before the cut (display only: `key` tells calls apart).
    static func label(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String {
            let first = KeyShapes.redacted(command).split(whereSeparator: \.isNewline).first.map(String.init) ?? command
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
        }
        // Only the named fields: other input (a Task prompt, MCP arguments) is never shown.
        guard let subject = knownSubject(input), !subject.isEmpty else { return String(tool.prefix(60)) }
        let shown = KeyShapes.redacted(subject)
        let name = shown.contains("/") ? (shown as NSString).lastPathComponent : shown
        return String((tool + " " + name).prefix(60))
    }
}

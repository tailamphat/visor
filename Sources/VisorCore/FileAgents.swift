import Foundation

/// A session read from an agent's own files rather than from hooks (Codex CLI
/// rollouts, OpenCode's database): what the Agents tab shows, read-only.
public struct ScannedSession: Equatable, Sendable {
    public var id: String
    public var agent: String
    public var cwd: String
    public var state: AgentState
    /// The last thing the user asked it.
    public var task: String?
    /// When the user last sent it a prompt.
    public var turnStart: Date?
    /// The last time its file changed.
    public var lastActivity: Date
    /// The last finished turn ended by asking you something.
    public var askedForReply = false
    /// The agent's process when one runs in `cwd` (set by `FileAgents.visible`).
    public var pid: Int32 = 0

    public init(id: String, agent: String, cwd: String, state: AgentState, task: String? = nil,
                turnStart: Date? = nil, lastActivity: Date, askedForReply: Bool = false) {
        self.id = id; self.agent = agent; self.cwd = cwd; self.state = state; self.task = task
        self.turnStart = turnStart; self.lastActivity = lastActivity; self.askedForReply = askedForReply
    }
}

public enum FileAgents {
    /// How long a working session with no file change still shows (a long command writes nothing).
    public static let activeWindow: TimeInterval = 30 * 60
    /// How long a finished or idle session still shows.
    public static let recentWindow: TimeInterval = 10 * 60

    /// The sessions to show. A session a live process has open (`pinned`, by
    /// id) shows with that pid; so does the newest in each folder where the
    /// agent's process runs (`live`, by folder). Any other working session
    /// shows for 30 minutes after its file last changed, and the rest for 10.
    /// Older sessions never fill the tab.
    public static func visible(_ sessions: [ScannedSession], live: [String: Int32], pinned: [String: Int32] = [:],
                               now: Date) -> [ScannedSession] {
        var newest: [String: String] = [:]
        let pinnedFolders = Set(sessions.filter { pinned[$0.id] != nil }.map(\.cwd))
        for session in sessions.sorted(by: { $0.lastActivity > $1.lastActivity })
        where live[session.cwd] != nil && !pinnedFolders.contains(session.cwd) && newest[session.cwd] == nil {
            newest[session.cwd] = session.id
        }
        return sessions.compactMap { session in
            var session = session
            if let pid = pinned[session.id] ?? (newest[session.cwd] == session.id ? live[session.cwd] : nil) {
                session.pid = pid
                return session
            }
            let age = now.timeIntervalSince(session.lastActivity)
            return age <= (session.state.isWorking ? activeWindow : recentWindow) ? session : nil
        }
    }

    /// A file path's last part, for "Edit: total.ts".
    static func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }
}

/// Remembers, for one agent, which sessions had a live process: once that
/// process is gone (Ctrl-C, closed terminal) its session stays hidden until its
/// file changes again, instead of coming back pid-less as "recent".
public struct FileAgentTracker: Sendable {
    private var withPid: [String: Date] = [:]
    private var ended: [String: Date] = [:]

    public init() {}

    public mutating func shown(_ sessions: [ScannedSession], live: [String: Int32], pinned: [String: Int32] = [:],
                               now: Date) -> [ScannedSession] {
        var next: [String: Date] = [:]
        let out = FileAgents.visible(sessions, live: live, pinned: pinned, now: now).filter { session in
            if session.pid > 0 {
                next[session.id] = session.lastActivity
                ended[session.id] = nil
                return true
            }
            if let last = withPid[session.id] { ended[session.id] = max(last, ended[session.id] ?? last) }
            guard let mark = ended[session.id] else { return true }
            guard session.lastActivity > mark else { return false }
            ended[session.id] = nil
            return true
        }
        let known = Set(sessions.map(\.id))
        ended = ended.filter { known.contains($0.key) }
        withPid = next
        return out
    }
}

extension AgentState {
    var isWorking: Bool {
        switch self {
        case .working, .needsApproval, .asking, .needsInput: return true
        case .idle, .done: return false
        }
    }
}

// MARK: Codex CLI

/// Reads one Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) a
/// piece at a time, like `TokenLedger.CodexReader`: rollouts only grow, so each
/// read takes the complete lines added since the last one. Field names follow
/// Codex's rollout format (`session_meta`, `turn_context`, `response_item`,
/// `event_msg`); not verified against a live Codex run.
public struct CodexRollout: Sendable {
    /// Bytes consumed so far (complete lines only).
    public private(set) var offset: UInt64 = 0
    private var id: String?
    private var cwd = ""
    private var state = AgentState.idle
    private var task: String?
    private var turnStart: Date?
    private var lastActivity: Date?
    private var askedForReply = false

    /// `id`: used until the rollout's `session_meta` names the session (the file name).
    public init(id: String? = nil) {
        self.id = id
    }

    public var session: ScannedSession? {
        guard let id, let lastActivity else { return nil }
        return ScannedSession(id: id, agent: "Codex CLI", cwd: cwd, state: state, task: task, turnStart: turnStart,
                              lastActivity: lastActivity, askedForReply: askedForReply)
    }

    /// Reads the complete lines of `data`, which starts at `offset`; a half-written last line waits.
    public mutating func read(_ data: Data) {
        let end = data.last == 0x0A ? data.endIndex : (data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex)
        offset += UInt64(end - data.startIndex)
        TokenLedger.forEachLine(data[data.startIndex..<end]) { take($0) }
    }

    private mutating func take(_ object: [String: Any]) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        let stamp = (object["timestamp"] as? String).flatMap(ISODate.parse)
        if let stamp { lastActivity = max(lastActivity ?? stamp, stamp) }
        switch object["type"] as? String {
        case "session_meta":
            if let value = payload["id"] as? String, !value.isEmpty { id = value }
            if let value = payload["cwd"] as? String, !value.isEmpty { cwd = value }
        case "turn_context":
            if let value = payload["cwd"] as? String, !value.isEmpty { cwd = value }
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message":
                if let text = payload["message"] as? String, let summary = AgentBoard.summarize(text) { task = summary }
                turnStart = stamp ?? turnStart
                state = .working("Thinking")
            case "task_started":
                if !state.isWorking { state = .working("Thinking") }
            case "task_complete":
                askedForReply = AgentBoard.asksForReply(payload["last_agent_message"] as? String ?? "")
                state = .done
            case "turn_aborted":
                state = .idle
            default: break
            }
        case "response_item":
            switch payload["type"] as? String {
            case "function_call":
                let arguments = (payload["arguments"] as? String).flatMap { Data($0.utf8).jsonObject } ?? [:]
                state = .working(Self.describe(name: payload["name"] as? String ?? "tool", arguments: arguments))
            case "custom_tool_call":
                state = .working(Self.describe(name: payload["name"] as? String ?? "tool", arguments: ["input": payload["input"] ?? ""]))
            case "local_shell_call":
                let action = payload["action"] as? [String: Any] ?? [:]
                state = .working(Self.describe(name: "local_shell", arguments: action))
            case "web_search_call":
                let action = payload["action"] as? [String: Any] ?? [:]
                state = .working(AgentBoard.describe(tool: "WebSearch", input: action))
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                if state.isWorking { state = .working("Thinking") }
            default: break
            }
        default: break
        }
    }

    /// A Codex tool call in the words the other agents use: "Bash: go test ./...", "Edit: total.ts".
    public static func describe(name: String, arguments: [String: Any]) -> String {
        switch name {
        case "shell", "local_shell", "container.exec", "exec_command":
            let command: String?
            if let parts = arguments["command"] as? [String] {
                // ["bash", "-lc", "go test ./..."] runs its last argument.
                command = parts.count == 3 && parts[1].hasPrefix("-") && parts[1].hasSuffix("c") ? parts[2] : parts.joined(separator: " ")
            } else {
                command = (arguments["cmd"] as? String) ?? (arguments["command"] as? String)
            }
            return AgentBoard.describe(tool: "Bash", input: command.map { ["command": $0] } ?? [:])
        case "apply_patch":
            let patch = (arguments["input"] as? String) ?? (arguments["patch"] as? String) ?? ""
            for line in patch.split(whereSeparator: \.isNewline) {
                for (marker, tool) in [("*** Update File: ", "Edit"), ("*** Add File: ", "Write"), ("*** Delete File: ", "Edit")]
                where line.hasPrefix(marker) {
                    return AgentBoard.describe(tool: tool, input: ["file_path": String(line.dropFirst(marker.count))])
                }
            }
            return "Edit"
        default:
            return name
        }
    }
}

private extension Data {
    var jsonObject: [String: Any]? { (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] }
}

// MARK: OpenCode

/// OpenCode sessions from its SQLite database (`opencode.db`), read with
/// `sqlite3 -json` on a read-only connection: each top-level session changed
/// lately, with its newest message and newest part.
public enum OpenCodeSessions {
    /// Only the fields shown are pulled out of the JSON columns, so tool output
    /// and file contents never leave the database.
    /// `directories`: folders where OpenCode runs now; each one's newest
    /// session is read too, however old (an open but idle OpenCode).
    public static func query(since: Date, directories: [String] = []) -> String {
        let ms = Int64(since.timeIntervalSince1970 * 1000)
        let newest = directories.sorted().map { dir in
            "s.id = (SELECT n.id FROM session n WHERE n.directory = '\(dir.replacingOccurrences(of: "'", with: "''"))' "
                + "AND n.parent_id IS NULL AND n.time_archived IS NULL ORDER BY n.time_updated DESC LIMIT 1)"
        }
        let recent = (["s.time_updated >= \(ms)"] + newest).joined(separator: " OR ")
        let message = "(SELECT m.data FROM message m WHERE m.session_id = s.id ORDER BY m.time_created DESC, m.id DESC LIMIT 1)"
        let part = "(SELECT p.data FROM part p WHERE p.session_id = s.id ORDER BY p.time_created DESC, p.id DESC LIMIT 1)"
        let input = ["filePath", "command", "description", "pattern", "url", "query"]
            .map { "'\($0)', json_extract(p.data, '$.state.input.\($0)')" }.joined(separator: ", ")
        return """
        SELECT s.id AS id, s.directory AS directory, s.title AS title, s.time_updated AS updated, \
        s.parent_id AS parent, s.time_archived AS archived, \
        (SELECT m.time_created FROM message m WHERE m.session_id = s.id AND json_extract(m.data, '$.role') = 'user' \
        ORDER BY m.time_created DESC LIMIT 1) AS prompted, \
        json_extract(\(message), '$.role') AS role, json_extract(\(message), '$.time.completed') AS completed, \
        json_extract(\(message), '$.finish') AS finish, json_extract(\(message), '$.error.name') AS error, \
        (SELECT json_extract(p.data, '$.type') FROM part p WHERE p.session_id = s.id ORDER BY p.time_created DESC, p.id DESC LIMIT 1) AS ptype, \
        json_extract(\(part), '$.tool') AS tool, json_extract(\(part), '$.state.status') AS status, \
        (SELECT json_object(\(input)) FROM part p WHERE p.session_id = s.id ORDER BY p.time_created DESC, p.id DESC LIMIT 1) AS input, \
        (SELECT substr(json_extract(p.data, '$.text'), -200) FROM part p WHERE p.session_id = s.id \
        AND json_extract(p.data, '$.type') = 'text' ORDER BY p.time_created DESC, p.id DESC LIMIT 1) AS text \
        FROM session s WHERE s.parent_id IS NULL AND s.time_archived IS NULL AND (\(recent)) \
        ORDER BY s.time_updated DESC LIMIT \(20 + directories.count)
        """
    }

    /// The rows of `query`; nil when the output isn't a JSON array. sqlite3 prints nothing for no rows.
    public static func parse(_ data: Data) -> [ScannedSession]? {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A }) { return [] }
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return rows.compactMap(session)
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    private static func session(_ row: [String: Any]) -> ScannedSession? {
        guard let id = row["id"] as? String, row["parent"] as? String == nil, row["archived"] as? NSNumber == nil,
              let updated = date(row["updated"]) else { return nil }
        let running = ["running", "pending"].contains(row["status"] as? String ?? "")
        let input = (row["input"] as? String).flatMap { Data($0.utf8).jsonObject } ?? [:]
        let state: AgentState
        var asked = false
        if row["role"] as? String == "user" {
            state = .working("Thinking")
        } else if row["ptype"] as? String == "tool", running, let tool = row["tool"] as? String {
            state = tool == "question" ? .asking("Question") : .working(describe(tool: tool, input: input))
        } else if row["completed"] == nil || row["completed"] is NSNull {
            state = .working("Thinking")
        } else if row["error"] as? String != nil {
            state = .idle
        } else if row["finish"] as? String == "tool-calls" {
            state = .working("Thinking")
        } else {
            asked = AgentBoard.asksForReply(row["text"] as? String ?? "")
            state = .done
        }
        let title = (row["title"] as? String).flatMap(AgentBoard.summarize)
        return ScannedSession(id: id, agent: "OpenCode", cwd: row["directory"] as? String ?? "", state: state, task: title,
                              turnStart: date(row["prompted"]), lastActivity: updated, askedForReply: asked)
    }

    /// OpenCode's lower-case tools and camelCase inputs, in the words the other agents use.
    public static func describe(tool: String, input: [String: Any]) -> String {
        let names = ["bash": "Bash", "read": "Read", "edit": "Edit", "write": "Write", "glob": "Glob", "grep": "Grep",
                     "webfetch": "WebFetch", "websearch": "WebSearch", "task": "Task", "patch": "Edit", "multiedit": "MultiEdit"]
        guard let name = names[tool] else { return tool }
        var mapped = input
        if let path = input["filePath"] as? String { mapped["file_path"] = path }
        return AgentBoard.describe(tool: name, input: mapped)
    }
}

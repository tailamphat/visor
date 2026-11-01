import Foundation

/// One message from the hook script: a Claude Code hook event plus its JSON input.
public struct HookMessage: @unchecked Sendable {
    public var event: String
    /// The Claude Code process that ran the hook.
    public var pid: Int32
    /// The hook script's own process; it exits when Claude Code stops waiting on it.
    public var hookPID: Int32 = 0
    public var payload: [String: Any]

    public init(event: String, pid: Int32, payload: [String: Any]) {
        self.event = event
        self.pid = pid
        self.payload = payload
    }

    /// The agent that sent it: "claude" or "copilot".
    public var provider = "claude"

    /// Parses one line written by agent-hook.sh: {"event":..,"provider":..,"pid":..,"raw":{...}}.
    public static func parse(_ line: Data) -> HookMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        let pid = (object["pid"] as? NSNumber)?.int32Value ?? 0
        let raw = object["raw"] as? [String: Any] ?? [:]
        let provider = object["provider"] as? String ?? "claude"
        var message = provider == "copilot"
            ? HookMessage(event: copilotEvents[event] ?? event, pid: pid, payload: copilotPayload(raw))
            : HookMessage(event: event, pid: pid, payload: raw)
        message.provider = provider
        message.hookPID = (object["hpid"] as? NSNumber)?.int32Value ?? 0
        return message
    }

    /// Copilot CLI's camelCase hook names, as the Claude Code names the board understands.
    static let copilotEvents = [
        "sessionStart": "SessionStart", "sessionEnd": "SessionEnd", "userPromptSubmitted": "UserPromptSubmit",
        "preToolUse": "PreToolUse", "postToolUse": "PostToolUse", "postToolUseFailure": "PostToolUseFailure",
        "agentStop": "Stop", "notification": "Notification", "permissionRequest": "PermissionRequest",
    ]

    static let copilotTools = [
        "bash": "Bash", "shell": "Bash", "powershell": "Bash", "edit": "Edit", "create": "Write",
        "web_fetch": "WebFetch", "view": "Read", "grep": "Grep", "glob": "Glob", "task": "Task",
    ]

    /// Copilot's camelCase fields as Claude Code's snake_case ones; Copilot's
    /// own notification types mapped too ("agent_idle" means waiting for you).
    static func copilotPayload(_ raw: [String: Any]) -> [String: Any] {
        var out = raw
        let renames = ["sessionId": "session_id", "toolName": "tool_name", "toolArgs": "tool_input", "toolInput": "tool_input"]
        for (from, to) in renames where out[to] == nil {
            if let value = raw[from] { out[to] = value }
        }
        // Copilot passes tool arguments as an object, but older builds sent a JSON string.
        if let text = out["tool_input"] as? String, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            out["tool_input"] = object
        }
        if let kind = out["notification_type"] as? String, kind == "agent_idle" { out["notification_type"] = "idle_prompt" }
        // Copilot's tools under Claude's names, so they read the same everywhere.
        if let tool = out["tool_name"] as? String, let claude = copilotTools[tool.lowercased()] { out["tool_name"] = claude }
        // Copilot calls a file "path"; Claude calls it "file_path".
        if var input = out["tool_input"] as? [String: Any], input["file_path"] == nil, let path = input["path"] {
            input["file_path"] = path
            out["tool_input"] = input
        }
        return out
    }

    public var sessionID: String? { payload["session_id"] as? String }
    public var cwd: String? { payload["cwd"] as? String }
    public var toolName: String? { payload["tool_name"] as? String }
    public var toolInput: [String: Any] { payload["tool_input"] as? [String: Any] ?? [:] }
}

public enum AgentState: Equatable, Sendable {
    case idle
    case working(String)
    case needsApproval(String)
    case needsInput
    case done
}

public struct AgentSession: Equatable, Sendable, Identifiable {
    public var id: String
    public var pid: Int32
    public var cwd: String
    public var state: AgentState
    /// When the current state began.
    public var since: Date
    public var lastEvent: Date
    /// Which agent this is, e.g. "Claude Code".
    public var agent = "Claude Code"
    /// The app it runs in (Ghostty, VS Code, ...), filled in by the app.
    public var host: String?
    /// The last thing the user asked it, to tell sessions in one project apart.
    public var task: String?

    public var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude" : name
    }

    public var isActive: Bool {
        switch state {
        case .working, .needsApproval, .needsInput: return true
        case .idle, .done: return false
        }
    }
}

/// Turns hook events into a list of Claude Code sessions and what each is doing.
public struct AgentBoard: Equatable, Sendable {
    public private(set) var sessions: [AgentSession] = []

    public init() {}

    public var working: Int { sessions.filter { if case .working = $0.state { return true } else { return false } }.count }
    public var waiting: Int {
        sessions.filter {
            switch $0.state { case .needsApproval, .needsInput: return true; default: return false }
        }.count
    }

    public mutating func apply(_ message: HookMessage, now: Date = Date()) {
        guard let id = message.sessionID else { return }
        if message.event == "SessionEnd" {
            sessions.removeAll { $0.id == id }
            return
        }
        let index: Int
        if let found = sessions.firstIndex(where: { $0.id == id }) {
            index = found
        } else {
            var session = AgentSession(id: id, pid: message.pid, cwd: message.cwd ?? "", state: .idle,
                                       since: now, lastEvent: now)
            session.agent = Self.agentName(message.provider)
            sessions.append(session)
            index = sessions.count - 1
        }
        if let cwd = message.cwd, !cwd.isEmpty { sessions[index].cwd = cwd }
        if message.pid > 0 { sessions[index].pid = message.pid }
        sessions[index].lastEvent = now

        let next: AgentState?
        switch message.event {
        case "SessionStart": next = .idle
        case "UserPromptSubmit":
            if let prompt = message.payload["prompt"] as? String { sessions[index].task = Self.summarize(prompt) }
            next = .working("Thinking")
        case "PreToolUse": next = .working(Self.describe(tool: message.toolName, input: message.toolInput))
        case "PostToolUse", "PostToolUseFailure", "SubagentStop": next = .working("Thinking")
        case "PermissionRequest": next = .needsApproval(Self.describe(tool: message.toolName, input: message.toolInput))
        case "Notification":
            let kind = message.payload["notification_type"] as? String ?? ""
            let text = (message.payload["message"] as? String ?? "").lowercased()
            if kind == "idle_prompt" || text.contains("waiting for your input") {
                next = .needsInput
            } else if kind == "permission_prompt" || text.contains("permission") {
                // Visor's own approval card already shows this when its hook asked.
                if case .needsApproval = sessions[index].state { next = nil } else { next = .needsApproval("Needs permission") }
            } else {
                next = nil
            }
        case "Stop": next = .done
        default: next = nil
        }
        if let next, next != sessions[index].state {
            sessions[index].state = next
            sessions[index].since = now
        }
    }

    /// The user answered an approval; the agent carries on.
    public mutating func resolveApproval(session id: String, now: Date = Date()) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), case .needsApproval = sessions[i].state else { return }
        sessions[i].state = .working("Thinking")
        sessions[i].since = now
    }

    /// Drops sessions whose Claude Code process has exited.
    public mutating func prune(isAlive: (Int32) -> Bool) {
        sessions.removeAll { $0.pid > 0 && !isAlive($0.pid) }
    }

    public static func agentName(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude Code"
        case "copilot": return "Copilot CLI"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// Agents with something going on, in the order the closed notch shows them:
    /// anyone waiting for you first, then Claude Code before Copilot CLI.
    public var activeAgents: [(agent: String, count: Int, waiting: Bool)] {
        var groups: [String: (count: Int, waiting: Bool)] = [:]
        for session in sessions where session.isActive {
            var group = groups[session.agent] ?? (0, false)
            group.count += 1
            switch session.state {
            case .needsApproval, .needsInput: group.waiting = true
            default: break
            }
            groups[session.agent] = group
        }
        let order = ["Claude Code": 0, "Copilot CLI": 1]
        return groups.map { ($0.key, $0.value.count, $0.value.waiting) }
            .sorted { a, b in
                a.waiting != b.waiting ? a.waiting : (order[a.agent] ?? 9, a.agent) < (order[b.agent] ?? 9, b.agent)
            }
    }

    /// The first line of a prompt, short enough for one row.
    public static func summarize(_ prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// Records the app a session runs in.
    public mutating func setHost(_ host: String?, session id: String) {
        guard let host, let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].host != host else { return }
        sessions[i].host = host
    }

    /// A short, human description of a tool call, e.g. "Bash: npm test".
    public static func describe(tool: String?, input: [String: Any]) -> String {
        guard let tool else { return "Working" }
        func first(_ keys: String...) -> String? {
            for key in keys { if let v = input[key] as? String, !v.isEmpty { return v } }
            return nil
        }
        let detail: String?
        switch tool {
        case "Bash": detail = first("description", "command")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            detail = first("file_path", "notebook_path").map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob": detail = first("pattern")
        case "WebFetch": detail = first("url").flatMap { URL(string: $0)?.host }
        case "WebSearch": detail = first("query")
        case "Task", "Agent": detail = first("description")
        default: detail = nil
        }
        guard let detail else { return tool }
        let line = detail.split(separator: "\n").first.map(String.init) ?? detail
        return "\(tool): \(line.count > 60 ? String(line.prefix(59)) + "…" : line)"
    }
}

/// A Claude Code PermissionRequest waiting for the user to allow or deny it.
public struct ApprovalRequest: Identifiable, @unchecked Sendable {
    public let id = UUID()
    /// "claude" or "copilot": who is asking, and which reply format it expects.
    public var provider = "claude"
    public var sessionID: String
    public var project: String
    public var tool: String
    /// The part worth reading before deciding: the command, file, or URL.
    public var preview: String
    /// Rules Claude Code offers for "always allow"; echoed back as updatedPermissions.
    public var suggestions: [Any]

    /// The session's working directory: which project an always-allow rule belongs to.
    public var cwd: String

    public init?(_ message: HookMessage) {
        guard message.event == "PermissionRequest", let session = message.sessionID else { return nil }
        provider = message.provider
        cwd = message.cwd ?? ""
        sessionID = session
        project = ((message.cwd ?? "") as NSString).lastPathComponent
        tool = message.toolName ?? "Tool"
        let input = message.toolInput
        let keys = ["command", "file_path", "url", "pattern", "query", "description", "prompt"]
        if let value = keys.lazy.compactMap({ input[$0] as? String }).first {
            preview = value
        } else if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) {
            preview = text
        } else {
            preview = ""
        }
        suggestions = message.payload["permission_suggestions"] as? [Any] ?? []
    }

    /// What the agent wants to do, in plain words: "run a command", "edit a file".
    public var action: String {
        switch tool {
        case "Bash": return "run a command"
        case "Edit", "MultiEdit", "NotebookEdit": return "edit a file"
        case "Write": return "create a file"
        case "Read": return "read a file"
        case "WebFetch": return "fetch a web page"
        case "WebSearch": return "search the web"
        case "Task", "Agent": return "start a subagent"
        default: return "use \(tool)"
        }
    }

    /// What "Always allow" will allow, from Claude Code's suggested rule:
    /// "git push" for Bash(git push:*), "edits" when it offers to accept edits.
    public var alwaysAllowLabel: String? {
        if provider == "copilot" { return CopilotRules.Rule(for: self).label }
        guard !suggestions.isEmpty else { return nil }
        for case let suggestion as [String: Any] in suggestions {
            if suggestion["type"] as? String == "setMode", suggestion["mode"] as? String == "acceptEdits" { return "edits" }
            for case let rule as [String: Any] in suggestion["rules"] as? [Any] ?? [] {
                guard var content = rule["ruleContent"] as? String, !content.isEmpty else { continue }
                if content.hasSuffix(":*") { content.removeLast(2) }
                if content.hasSuffix("/**") { content = (content.dropLast(3) as Substring).description + "/" }
                return content.count > 28 ? String(content.prefix(27)) + "…" : content
            }
        }
        return tool
    }

    public enum Decision: Sendable { case allow, allowAlways, deny }

    /// The JSON line the hook prints back to Claude Code.
    public func reply(_ decision: Decision) -> Data {
        if provider == "copilot" {
            // Copilot's permissionRequest output; "always" is remembered by Visor.
            let body: [String: Any] = decision == .deny
                ? ["behavior": "deny", "message": "Denied from Visor."] : ["behavior": "allow"]
            var data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            data.append(0x0A)
            return data
        }
        var body: [String: Any]
        switch decision {
        case .allow: body = ["behavior": "allow"]
        case .allowAlways: body = ["behavior": "allow", "updatedPermissions": suggestions]
        case .deny: body = ["behavior": "deny", "message": "Denied from Visor."]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        var data = (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// Which held approvals a session's next event makes moot.
public enum ApprovalRelease: Equatable, Sendable {
    /// Every approval the session holds (it moved on: new prompt, idle, stop).
    case all
    /// Approvals for this tool (it ran or failed, so it was answered elsewhere).
    case tool(String)

    public static func after(_ message: HookMessage) -> ApprovalRelease? {
        guard message.sessionID != nil else { return nil }
        switch message.event {
        case "UserPromptSubmit", "Stop", "SessionEnd":
            return .all
        case "PostToolUse", "PostToolUseFailure":
            return message.toolName.map(ApprovalRelease.tool) ?? .all
        case "Notification" where message.payload["notification_type"] as? String == "idle_prompt":
            return .all
        default:
            return nil
        }
    }
}

/// What the closed notch shows for agents: at most two marks, then "+N".
public struct NotchMarks: Equatable, Sendable {
    public struct Mark: Equatable, Sendable {
        public var agent: String
        public var count: Int
        public var waiting: Bool

        public init(agent: String, count: Int, waiting: Bool) {
            self.agent = agent
            self.count = count
            self.waiting = waiting
        }
    }
    public var shown: [Mark]
    /// Agents folded into the "+N" chip.
    public var more: [String]

    /// Waiting agents come first in `activeAgents`, so they always get a slot.
    public static func make(_ board: AgentBoard, pendingApproval: Bool) -> NotchMarks {
        var agents = board.activeAgents.map { Mark(agent: $0.agent, count: $0.count, waiting: $0.waiting) }
        // An open approval card is Claude Code waiting for you.
        if pendingApproval, let i = agents.firstIndex(where: { $0.agent == "Claude Code" }), !agents[i].waiting {
            var claude = agents.remove(at: i)
            claude.waiting = true
            agents.insert(claude, at: 0)
        }
        return NotchMarks(shown: Array(agents.prefix(2)), more: agents.dropFirst(2).map(\.agent))
    }

    /// Width of each side of the closed notch: both widen together so it stays centred.
    public static func earWidth(agents: Int) -> Double {
        agents >= 3 ? 84 : agents == 2 ? 62 : 38
    }
}


/// Copilot CLI "always allow" rules. Copilot's hooks can't save rules, so
/// Visor keeps them, per project, like Claude Code's own rules.
public struct CopilotRules: Codable, Equatable, Sendable {
    public struct Rule: Codable, Equatable, Sendable {
        public var project: String
        /// "command", "edits", "web", or another tool's name.
        public var kind: String
        /// The command's first word, the site, or "*" for any.
        public var match: String

        public init(for request: ApprovalRequest) {
            project = request.cwd
            switch request.tool {
            case "Bash":
                kind = "command"
                match = request.preview.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "*"
            case "Edit", "Write", "MultiEdit":
                kind = "edits"
                match = "*"
            case "WebFetch":
                kind = "web"
                match = URL(string: request.preview)?.host ?? "*"
            default:
                kind = request.tool
                match = "*"
            }
        }

        /// What the "Always" button names: "npm", "edits", "docs.github.com".
        public var label: String {
            switch kind {
            case "edits": return "edits"
            default: return match == "*" ? kind : match
            }
        }
    }

    public var rules: [Rule] = []

    public init() {}

    public mutating func add(for request: ApprovalRequest) {
        let rule = Rule(for: request)
        if !rules.contains(rule) { rules.append(rule) }
    }

    public func allows(_ request: ApprovalRequest) -> Bool {
        let wanted = Rule(for: request)
        return rules.contains { $0.project == wanted.project && $0.kind == wanted.kind && ($0.match == "*" || $0.match == wanted.match) }
    }
}

extension AgentBoard {
    /// Whether anything shown in the notch differs. The last-event time moves
    /// on every tool call but is never shown, so it alone doesn't count.
    public func differsVisibly(from other: AgentBoard) -> Bool {
        guard sessions.count == other.sessions.count else { return true }
        return zip(sessions, other.sessions).contains { a, b in
            a.id != b.id || a.cwd != b.cwd || a.state != b.state || a.since != b.since
                || a.agent != b.agent || a.host != b.host || a.task != b.task
        }
    }
}

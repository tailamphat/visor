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

    /// Parses one line written by agent-hook.sh: {"event":..,"pid":..,"raw":{...}}.
    public static func parse(_ line: Data) -> HookMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        let pid = (object["pid"] as? NSNumber)?.int32Value ?? 0
        let raw = object["raw"] as? [String: Any] ?? [:]
        var message = HookMessage(event: event, pid: pid, payload: raw)
        message.hookPID = (object["hpid"] as? NSNumber)?.int32Value ?? 0
        return message
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
            sessions.append(AgentSession(id: id, pid: message.pid, cwd: message.cwd ?? "", state: .idle,
                                         since: now, lastEvent: now))
            index = sessions.count - 1
        }
        if let cwd = message.cwd, !cwd.isEmpty { sessions[index].cwd = cwd }
        if message.pid > 0 { sessions[index].pid = message.pid }
        sessions[index].lastEvent = now

        let next: AgentState?
        switch message.event {
        case "SessionStart": next = .idle
        case "UserPromptSubmit": next = .working("Thinking")
        case "PreToolUse": next = .working(Self.describe(tool: message.toolName, input: message.toolInput))
        case "PostToolUse", "PostToolUseFailure", "SubagentStop": next = .working("Thinking")
        case "PermissionRequest": next = .needsApproval(Self.describe(tool: message.toolName, input: message.toolInput))
        case "Notification":
            let kind = message.payload["notification_type"] as? String ?? ""
            let text = (message.payload["message"] as? String ?? "").lowercased()
            if kind == "idle_prompt" || text.contains("waiting for your input") {
                next = .needsInput
            } else if kind == "permission_prompt" || text.contains("permission") {
                // Notchboard's own approval card already shows this when its hook asked.
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
    public var sessionID: String
    public var project: String
    public var tool: String
    /// The part worth reading before deciding: the command, file, or URL.
    public var preview: String
    /// Rules Claude Code offers for "always allow"; echoed back as updatedPermissions.
    public var suggestions: [Any]

    public init?(_ message: HookMessage) {
        guard message.event == "PermissionRequest", let session = message.sessionID else { return nil }
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

    public enum Decision: Sendable { case allow, allowAlways, deny }

    /// The JSON line the hook prints back to Claude Code.
    public func reply(_ decision: Decision) -> Data {
        var body: [String: Any]
        switch decision {
        case .allow: body = ["behavior": "allow"]
        case .allowAlways: body = ["behavior": "allow", "updatedPermissions": suggestions]
        case .deny: body = ["behavior": "deny", "message": "Denied from Notchboard."]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        var data = (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
        data.append(0x0A)
        return data
    }
}

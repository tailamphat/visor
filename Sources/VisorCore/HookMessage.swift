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

    /// The agent that sent it: "claude", "copilot" or "antigravity".
    public var provider = "claude"

    /// Parses one line written by agent-hook.sh: {"event":..,"provider":..,"pid":..,"raw":{...}}.
    public static func parse(_ line: Data) -> HookMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        let pid = (object["pid"] as? NSNumber)?.int32Value ?? 0
        let raw = object["raw"] as? [String: Any] ?? [:]
        let provider = object["provider"] as? String ?? "claude"
        var message: HookMessage
        switch provider {
        case "copilot":
            message = HookMessage(event: copilotEvents[event] ?? event, pid: pid, payload: copilotPayload(raw))
        case "antigravity":
            message = HookMessage(event: antigravityEvent(event, raw), pid: pid, payload: antigravityPayload(raw))
        default:
            message = HookMessage(event: event, pid: pid, payload: raw)
        }
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

    /// Antigravity calls PreInvocation before every model call; only the first
    /// call of a turn starts from a new prompt.
    static func antigravityEvent(_ event: String, _ raw: [String: Any]) -> String {
        guard event == "PreInvocation" else { return event }
        let invocation = (raw["invocationNum"] as? NSNumber)?.intValue ?? 0
        return invocation == 0 ? "UserPromptSubmit" : "PreInvocation"
    }

    static let antigravityTools = [
        "run_command": "Bash", "read_file": "Read", "view_file": "Read", "write_file": "Write",
        "replace_file_content": "Edit", "multi_replace_file_content": "MultiEdit",
        "grep_search": "Grep", "find_by_name": "Glob", "list_directory": "LS",
    ]

    /// Antigravity's payload fields as Claude Code's, and its tools under the
    /// names the board already describes.
    static func antigravityPayload(_ raw: [String: Any]) -> [String: Any] {
        var out = raw
        if out["session_id"] == nil { out["session_id"] = raw["conversationId"] }
        if out["cwd"] == nil, let paths = raw["workspacePaths"] as? [String], let first = paths.first {
            out["cwd"] = first
        }
        if out["prompt"] == nil { out["prompt"] = raw["lastUserInput"] }
        guard let call = raw["toolCall"] as? [String: Any] else { return out }
        let name = call["name"] as? String ?? ""
        let args = call["args"] as? [String: Any] ?? [:]
        out["tool_name"] = antigravityTools[name] ?? name
        func string(_ keys: String...) -> String {
            for key in keys { if let value = args[key] as? String { return value } }
            return ""
        }
        switch name {
        case "run_command":
            out["tool_input"] = ["command": string("CommandLine", "command"), "description": string("toolSummary", "description")]
        case "read_file", "view_file":
            out["tool_input"] = ["file_path": string("Path", "AbsolutePath", "path")]
        case "write_file":
            out["tool_input"] = ["file_path": string("Path", "path"), "content": string("Content", "content")]
        case "replace_file_content", "multi_replace_file_content":
            out["tool_input"] = ["file_path": string("Path", "TargetFile", "path")]
        case "grep_search":
            out["tool_input"] = ["pattern": string("Query", "query", "Pattern", "pattern")]
        case "find_by_name":
            out["tool_input"] = ["pattern": string("Pattern", "pattern", "Name", "name")]
        default:
            out["tool_input"] = args
        }
        return out
    }

    public var sessionID: String? { payload["session_id"] as? String }
    public var cwd: String? { payload["cwd"] as? String }
    public var toolName: String? { payload["tool_name"] as? String }
    public var toolInput: [String: Any] { payload["tool_input"] as? [String: Any] ?? [:] }
}

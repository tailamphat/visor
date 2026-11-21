import Foundation

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

    /// A question (AskUserQuestion) rather than an action: the terminal answers
    /// it, so Visor only needs to tell it apart from an approval.
    public var isQuestion: Bool { tool == AgentQuestion.tool }

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

    public enum Decision: Equatable, Sendable {
        case allow, allowAlways, deny
    }

    /// The JSON line the hook prints back to Claude Code.
    public func reply(_ decision: Decision) -> Data {
        if provider == "copilot" {
            // Copilot's permissionRequest output; "always" is remembered by Visor.
            let body: [String: Any]
            if case .deny = decision { body = ["behavior": "deny", "message": "Denied from Visor."] } else { body = ["behavior": "allow"] }
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

/// Where an approval goes. "Approvals in the Notch" is one switch for every
/// agent that can ask the notch (Claude Code and Copilot CLI); off, each asks
/// in its own terminal as if Visor weren't there.
public enum ApprovalRoute: Equatable, Sendable {
    /// Reply with nothing at once, so the terminal's own prompt answers it.
    case terminal
    /// A saved Copilot "Always" rule covers it: allow without a card.
    case allow
    /// Show the card and open the notch.
    case notch

    public static func of(_ request: ApprovalRequest, inNotch: Bool, rules: CopilotRules) -> ApprovalRoute {
        if request.isQuestion || !inNotch { return .terminal }
        if request.provider == "copilot" && rules.allows(request) { return .allow }
        return .notch
    }
}

/// How Visor tells that an approval it holds was answered in the terminal.
/// Denying there ends the hook (Visor checks its pid). Allowing doesn't: Claude
/// Code leaves the hook running and starts the command, so Visor looks for it.
public enum TerminalAnswer {
    /// Whether a process's arguments are Claude Code running `command`: its
    /// Bash tool wraps the command as `eval '<command>'`, quoted for the shell.
    public static func runs(_ arguments: String, command: String) -> Bool {
        guard !command.isEmpty else { return false }
        let quoted = "eval '" + command.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
        return arguments.contains(quoted)
    }
}

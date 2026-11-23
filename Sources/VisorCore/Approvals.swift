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
    /// Which call this is, so only that call finishing lets the card go.
    public var call: ApprovalCall

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
        call = ApprovalCall(message)
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

/// One tool call: its tool, its input (canonical JSON, or the raw string some
/// agents send) and the subagent that made it (nil for the main agent).
/// Subagent events share the main session's id, so the tool name alone can't
/// tell two calls apart.
public struct ApprovalCall: Equatable, Sendable {
    public var tool: String
    public var input: String
    public var agent: String?

    public init(_ message: HookMessage) {
        tool = message.toolName ?? "Tool"
        agent = message.payload["agent_id"] as? String
        switch message.payload["tool_input"] {
        case let text as String:
            input = text
        case let object as [String: Any]:
            input = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        default:
            input = ""
        }
    }
}

/// Which held approvals a session's next event makes moot.
public enum ApprovalRelease: Equatable, Sendable {
    /// Every approval the session holds (it moved on: new prompt, idle, stop).
    case all
    /// The approval for this exact call (it ran or failed, so it was answered
    /// elsewhere). Another call of the same tool, or a subagent's, leaves it.
    case call(ApprovalCall)

    public static func after(_ message: HookMessage) -> ApprovalRelease? {
        guard message.sessionID != nil else { return nil }
        switch message.event {
        case "UserPromptSubmit", "Stop", "SessionEnd":
            return .all
        case "PostToolUse", "PostToolUseFailure":
            return message.toolName == nil ? .all : .call(ApprovalCall(message))
        case "Notification" where message.payload["notification_type"] as? String == "idle_prompt":
            return .all
        default:
            return nil
        }
    }

    /// Which of a session's held approvals (oldest first) this lets go of.
    /// A finished call takes the oldest card for the same call: same tool and
    /// input, from the same agent.
    /// With no exact match, a tool other than Bash takes the oldest card for
    /// that tool and agent: its input can change on the way (an edit changed
    /// in the IDE before accepting), and unlike Bash, Visor can't see it start.
    public func releases<ID>(from held: [(id: ID, call: ApprovalCall)]) -> [ID] {
        switch self {
        case .all:
            return held.map(\.id)
        case .call(let done):
            if let exact = held.first(where: { $0.call == done }) {
                return [exact.id]
            }
            guard done.tool != "Bash",
                  let near = held.first(where: { $0.call.tool == done.tool && $0.call.agent == done.agent }) else { return [] }
            return [near.id]
        }
    }
}

/// One line of ~/Library/Logs/Visor/approvals.log: when, which agent, the
/// project folder, the tool and what happened. Never the command, file or
/// input: the log says why a card came and went, not what it was for.
public enum ApprovalLog {
    public static func line(_ request: ApprovalRequest, _ outcome: String, at date: Date) -> String {
        // Agents choose these names: no control characters (newlines, ANSI escapes), at most 64 characters.
        let fields = [request.provider, request.project.isEmpty ? "-" : request.project, request.tool].map { field in
            String(String.UnicodeScalarView(field.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0 }).prefix(64))
        }
        return "\(ISODate.string(date)) \(fields.joined(separator: " ")): \(outcome)\n"
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

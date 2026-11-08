import Foundation

/// Adds and removes Visor's hooks in Claude Code's settings and Copilot CLI's
/// hook file. Other apps' and the user's own hooks are always kept.
public enum HookSettings {
    public static let claudeEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                      "PostToolUseFailure", "PermissionRequest", "Notification", "Stop"]
    public static let copilotEvents = ["sessionStart", "sessionEnd", "userPromptSubmitted", "preToolUse", "postToolUse",
                                       "postToolUseFailure", "agentStop", "notification", "permissionRequest"]
    public static let antigravityEvents = ["SessionStart", "PreInvocation", "PostInvocation",
                                           "PreToolUse", "PostToolUse", "Stop"]

    /// Copilot tools that ask: commands, file changes and web fetches. Reading
    /// and searching never ask.
    public static let copilotApprovalTools = "bash|powershell|create|edit|web_fetch"

    /// How a hook command is recognised as ours: Visor's, and Notchboard's from
    /// before the app was renamed (so those are replaced, not left behind).
    static let markers = ["Visor/agent-hook.sh", "Notchboard/agent-hook.sh"]

    public static func command(script: String, event: String) -> String { "\"\(script)\" \(event)" }

    /// Antigravity passes the provider first, then the event name.
    public static func antigravityCommand(script: String, event: String) -> String {
        "\"\(script)\" antigravity \(event)"
    }

    /// The `"visor"` entry in ~/.gemini/config/hooks.json. Tool events use the
    /// nested matcher shape; lifecycle events take the flat handler shape.
    public static func antigravityEntry(script: String) -> [String: Any] {
        var entry: [String: Any] = [:]
        for event in antigravityEvents {
            let hook: [String: Any] = ["type": "command", "command": antigravityCommand(script: script, event: event),
                                       "timeout": 5]
            switch event {
            case "PreToolUse", "PostToolUse":
                entry[event] = [["matcher": "*", "hooks": [hook]]]
            default:
                entry[event] = [hook]
            }
        }
        return entry
    }

    public static func antigravityFile(script: String) -> [String: Any] {
        ["visor": antigravityEntry(script: script)]
    }

    public static func installAntigravity(into hooks: [String: Any], script: String) -> [String: Any] {
        var hooks = hooks
        hooks["visor"] = antigravityEntry(script: script)
        return hooks
    }

    public static func uninstallAntigravity(from hooks: [String: Any]) -> [String: Any] {
        guard let entry = hooks["visor"], isOursAntigravity(entry) else { return hooks }
        var hooks = hooks
        hooks["visor"] = nil
        return hooks
    }

    public static func isAntigravityInstalled(_ hooks: [String: Any]) -> Bool {
        guard let entry = hooks["visor"] else { return false }
        return isOursAntigravity(entry)
    }

    /// Claude Code settings with Visor's hooks added once per event, after any others.
    public static func install(into settings: [String: Any], script: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in claudeEvents {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            var hook: [String: Any] = ["type": "command", "command": command(script: script, event: event)]
            // Claude Code waits for the hook before it shows its own prompt; give up in time.
            if event == "PermissionRequest" { hook["timeout"] = 120 }
            groups.append(["hooks": [hook]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Claude Code settings without Visor's hooks; events left empty are dropped.
    public static func uninstall(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        var settings = settings
        for (event, value) in hooks {
            let groups = (value as? [[String: Any]] ?? []).filter { !isOurs($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Connected at all, even by an older version with fewer events.
    public static func isInstalled(_ settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return claudeEvents.contains { (hooks[$0] as? [[String: Any]] ?? []).contains(where: isOurs) }
    }

    /// The contents of ~/.copilot/hooks/visor.json.
    public static func copilotFile(script: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in copilotEvents {
            var hook: [String: Any] = ["type": "command", "bash": command(script: script, event: event) + " copilot", "timeoutSec": 5]
            if event == "permissionRequest" {
                // Waits for the card, then Copilot falls back to its own prompt.
                hook["matcher"] = copilotApprovalTools
                hook["timeoutSec"] = 120
            }
            hooks[event] = [hook]
        }
        return ["version": 1, "hooks": hooks]
    }

    /// A hook group that runs our script.
    static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return markers.contains { command.contains($0) }
        }
    }

    /// Antigravity's named hook entries nest commands inside matcher groups.
    static func isOursAntigravity(_ entry: Any) -> Bool {
        hookCommands(in: entry).contains { command in
            markers.contains { command.contains($0) } && command.contains("antigravity")
        }
    }

    static func hookCommands(in value: Any) -> [String] {
        if let object = value as? [String: Any] {
            var commands: [String] = []
            for (key, nested) in object where key != "command" { commands += hookCommands(in: nested) }
            if let command = object["command"] as? String { commands.append(command) }
            return commands
        }
        if let list = value as? [Any] { return list.flatMap(hookCommands(in:)) }
        return []
    }
}

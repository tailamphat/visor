import Foundation

/// Adds and removes Notchboard's hooks in Claude Code's settings and Copilot CLI's
/// hook file. Other apps' and the user's own hooks are always kept.
public enum HookSettings {
    public static let claudeEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                      "PostToolUseFailure", "PermissionRequest", "Notification", "Stop"]
    public static let copilotEvents = ["sessionStart", "sessionEnd", "userPromptSubmitted", "preToolUse", "postToolUse",
                                       "postToolUseFailure", "agentStop", "notification", "permissionRequest"]

    /// Copilot tools that ask: commands, file changes and web fetches. Reading
    /// and searching never ask.
    public static let copilotApprovalTools = "bash|powershell|create|edit|web_fetch"

    /// How a hook command is recognised as Notchboard's.
    static let marker = "Notchboard/agent-hook.sh"

    public static func command(script: String, event: String) -> String { "\"\(script)\" \(event)" }

    /// Claude Code settings with Notchboard's hooks added once per event, after any others.
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

    /// Claude Code settings without Notchboard's hooks; events left empty are dropped.
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

    /// The contents of ~/.copilot/hooks/notchboard.json.
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
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }
}

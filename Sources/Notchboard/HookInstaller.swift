import Foundation

/// Installs agent-hook.sh and registers it for Claude Code's hook events in
/// ~/.claude/settings.json. Other hooks (other apps, the user's own) are kept.
enum HookInstaller {
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "PermissionRequest", "Notification", "Stop"]

    static var scriptURL: URL { HookServer.directory.appendingPathComponent("agent-hook.sh") }
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The hook must never get in Claude Code's way: it exits 0 whether or not
    /// Notchboard is running, and only PermissionRequest waits for an answer.
    static let script = """
    #!/bin/sh
    # Notchboard: forwards Claude Code hook events to the notch. Always succeeds.
    e=$1
    s="$HOME/Library/Application Support/Notchboard/hook.sock"
    d=$(cat)
    [ -S "$s" ] || exit 0
    [ -n "$d" ] || d='{}'
    m=$(printf '{"event":"%s","pid":%s,"raw":%s}' "$e" "$PPID" "$d")
    if [ "$e" = "PermissionRequest" ]; then
      printf '%s\\n' "$m" | /usr/bin/nc -U -w 110 "$s" 2>/dev/null
    else
      printf '%s\\n' "$m" | /usr/bin/nc -U -w 1 "$s" >/dev/null 2>&1
    fi
    exit 0

    """

    private static func command(_ event: String) -> String { "\"\(scriptURL.path)\" \(event)" }

    static var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path),
              let hooks = readSettings()?["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains(where: isOurs)
        }
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: HookServer.directory, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var settings = readSettings() ?? [:]
        backUpSettingsOnce()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            var hook: [String: Any] = ["type": "command", "command": command(event)]
            // Claude Code waits for the hook before it shows its own prompt; give up in time.
            if event == "PermissionRequest" { hook["timeout"] = 120 }
            groups.append(["hooks": [hook]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    static func uninstall() throws {
        guard var settings = readSettings(), var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            let groups = (value as? [[String: Any]] ?? []).filter { !isOurs($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    /// A hook group that runs our script.
    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains("Notchboard/agent-hook.sh") == true
        }
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func backUpSettingsOnce() {
        let backup = settingsURL.appendingPathExtension("notchboard-backup")
        guard !FileManager.default.fileExists(atPath: backup.path),
              FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }
}

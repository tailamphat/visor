import Foundation
import VisorCore

/// Installs agent-hook.sh and registers it for Claude Code's hook events in
/// ~/.claude/settings.json. Other hooks (other apps, the user's own) are kept.
enum HookInstaller {
    static let events = HookSettings.claudeEvents

    static var scriptURL: URL { HookServer.directory.appendingPathComponent("agent-hook.sh") }
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The hook must never get in the agent's way: it exits 0 whether or not
    /// Visor is running, and only approval requests wait for an answer.
    static let script = """
    #!/bin/sh
    # Visor: forwards agent hook events to the notch. Always succeeds.
    # The usage probe must not show up as a session.
    [ -z "$VISOR_USAGE_PROBE" ] || exit 0
    if [ "$1" = "antigravity" ]; then
      p=antigravity
      e=$2
    else
      e=$1
      p=${2:-claude}
    fi
    s="$HOME/Library/Application Support/Visor/hook.sock"
    d=$(cat)
    [ -n "$d" ] || d='{}'
    if [ -S "$s" ]; then
      m=$(printf '{"event":"%s","provider":"%s","pid":%s,"hpid":%s,"raw":%s}' "$e" "$p" "$PPID" "$$" "$d")
      if [ "$e" = "PermissionRequest" ] || [ "$e" = "permissionRequest" ]; then
        printf '%s\\n' "$m" | /usr/bin/nc -U -w 110 "$s" 2>/dev/null
      else
        printf '%s\\n' "$m" | /usr/bin/nc -U -w 1 "$s" >/dev/null 2>&1
      fi
    fi
    # Antigravity needs an explicit decision; allow defers to its own rules.
    if [ "$p" = "antigravity" ] && [ "$e" = "PreToolUse" ]; then
      printf '{"decision":"allow"}'
    fi
    exit 0

    """

    /// Connected at all, even by an older version with fewer events; launch
    /// then re-installs to bring the script and event list up to date.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: scriptURL.path) && HookSettings.isInstalled(readSettings() ?? [:])
    }

    static func writeScript() throws {
        try FileManager.default.createDirectory(at: HookServer.directory, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    static func install() throws {
        try writeScript()
        backUpSettingsOnce()
        try writeSettings(HookSettings.install(into: readSettings() ?? [:], script: scriptURL.path))
    }

    // MARK: Copilot CLI

    /// Copilot CLI reads every JSON file in ~/.copilot/hooks; Visor keeps its own.
    static var copilotDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot") }
    static var copilotHooksURL: URL { copilotDirectory.appendingPathComponent("hooks/visor.json") }
    /// The file Notchboard wrote before the rename.
    static var legacyCopilotHooksURL: URL { copilotDirectory.appendingPathComponent("hooks/notchboard.json") }

    static var hasCopilotCLI: Bool { FileManager.default.fileExists(atPath: copilotDirectory.path) }
    static var copilotInstalled: Bool {
        FileManager.default.fileExists(atPath: copilotHooksURL.path) || FileManager.default.fileExists(atPath: legacyCopilotHooksURL.path)
    }

    static func installCopilot() throws {
        guard hasCopilotCLI else { return }
        try writeScript()
        let data = try JSONSerialization.data(withJSONObject: HookSettings.copilotFile(script: scriptURL.path),
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: copilotHooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: copilotHooksURL, options: .atomic)
        try? FileManager.default.removeItem(at: legacyCopilotHooksURL)
    }

    // MARK: Antigravity

    /// Antigravity reads named hooks from ~/.gemini/config/hooks.json.
    static var antigravityHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config/hooks.json")
    }

    static var hasAntigravityCLI: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.gemini/antigravity-cli", home + "/.local/bin/agy",
                "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    static var antigravityInstalled: Bool {
        readAntigravityHooks().map(HookSettings.isAntigravityInstalled) ?? false
    }

    static func installAntigravity() throws {
        guard hasAntigravityCLI else { return }
        try writeScript()
        try writeAntigravityHooks(HookSettings.installAntigravity(into: readAntigravityHooks() ?? [:],
                                                                 script: scriptURL.path))
    }

    static func uninstallAntigravity() throws {
        guard let hooks = readAntigravityHooks() else { return }
        let remaining = HookSettings.uninstallAntigravity(from: hooks)
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: antigravityHooksURL)
        } else {
            try writeAntigravityHooks(remaining)
        }
    }

    private static func readAntigravityHooks() -> [String: Any]? {
        guard let data = try? Data(contentsOf: antigravityHooksURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeAntigravityHooks(_ hooks: [String: Any]) throws {
        try FileManager.default.createDirectory(at: antigravityHooksURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: hooks,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: antigravityHooksURL, options: .atomic)
    }

    static func uninstallCopilot() throws {
        for url in [copilotHooksURL, legacyCopilotHooksURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func uninstall() throws {
        guard let settings = readSettings() else { return }
        try writeSettings(HookSettings.uninstall(from: settings))
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
        let backup = settingsURL.appendingPathExtension("visor-backup")
        guard !FileManager.default.fileExists(atPath: backup.path),
              FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }
}

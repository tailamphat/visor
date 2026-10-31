import Foundation
import NotchboardCore

/// Installs agent-hook.sh and registers it for Claude Code's hook events in
/// ~/.claude/settings.json. Other hooks (other apps, the user's own) are kept.
enum HookInstaller {
    static let events = HookSettings.claudeEvents

    static var scriptURL: URL { HookServer.directory.appendingPathComponent("agent-hook.sh") }
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The hook must never get in the agent's way: it exits 0 whether or not
    /// Notchboard is running, and only approval requests wait for an answer.
    static let script = """
    #!/bin/sh
    # Notchboard: forwards Claude Code hook events to the notch. Always succeeds.
    e=$1
    p=${2:-claude}
    s="$HOME/Library/Application Support/Notchboard/hook.sock"
    d=$(cat)
    [ -S "$s" ] || exit 0
    [ -n "$d" ] || d='{}'
    m=$(printf '{"event":"%s","provider":"%s","pid":%s,"hpid":%s,"raw":%s}' "$e" "$p" "$PPID" "$$" "$d")
    if [ "$e" = "PermissionRequest" ] || [ "$e" = "permissionRequest" ]; then
      printf '%s\\n' "$m" | /usr/bin/nc -U -w 110 "$s" 2>/dev/null
    else
      printf '%s\\n' "$m" | /usr/bin/nc -U -w 1 "$s" >/dev/null 2>&1
    fi
    exit 0

    """

    /// Connected at all, even by an older version with fewer events; launch
    /// then re-installs to bring the script and event list up to date.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: scriptURL.path) && HookSettings.isInstalled(readSettings() ?? [:])
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: HookServer.directory, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        backUpSettingsOnce()
        try writeSettings(HookSettings.install(into: readSettings() ?? [:], script: scriptURL.path))
    }

    // MARK: Copilot CLI

    /// Copilot CLI reads every JSON file in ~/.copilot/hooks; Notchboard keeps its own.
    static var copilotDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot") }
    static var copilotHooksURL: URL { copilotDirectory.appendingPathComponent("hooks/notchboard.json") }

    static var hasCopilotCLI: Bool { FileManager.default.fileExists(atPath: copilotDirectory.path) }
    static var copilotInstalled: Bool { FileManager.default.fileExists(atPath: copilotHooksURL.path) }

    static func installCopilot() throws {
        guard hasCopilotCLI else { return }
        let data = try JSONSerialization.data(withJSONObject: HookSettings.copilotFile(script: scriptURL.path),
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: copilotHooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: copilotHooksURL, options: .atomic)
    }

    static func uninstallCopilot() throws {
        if copilotInstalled { try FileManager.default.removeItem(at: copilotHooksURL) }
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
        let backup = settingsURL.appendingPathExtension("notchboard-backup")
        guard !FileManager.default.fileExists(atPath: backup.path),
              FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: backup)
    }
}

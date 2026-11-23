import Foundation

/// The script Terminal runs for Update on a release card. It is written to a
/// private temp folder and opened with Terminal (a `.command` file runs in a
/// new window), so nothing is typed into the user's own shell and no
/// Automation permission is needed. The only command in it is the catalog's.
public enum TerminalCommand {
    /// Letters, digits and `space - _ . / @ :` only: every catalog command fits,
    /// and nothing a shell treats specially (quotes, `$`, `;`, newlines) can get through.
    public static func isSafe(_ command: String) -> Bool {
        !command.isEmpty && command.count <= 120 && command.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0))))
                || " -_./@:".unicodeScalars.contains($0)
        }
    }

    /// nil when the command, the tool name or the folder isn't plain. PATH is the
    /// radar's: the binary's folder, then Homebrew and the system. The script
    /// removes itself first so it is gone even if the window is closed mid-run.
    public static func script(toolName: String, command: String, binaryDir: String?) -> String? {
        guard isSafe(command), isSafe(toolName) else { return nil }
        var path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let dir = binaryDir, isSafe(dir), dir.hasPrefix("/") { path = "\(dir):" + path }
        return """
        #!/bin/zsh -f
        rm -f -- "$0"; rmdir -- "${0:h}" 2>/dev/null
        export PATH='\(path)'
        print -r -- 'Visor: updating \(toolName)'
        \(command)
        rc=$?
        if [ "$rc" -eq 0 ]; then
          print -r -- 'Done. You can close this window.'
        else
          print -r -- "Update failed (exit status $rc). You can close this window."
        fi

        """
    }

    /// Writes the script into a fresh 0700 folder as a 0700 `.command` file.
    public static func write(_ script: String, in base: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let dir = base.appendingPathComponent("visor-update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("update.command")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}

import Foundation

/// The AppleScript that opens a Terminal tab with a catalog command typed on
/// its prompt, not run. zsh's `print -z` pushes text onto the next prompt's
/// edit buffer, so the user reads it and presses Return; no keystrokes are
/// posted, so no Accessibility is needed. The only thing Terminal runs is our
/// own `print`, never the command.
public enum TerminalCommand {
    /// Letters, digits and `space - _ . / @ :` only: every catalog command fits,
    /// and nothing a shell or AppleScript treats specially can get through.
    public static func isSafe(_ command: String) -> Bool {
        !command.isEmpty && command.count <= 120 && command.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0))))
                || " -_./@:".unicodeScalars.contains($0)
        }
    }

    /// True when a login shell path (the passwd entry or $SHELL) is zsh.
    public static func isZsh(_ shellPath: String?) -> Bool {
        shellPath?.split(separator: "/").last == "zsh"
    }

    /// nil when the command isn't plain (it is then never sent to a shell).
    /// The line starts with one space: a startup prompt that reads one character
    /// (oh-my-zsh's update question) gets " " (no), and zsh ignores it. `--`
    /// keeps a leading "-" from being read as an option. Only for zsh; other
    /// shells get the command on the clipboard instead (`needsClipboard`).
    public static func appleScript(typing command: String) -> String? {
        guard isSafe(command) else { return nil }
        let line = " print -z -- '\(command)'"
        return """
        tell application "Terminal"
            activate
            do script "\(escaped(line))"
        end tell
        """
    }

    /// For an AppleScript string literal.
    public static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

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

    /// nil when the command isn't plain (it is then never sent to a shell).
    public static func appleScript(typing command: String) -> String? {
        guard isSafe(command) else { return nil }
        // Inside single quotes nothing is special, and the set has no quote.
        // Other shells have no `print -z`: they show the command to copy.
        let line = "if [ -n \"$ZSH_VERSION\" ]; then print -z '\(command)'; else echo '\(command)'; fi"
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

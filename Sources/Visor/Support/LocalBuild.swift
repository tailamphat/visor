import AppKit
import VisorCore

/// Local builds (debug, worktree, plain bundle.sh) look different from the release.
enum LocalBuild {
    static let isLocal = !BuildKind.isRelease(info: Bundle.main.infoDictionary)
    static let orange = NSColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)

    /// Read once, on first menu open: version, commit and worktree folder.
    static let menuTitle: String = {
        let info = Bundle.main.infoDictionary
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let root = repoRoot(from: exe)
        var commit = info?["VisorCommit"] as? String
        if commit == nil, let root {
            commit = Shell.run("/usr/bin/git", ["-C", root.path, "rev-parse", "--short", "HEAD"], timeout: 2)?
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var worktree: String?
        if let root, isWorktree(root) { worktree = root.lastPathComponent }
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty || exe.path.contains("/.build/debug/") ? nil : $0 }
        return BuildKind.menuTitle(version: version, commit: commit, worktree: worktree)
    }()

    private static func repoRoot(from url: URL) -> URL? {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// In a linked worktree `.git` is a file, in the main repo a folder.
    private static func isWorktree(_ root: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path, isDirectory: &isDir)
        return !isDir.boolValue
    }

    /// The menu bar icon in orange, with a small dot (not a template, so the colour stays).
    static func tinted(_ icon: NSImage?) -> NSImage? {
        guard let icon else { return nil }
        let size = icon.size
        let image = NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            orange.setFill()
            rect.fill(using: .sourceAtop)
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5.5, y: 0, width: 5.5, height: 5.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

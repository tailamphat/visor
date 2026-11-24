import AppKit
import VisorCore

/// Local builds (debug, worktree, plain bundle.sh) look different from the release.
enum LocalBuild {
    static let isLocal = !BuildKind.isRelease(info: Bundle.main.infoDictionary)
    static let orange = NSColor(hex: DesignTokens.Palette.localBuild)

    /// The first menu line. Main thread only; `start()` fills in the commit and worktree.
    private(set) static var menuTitle = BuildKind.menuTitle(version: version, commit: info?["VisorCommit"] as? String, worktree: nil)

    /// Under the short hello: "Visor 0.9.1", marked when it's a local build.
    static var helloLine: String {
        let name = version.map { "Visor \($0)" } ?? "Visor"
        return isLocal ? name + " (local build)" : name
    }

    private static var info: [String: Any]? { Bundle.main.infoDictionary }
    private static var version: String? {
        (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// At launch, local builds only: finds the commit and worktree off the main thread.
    static func start() {
        guard isLocal else { return }
        DispatchQueue.global(qos: .utility).async {
            let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let root = repoRoot(from: exe)
            var commit = info?["VisorCommit"] as? String
            if commit == nil, let root {
                commit = Shell.run("/usr/bin/git", ["-C", root.path, "rev-parse", "--short", "HEAD"], timeout: 2)?
                    .text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let worktree = root.flatMap { isWorktree($0) ? $0.lastPathComponent : nil }
            let title = BuildKind.menuTitle(version: version, commit: commit, worktree: worktree)
            DispatchQueue.main.async { menuTitle = title }
        }
    }

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

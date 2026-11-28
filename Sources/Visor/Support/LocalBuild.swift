import AppKit
import SwiftUI
import VisorCore

/// Local builds (debug, worktree, plain bundle.sh) look different from the release.
enum LocalBuild {
    static let isLocal = !BuildKind.isRelease(info: Bundle.main.infoDictionary)
    /// What this build draws beyond the release look: the open panel's grid and the hello's pen line.
    static let look = BuildKind.look(info: Bundle.main.infoDictionary)

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

    /// One square of the open panel's drafting grid (a line along its top and
    /// left edge), drawn once; SwiftUI tiles it.
    static let gridTile: NSImage = {
        typealias B = DesignComponents.Blueprint
        let cell = CGFloat(B.cell), line = CGFloat(B.line)
        let colour = NSColor(DS.Palette.blueprint).withAlphaComponent(CGFloat(B.gridOpacity))
        return NSImage(size: NSSize(width: cell, height: cell), flipped: true) { rect in
            colour.setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: line).fill()
            NSRect(x: 0, y: line, width: line, height: rect.height - line).fill()
            return true
        }
    }()
}

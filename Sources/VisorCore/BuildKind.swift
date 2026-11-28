import Foundation

/// Tells the release build from a local one. scripts/release.sh stamps
/// `VisorRelease = YES` into Info.plist; every other build is local.
public enum BuildKind {
    public static func isRelease(info: [String: Any]?) -> Bool {
        guard let value = info?["VisorRelease"] else { return false }
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return ["yes", "true", "1"].contains(text.lowercased()) }
        return false
    }

    /// What a build draws beyond the release look.
    public static func look(info: [String: Any]?) -> BuildLook {
        isRelease(info: info) ? .release : .local
    }

    /// The first menu line of a local build.
    public static func menuTitle(version: String?, commit: String?, worktree: String?) -> String {
        var parts = ["Visor (local build)", version ?? "dev"]
        if let commit, !commit.isEmpty { parts.append(commit) }
        if let worktree, !worktree.isEmpty { parts.append(worktree) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The local build's look (mockup E1 "Blueprint"): a faint grid behind the
/// open panel's content and a pen line drawn once under the launch hello.
/// The closed notch and the menu bar icon look like the release in both.
public struct BuildLook: Equatable, Sendable {
    public let panelGrid: Bool
    public let helloPen: Bool

    public static let local = BuildLook(panelGrid: true, helloPen: true)
    public static let release = BuildLook(panelGrid: false, helloPen: false)
}

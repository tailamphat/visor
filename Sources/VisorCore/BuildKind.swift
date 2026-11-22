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

    /// The first menu line of a local build.
    public static func menuTitle(version: String?, commit: String?, worktree: String?) -> String {
        var parts = ["Visor (local build)", version ?? "dev"]
        if let commit, !commit.isEmpty { parts.append(commit) }
        if let worktree, !worktree.isEmpty { parts.append(worktree) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

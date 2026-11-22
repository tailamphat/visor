import Foundation

/// A tool version, semver style: `major.minor.patch` with an optional
/// `-prerelease`. Only made from text that passes the version pattern, so its
/// `description` is safe to put in a URL path or on screen.
public struct ToolVersion: Comparable, Hashable, Sendable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated prerelease identifiers; empty for a release.
    public let prerelease: [String]

    static let maxLength = 40
    private static let exact = try! NSRegularExpression(pattern: #"^(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?:-([0-9A-Za-z.-]+))?$"#)
    private static let anywhere = try! NSRegularExpression(pattern: #"(?<![\d.])\d{1,9}\.\d{1,9}\.\d{1,9}(?:-[0-9A-Za-z.-]{1,40})?"#)

    /// Exactly a version, nothing around it.
    public init?(_ text: String) {
        guard text.count <= Self.maxLength,
              let match = Self.exact.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
        guard let major = group(1).flatMap(Int.init), let minor = group(2).flatMap(Int.init),
              let patch = group(3).flatMap(Int.init) else { return nil }
        let pre = group(4)?.split(separator: ".", omittingEmptySubsequences: false).map(String.init) ?? []
        guard !pre.contains(where: \.isEmpty) else { return nil }
        (self.major, self.minor, self.patch, self.prerelease) = (major, minor, patch, pre)
    }

    /// The last version in a CLI's `--version` output ("2.1.311 (Claude Code)",
    /// "GitHub Copilot CLI 1.0.107.", "codex-cli 0.63.0"): the last, so a runtime
    /// warning printed first ("Node.js v18.0.0 is not supported") isn't read as it.
    public init?(output: String) {
        let output = String(output.prefix(4_000))
        guard let match = Self.anywhere.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
              let range = Range(match.range, in: output) else { return nil }
        var text = String(output[range])
        while text.hasSuffix(".") || text.hasSuffix("-") { text.removeLast() }
        self.init(text)
    }

    /// A release tag with the catalog's prefix ("v2.1.330", "rust-v0.171.0").
    public init?(tag: String, prefix: String) {
        guard tag.hasPrefix(prefix) else { return nil }
        self.init(String(tag.dropFirst(prefix.count)))
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// Saved as its text, and read back only if it still passes the pattern.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = ToolVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a version"))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: ToolVersion, b: ToolVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// How a tool was installed, which decides where its latest version is read and
/// which update command fits.
public enum InstallMethod: String, CaseIterable, Sendable, Codable {
    case npm, brew, native
}

/// A tool the release radar knows, with its public feeds and fixed update
/// commands. Every string here is a constant: feed data never reaches a URL host
/// or a command. Sources confirmed with one GET each on 2026-11-22.
public struct ReleaseTool: Sendable, Identifiable {
    public enum Brew: Equatable, Sendable { case formula(String), cask(String) }
    public struct GitHub: Equatable, Sendable {
        public var repo: String
        public var tagPrefix: String
    }

    public let id: String
    /// The Agents tab's name for it.
    public let name: String
    public let binary: String
    public let npmPackage: String?
    public let brew: Brew?
    public let github: GitHub?
    /// The tool's own updater for a native install, if it has one.
    let nativeCommand: String?
    /// Where its native installer puts it, relative to the home folder.
    let nativePaths: [String]

    /// No public feed: never checked, never offered.
    public var isSkipped: Bool { npmPackage == nil && brew == nil && github == nil }

    public static let all: [ReleaseTool] = [
        ReleaseTool(id: "claude", name: "Claude Code", binary: "claude", npmPackage: "@anthropic-ai/claude-code",
                    brew: .cask("claude-code"), github: GitHub(repo: "anthropics/claude-code", tagPrefix: "v"),
                    nativeCommand: "claude update", nativePaths: [".local/bin/claude", ".local/share/claude/", ".claude/local/"]),
        ReleaseTool(id: "copilot", name: "Copilot CLI", binary: "copilot", npmPackage: "@github/copilot",
                    brew: .cask("copilot-cli"), github: GitHub(repo: "github/copilot-cli", tagPrefix: "v"),
                    nativeCommand: "copilot update", nativePaths: [".local/bin/copilot"]),
        ReleaseTool(id: "codex", name: "Codex CLI", binary: "codex", npmPackage: "@openai/codex",
                    brew: .cask("codex"), github: GitHub(repo: "openai/codex", tagPrefix: "rust-v"),
                    nativeCommand: nil, nativePaths: []),
        ReleaseTool(id: "gemini", name: "Gemini CLI", binary: "gemini", npmPackage: "@google/gemini-cli",
                    brew: .formula("gemini-cli"), github: GitHub(repo: "google-gemini/gemini-cli", tagPrefix: "v"),
                    nativeCommand: nil, nativePaths: []),
        ReleaseTool(id: "opencode", name: "OpenCode", binary: "opencode", npmPackage: "opencode-ai",
                    brew: .formula("opencode"), github: GitHub(repo: "anomalyco/opencode", tagPrefix: "v"),
                    nativeCommand: "opencode upgrade", nativePaths: [".opencode/bin/"]),
        // No confirmed public release feed (backlog Assumptions): skipped.
        ReleaseTool(id: "antigravity", name: "Antigravity CLI", binary: "agy", npmPackage: nil, brew: nil, github: nil,
                    nativeCommand: nil, nativePaths: []),
    ]

    /// The install method from the binary's resolved path; nil when it can't be
    /// told, or when it's a manager Visor has no command for (bun, pnpm).
    public func installMethod(path: String, home: String) -> InstallMethod? {
        guard !isSkipped else { return nil }
        let base = home.hasSuffix("/") ? home : home + "/"
        // Native first: Claude's old local install keeps its own node_modules.
        if nativePaths.contains(where: { path.hasPrefix(base + $0) }) { return .native }
        switch brew {
        case .cask(let name)? where path.contains("/Caskroom/\(name)/"): return .brew
        case .formula(let name)? where path.contains("/Cellar/\(name)/"): return .brew
        default: break
        }
        if path.contains("/Caskroom/") || path.contains("/Cellar/") { return nil }
        // Other managers' globals: `npm install -g` would only add a second copy.
        let managers = ["/.bun/", "/pnpm/", "/.yarn/", "/.config/yarn/", "/.volta/"]
        if managers.contains(where: path.contains) { return nil }
        // An npm global prefix (`<prefix>/lib/node_modules/<package>/`), for this package only.
        if let npmPackage, path.contains("/lib/node_modules/\(npmPackage)/") { return .npm }
        return nil
    }

    /// The command 2c types into Terminal (the user presses Return); nil when
    /// there is none for this install.
    public func updateCommand(_ method: InstallMethod) -> String? {
        switch method {
        case .npm: return npmPackage.map { "npm install -g \($0)@latest" }
        case .brew:
            switch brew {
            case .cask(let name)?: return "brew upgrade --cask \(name)"
            case .formula(let name)?: return "brew upgrade \(name)"
            case nil: return nil
            }
        case .native: return nativeCommand
        }
    }

    /// Where the latest version for this install's own channel is read, so the
    /// command installs what was offered.
    public func versionURL(for method: InstallMethod) -> URL? {
        switch method {
        case .npm:
            guard let package = npmPackage else { return nil }
            return ReleaseFeed.url("https://registry.npmjs.org/\(package.replacingOccurrences(of: "/", with: "%2F"))/latest")
        case .brew:
            switch brew {
            case .cask(let name)?: return ReleaseFeed.url("https://formulae.brew.sh/api/cask/\(name).json")
            case .formula(let name)?: return ReleaseFeed.url("https://formulae.brew.sh/api/formula/\(name).json")
            case nil: return nil
            }
        case .native:
            guard let github, !nativePaths.isEmpty else { return nil }
            return ReleaseFeed.url("https://api.github.com/repos/\(github.repo)/releases/latest")
        }
    }

    /// The GitHub release for a version, for its notes.
    public func notesURL(version: ToolVersion) -> URL? {
        guard let github else { return nil }
        return ReleaseFeed.url("https://api.github.com/repos/\(github.repo)/releases/tags/\(github.tagPrefix)\(version)")
    }

    /// The latest version from the answer to `versionURL(for: method)`.
    public func latest(from data: Data, method: InstallMethod) -> ToolVersion? {
        switch method {
        case .npm: return ReleaseFeed.npmLatest(data)
        case .brew:
            switch brew {
            case .cask?: return ReleaseFeed.brewCask(data)
            case .formula?: return ReleaseFeed.brewFormula(data)
            case nil: return nil
            }
        case .native: return github.flatMap { ReleaseFeed.githubRelease(data, tagPrefix: $0.tagPrefix)?.version }
        }
    }
}

/// A GitHub release: its version and notes, nothing else (no links).
public struct GitHubRelease: Equatable, Sendable {
    public var version: ToolVersion
    public var notes: String
}

/// Parsers for the public feeds. Feed text is data only.
public enum ReleaseFeed {
    /// The only hosts the radar contacts (HTTPS GET, no sign-in).
    public static let allowedHosts: Set<String> = ["registry.npmjs.org", "api.github.com", "formulae.brew.sh"]

    /// A URL only when it's https on an allowed host, with no query, port or user.
    static func url(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, allowedHosts.contains(host),
              url.query == nil, url.fragment == nil, url.port == nil, url.user == nil else { return nil }
        return url
    }

    /// Larger answers are refused unread (a release object is tens of KB).
    static let maxAnswer = 2_000_000

    static func object(_ data: Data) -> [String: Any]? {
        guard data.count <= maxAnswer else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `registry.npmjs.org/<package>/latest`: its `version`.
    public static func npmLatest(_ data: Data) -> ToolVersion? {
        (object(data)?["version"] as? String).flatMap { ToolVersion($0) }
    }

    /// `formulae.brew.sh/api/formula/<name>.json`: `versions.stable`.
    public static func brewFormula(_ data: Data) -> ToolVersion? {
        ((object(data)?["versions"] as? [String: Any])?["stable"] as? String).flatMap { ToolVersion($0) }
    }

    /// `formulae.brew.sh/api/cask/<name>.json`: `version`, up to a comma ("1.0.108,abc123").
    public static func brewCask(_ data: Data) -> ToolVersion? {
        guard let text = object(data)?["version"] as? String else { return nil }
        return ToolVersion(String(text.prefix { $0 != "," }))
    }

    /// A GitHub release object; nil for a draft, a prerelease or a tag without the prefix.
    public static func githubRelease(_ data: Data, tagPrefix: String) -> GitHubRelease? {
        guard let release = object(data), release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
              let tag = release["tag_name"] as? String,
              let version = ToolVersion(tag: tag, prefix: tagPrefix), !version.isPrerelease else { return nil }
        return GitHubRelease(version: version, notes: release["body"] as? String ?? "")
    }
}

/// The top changes from a release body: top-level bullets as plain text.
public enum ReleaseNotes {
    static let maxLength = 120
    /// Only the head of a body is read, and each line is cut before the cleanup
    /// regexes run, so a hostile body can't make them backtrack for long.
    static let maxBody = 64_000
    static let maxLines = 500
    static let maxLine = 500
    private static let numbered = try! NSRegularExpression(pattern: #"^\d{1,3}\.\s+"#)
    private static let image = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let credit = try! NSRegularExpression(pattern: #"\s+by @[\w-]+(\[bot\])? in https?://\S+$"#)
    private static let issues = try! NSRegularExpression(pattern: #"\s*\((#\d+[,\s]*)+\)$"#)
    private static let space = try! NSRegularExpression(pattern: #"\s+"#)
    /// Housekeeping, not a change anyone would want to read about.
    private static let chore = try! NSRegularExpression(pattern: #"^(chore|test|tests|ci|build|docs|refactor|style)(\([^)]*\))?!?:|^Changelog for "#,
                                                        options: .caseInsensitive)

    public static func topChanges(_ body: String, limit: Int = 3) -> [String] {
        var changes: [String] = []
        let head = String(String.UnicodeScalarView(body.unicodeScalars.prefix(maxBody)))
        for raw in head.components(separatedBy: .newlines).prefix(maxLines) where changes.count < limit {
            guard !raw.hasPrefix("  "), !raw.hasPrefix("\t") else { continue }
            var line = plain(raw).trimmingCharacters(in: .whitespaces)
            if let marker = ["- ", "* ", "+ "].first(where: line.hasPrefix) {
                line.removeFirst(marker.count)
            } else if let match = numbered.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range, in: line) {
                line.removeSubrange(range)
            } else {
                continue
            }
            line = clean(line)
            guard !line.isEmpty, !matches(chore, line) else { continue }
            if line.unicodeScalars.count > maxLength {
                line = String(String.UnicodeScalarView(line.unicodeScalars.prefix(maxLength - 1))).trimmingCharacters(in: .whitespaces) + "…"
            }
            changes.append(line)
        }
        return changes
    }

    /// At most `maxLine` scalars, control characters as spaces, format
    /// characters (bidi overrides, zero-width) dropped.
    static func plain(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars.prefix(maxLine) {
            switch scalar.properties.generalCategory {
            case .control: scalars.append(" ")
            case .format: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// One saved change cleaned like a fresh one; nil when nothing is left.
    static func sanitized(_ text: String) -> String? {
        var line = clean(plain(text))
        guard !line.isEmpty else { return nil }
        if line.unicodeScalars.count > maxLength {
            line = String(String.UnicodeScalarView(line.unicodeScalars.prefix(maxLength - 1))).trimmingCharacters(in: .whitespaces) + "…"
        }
        return line
    }

    static func clean(_ text: String) -> String {
        var line = replace(image, in: text, with: "")
        line = replace(link, in: line, with: "$1")
        line = replace(credit, in: line, with: "")
        line = replace(issues, in: line, with: "")
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        return replace(space, in: line, with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// An update worth a peek.
public struct ReleaseUpdate: Equatable, Sendable, Codable {
    public var toolID: String
    public var name: String
    public var installed: ToolVersion
    public var latest: ToolVersion
    public var changes: [String]
    /// nil when the install has no update command (the peek shows no Update action).
    public var command: String?
    /// The channel it was read from; decides the command.
    public var method: InstallMethod?
}

extension ReleaseUpdate {
    enum CodingKeys: String, CodingKey { case toolID, method, installed, latest, changes }

    /// Saved without its name or command: on load both come from the catalog
    /// and the changes are cleaned again, so an edited file can't choose what
    /// the card says or what the Update action types.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .toolID)
        let method = try container.decode(InstallMethod.self, forKey: .method)
        guard let tool = ReleaseTool.all.first(where: { $0.id == id && !$0.isSkipped }) else {
            throw DecodingError.dataCorruptedError(forKey: .toolID, in: container, debugDescription: "unknown tool")
        }
        let changes = try container.decode([String].self, forKey: .changes).prefix(3).compactMap(ReleaseNotes.sanitized)
        self.init(toolID: tool.id, name: tool.name, installed: try container.decode(ToolVersion.self, forKey: .installed),
                  latest: try container.decode(ToolVersion.self, forKey: .latest), changes: changes,
                  command: tool.updateCommand(method), method: method)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolID, forKey: .toolID)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encode(installed, forKey: .installed)
        try container.encode(latest, forKey: .latest)
        try container.encode(changes, forKey: .changes)
    }
}

public enum ReleaseRadar {
    /// An update when the install's channel has a newer release (never a
    /// prerelease); nil otherwise, or for a skipped tool or a channel with no feed.
    public static func update(tool: ReleaseTool, installed: ToolVersion, method: InstallMethod,
                              latest: ToolVersion, notes: String?) -> ReleaseUpdate? {
        guard !tool.isSkipped, tool.versionURL(for: method) != nil, !latest.isPrerelease, installed < latest else { return nil }
        return ReleaseUpdate(toolID: tool.id, name: tool.name, installed: installed, latest: latest,
                             changes: notes.map { ReleaseNotes.topChanges($0) } ?? [], command: tool.updateCommand(method), method: method)
    }
}

import Foundation

/// A plugin's plugin.json: who it is, what it may reach, and its defaults.
public struct PluginManifest: Equatable, @unchecked Sendable {
    public var id: String
    public var name: String
    public var version: String
    /// An SF Symbol name.
    public var icon: String
    public var description: String
    /// The Lua file Visor runs, relative to the plugin's folder.
    public var main: String
    /// The only hosts `visor.http` may call, over https. "*.ghe.com" matches any subdomain.
    public var hosts: [String]
    /// Secret name → how to read it and where it may be sent.
    public var secrets: [String: PluginSecret]
    /// Setting name → default value; the user's settings.json overrides them.
    public var settings: [String: Any]
    /// The plugin's one colour (0xRRGGBB) for charts, progress and its primary button.
    public var accent: Int?

    public init(id: String, name: String, version: String = "0.0.0", icon: String = "puzzlepiece.extension",
                description: String = "", main: String = "main.lua", hosts: [String] = [], secrets: [String: PluginSecret] = [:],
                settings: [String: Any] = [:], accent: Int? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.icon = icon
        self.description = description
        self.main = main
        self.hosts = hosts
        self.secrets = secrets
        self.settings = settings
        self.accent = accent
    }

    public static func == (a: PluginManifest, b: PluginManifest) -> Bool {
        a.id == b.id && a.name == b.name && a.version == b.version && a.icon == b.icon && a.main == b.main
            && a.hosts == b.hosts && a.secrets == b.secrets && a.accent == b.accent
    }

    public static func parse(_ data: Data) throws -> PluginManifest {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.manifest("plugin.json isn't a JSON object")
        }
        guard let id = object["id"] as? String, id.range(of: #"^[a-z0-9][a-z0-9-]{0,40}$"#, options: .regularExpression) != nil else {
            throw PluginError.manifest("\"id\" must be lowercase letters, digits and dashes")
        }
        guard let name = object["name"] as? String, !name.isEmpty else { throw PluginError.manifest("\"name\" is missing") }
        let main = object["main"] as? String ?? "main.lua"
        guard !main.contains("/"), main.hasSuffix(".lua") else { throw PluginError.manifest("\"main\" must be a .lua file in the plugin's folder") }
        return PluginManifest(id: id, name: name, version: object["version"] as? String ?? "0.0.0",
                              icon: object["icon"] as? String ?? "puzzlepiece.extension",
                              description: object["description"] as? String ?? "", main: main,
                              hosts: object["hosts"] as? [String] ?? [],
                              secrets: (object["secrets"] as? [String: Any] ?? [:]).compactMapValues(PluginSecret.parse),
                              settings: object["settings"] as? [String: Any] ?? [:],
                              accent: (object["accent"] as? String).flatMap(Self.hexColor))
    }

    /// "#RRGGBB" as 0xRRGGBB.
    static func hexColor(_ text: String) -> Int? {
        guard text.count == 7, text.hasPrefix("#") else { return nil }
        return Int(text.dropFirst(), radix: 16)
    }

    /// Whether `visor.http` may call this URL: https, to a listed host.
    public func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains { pattern in
            let pattern = pattern.lowercased()
            if pattern.hasPrefix("*.") { return host.hasSuffix(pattern.dropFirst(1)) && host.count > pattern.count - 1 }
            return host == pattern
        }
    }
}

/// A secret from plugin.json: the command that reads it, and where it may go.
/// `"token": "gh auth token --hostname {host}"` goes only to the sign-in's host
/// (and its subdomains); `{"command": "op read …", "hosts": ["api.example.com"]}`
/// only to the hosts listed. A secret that names no host is refused.
public struct PluginSecret: Equatable, Sendable {
    public var command: String
    public var hosts: [String]

    public init(command: String, hosts: [String] = []) {
        self.command = command
        self.hosts = hosts
    }

    static func parse(_ any: Any) -> PluginSecret? {
        if let command = any as? String {
            return command.contains("{host}") ? PluginSecret(command: command) : nil
        }
        guard let fields = any as? [String: Any], let command = fields["command"] as? String else { return nil }
        let hosts = (fields["hosts"] as? [String] ?? []).map { $0.lowercased() }
        guard command.contains("{host}") || !hosts.isEmpty else { return nil }
        return PluginSecret(command: command, hosts: hosts)
    }
}

public enum PluginError: Error, Equatable, CustomStringConvertible {
    case manifest(String)
    case lua(String)

    public var description: String {
        switch self {
        case .manifest(let message): return "plugin.json: \(message)"
        case .lua(let message): return message
        }
    }
}

// MARK: What a plugin shows

public enum PluginState: String, Sendable {
    case good, warn, bad, info, idle

    /// Accepts the obvious synonyms, so `status = r.conclusion` mostly just works.
    public init(loose: String?) {
        switch loose?.lowercased() {
        case "good", "ok", "success", "passed", "done", "green": self = .good
        case "warn", "warning", "running", "pending", "in_progress", "queued", "yellow": self = .warn
        case "bad", "error", "failure", "failed", "red", "cancelled", "timed_out": self = .bad
        case "info", "blue", "new": self = .info
        default: self = .idle
        }
    }
}

/// An icon on the closed notch while it's true.
public struct PluginBadge: Equatable, Sendable {
    public var icon: String
    public var count: Int?
    public var state: PluginState
    public var help: String

    public init(icon: String, count: Int? = nil, state: PluginState = .info, help: String = "") {
        self.icon = icon
        self.count = count
        self.state = state
        self.help = help
    }
}

public struct PluginRow: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var status: PluginState
    public var url: URL?
    public var time: Date?

    public init(title: String, detail: String = "", status: PluginState = .idle, url: URL? = nil, time: Date? = nil) {
        self.title = title
        self.detail = detail
        self.status = status
        self.url = url
        self.time = time
    }
}

public struct PluginSection: Equatable, Sendable {
    public var title: String
    public var rows: [PluginRow]

    public init(title: String, rows: [PluginRow]) {
        self.title = title
        self.rows = rows
    }
}

/// Everything a plugin shows at the moment: its badge, and either a custom
/// view or plain sections of rows.
public struct PluginOutput: Equatable, Sendable {
    public var badge: PluginBadge?
    public var sections: [PluginSection]
    public var view: PluginNode?

    public init(badge: PluginBadge? = nil, sections: [PluginSection] = [], view: PluginNode? = nil) {
        self.badge = badge
        self.sections = sections
        self.view = view
    }
}

/// A few seconds of news in the closed notch.
public struct PluginPeek: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var state: PluginState
    public var icon: String?

    public init(title: String, subtitle: String = "", state: PluginState = .info, icon: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.icon = icon
    }
}

// MARK: What Visor does for a plugin

public struct PluginRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
}

public struct PluginResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]
    /// Answered from Visor's cache because the server said nothing changed (304).
    public var cached: Bool

    public init(status: Int, body: Data, headers: [String: String], cached: Bool) {
        self.status = status
        self.body = body
        self.headers = headers
        self.cached = cached
    }
}

/// A git repo one of your agents is working in.
public struct PluginRepo: Equatable, Sendable {
    public var host: String
    public var owner: String
    public var name: String
    public var branch: String?
    public var path: String

    public init(host: String, owner: String, name: String, branch: String?, path: String) {
        self.host = host
        self.owner = owner
        self.name = name
        self.branch = branch
        self.path = path
    }

    /// host, owner and repo from a remote URL (ssh, scp-style or https).
    public static func parseRemote(_ remote: String) -> (String, String, String)? {
        var rest = remote.trimmingCharacters(in: .whitespaces)
        var host: Substring
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
            if let at = rest.firstIndex(of: "@"), at < (rest.firstIndex(of: "/") ?? rest.endIndex) { rest = String(rest[rest.index(after: at)...]) }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = rest[..<slash]
            rest = String(rest[rest.index(after: slash)...])
        } else if let colon = rest.firstIndex(of: ":"), rest.contains("@") {
            host = rest[rest.index(after: rest.firstIndex(of: "@")!)..<colon]
            rest = String(rest[rest.index(after: colon)...])
        } else {
            return nil
        }
        if let port = host.firstIndex(of: ":") { host = host[..<port] }
        let parts = rest.split(separator: "/")
        guard parts.count >= 2, !host.isEmpty else { return nil }
        var name = String(parts[parts.count - 1])
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return (String(host).lowercased(), String(parts[parts.count - 2]), name)
    }

    /// The url of [remote "origin"] in a .git/config.
    public static func originURL(gitConfig: String) -> String? {
        var inOrigin = false
        for line in gitConfig.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") { inOrigin = text == #"[remote "origin"]"#; continue }
            if inOrigin, text.hasPrefix("url"), let eq = text.firstIndex(of: "=") {
                return text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The checked-out branch from .git/HEAD; nil when detached.
    public static func branch(head: String) -> String? {
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("ref: refs/heads/") else { return nil }
        return String(text.dropFirst("ref: refs/heads/".count))
    }
}

/// What Visor provides a plugin. Called on the plugin's own queue.
public protocol PluginHost: AnyObject {
    func request(_ request: PluginRequest) -> PluginResponse
    func secret(_ name: String, host: String?) -> String?
    func repos() -> [PluginRepo]
    func log(_ line: String)
    func show(_ output: PluginOutput)
    func peek(_ peek: PluginPeek)
    func failed(_ message: String)
    func saveStore(_ data: Data)
}

/// How a plugin's secret is read: the command from plugin.json, if it's one
/// that only reads a saved sign-in. Run without a shell, so nothing is expanded.
public enum PluginSecrets {
    public static func command(_ template: String, host: String?) -> [String]? {
        if let host, host.range(of: #"^[A-Za-z0-9.-]{1,253}$"#, options: .regularExpression) == nil { return nil }
        let words = template.split(separator: " ").map { $0 == "{host}" ? (host ?? "") : String($0) }
        guard !words.contains(where: \.isEmpty), let tool = words.first else { return nil }
        switch tool {
        case "gh": return Array(words.prefix(3)) == ["gh", "auth", "token"] ? words : nil
        case "op": return words.count >= 3 && words[1] == "read" ? words : nil
        case "security": return ["find-generic-password", "find-internet-password"].contains(words.dropFirst().first ?? "") ? words : nil
        default: return nil
        }
    }
}

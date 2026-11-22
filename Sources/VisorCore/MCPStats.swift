import Foundation

/// An MCP tool call's server and tool, read from a hook's tool name.
public struct MCPTool: Equatable, Sendable {
    public let server: String
    public let tool: String

    public init(server: String, tool: String) {
        self.server = server
        self.tool = tool
    }

    /// `mcp__<server>__<tool>` from any agent (a configured name containing "__" is tried first,
    /// longest first, then the first "__" split); Copilot's `<server>-<tool>` only for a
    /// server named in its config (longest name first). Built-in tools give nil.
    public static func parse(_ name: String, provider: String, configured: Set<String> = []) -> MCPTool? {
        if name.hasPrefix("mcp__") {
            let rest = name.dropFirst(5)
            let doubled = Set(configured.map(sanitised).filter { $0.contains("__") })
            for server in longestFirst(doubled) where rest.hasPrefix(server + "__") && rest.count > server.count + 2 {
                return make(server, String(rest.dropFirst(server.count + 2)))
            }
            guard let split = rest.range(of: "__") else { return nil }
            return make(String(rest[..<split.lowerBound]), String(rest[split.upperBound...]))
        }
        guard provider == "copilot" else { return nil }
        for server in longestFirst(configured) where name.hasPrefix(server + "-") {
            return make(server, String(name.dropFirst(server.count + 1)))
        }
        return nil
    }

    /// A server name as Claude Code writes it into tool names: anything outside
    /// letters, digits, "_" and "-" becomes "_" ("claude.ai Figma" is `claude_ai_Figma`).
    public static func sanitised(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
    }

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    private static func longestFirst(_ names: Set<String>) -> [String] {
        names.sorted { ($0.count, $0) > ($1.count, $1) }
    }

    private static func make(_ server: String, _ tool: String) -> MCPTool? {
        guard MCPConfig.isValidName(server), MCPConfig.isValidName(tool) else { return nil }
        return MCPTool(server: server, tool: tool)
    }
}

public struct MCPToolCount: Equatable, Sendable {
    public let tool: String
    public let calls: Int
}

/// "figma failed 3x in web-shop".
public struct MCPFailure: Equatable, Sendable {
    public let server: String
    public let count: Int
    /// The project's folder name.
    public let project: String
}

/// One server's health: configured, seen working, or failing recently.
public struct MCPServerHealth: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// In a config (or failed long ago) with no recent sign either way. Visor never starts servers.
        case configured
        case working
        /// The last call failed; the count is failures in the window.
        case failing(Int)
    }

    public let server: String
    public let state: State
    /// Agents whose configs name it.
    public let agents: [String]
    /// Agents seen calling it.
    public let seenBy: [String]
    public let configured: Bool
    public let lastWorking: Date?
    public let topTools: [MCPToolCount]
}

/// MCP calls seen in hook events, per server, tool and project. Event-driven and capped;
/// stores only names, counts and dates, never tool input or output.
public struct MCPStats: Equatable, Sendable {
    public static let maxServers = 32
    public static let maxTools = 16
    public static let maxProjects = 16
    public static let maxFailures = 20
    /// Failures count only this recently.
    public static let window: TimeInterval = 86_400

    public struct Project: Equatable, Sendable {
        public var calls = 0
        public var failedAt: [Date] = []
        public var lastSeen: Date
    }

    public struct Server: Equatable, Sendable {
        public var lastSeen: Date
        public var lastWorking: Date?
        public var lastFailed: Date?
        public var tools: [String: Int] = [:]
        /// Keyed by the event's cwd ("" when it had none).
        public var projects: [String: Project] = [:]
        public var agents: Set<String> = []

        public func failures(in project: String, now: Date, window: TimeInterval = MCPStats.window) -> Int {
            projects[project]?.failedAt.filter { $0 > now - window }.count ?? 0
        }

        public func failures(now: Date, window: TimeInterval = MCPStats.window) -> Int {
            projects.keys.reduce(0) { $0 + failures(in: $1, now: now, window: window) }
        }

        /// The last call failed.
        var lastCallFailed: Bool {
            guard let failed = lastFailed else { return false }
            return lastWorking.map { failed >= $0 } ?? true
        }
    }

    public private(set) var servers: [String: Server] = [:]

    public init() {}

    /// Counts a finished MCP call (`PostToolUse` or `PostToolUseFailure`). `configured` is the
    /// configured server names, needed for Copilot's dashed names and names containing "__".
    /// Returns whether anything changed.
    @discardableResult
    public mutating func record(_ message: HookMessage, configured: Set<String> = [], at now: Date) -> Bool {
        let failed = message.event == "PostToolUseFailure"
        guard failed || message.event == "PostToolUse", let name = message.toolName,
              let call = MCPTool.parse(name, provider: message.provider, configured: configured) else { return false }
        let project = Self.project(message.cwd)

        if servers[call.server] == nil, servers.count >= Self.maxServers,
           let oldest = servers.min(by: { ($0.value.lastSeen, $0.key) < ($1.value.lastSeen, $1.key) }) {
            servers[oldest.key] = nil
        }
        var server = servers[call.server] ?? Server(lastSeen: now)
        server.lastSeen = now
        server.agents.insert(AgentBoard.agentName(message.provider))
        if failed { server.lastFailed = now } else { server.lastWorking = now }

        if server.tools[call.tool] == nil, server.tools.count >= Self.maxTools,
           let least = server.tools.min(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            server.tools[least.key] = nil
        }
        server.tools[call.tool, default: 0] += 1

        if server.projects[project] == nil, server.projects.count >= Self.maxProjects,
           let oldest = server.projects.min(by: { ($0.value.lastSeen, $0.key) < ($1.value.lastSeen, $1.key) }) {
            server.projects[oldest.key] = nil
        }
        var entry = server.projects[project] ?? Project(lastSeen: now)
        entry.lastSeen = now
        entry.calls += 1
        if failed {
            entry.failedAt.append(now)
            if entry.failedAt.count > Self.maxFailures { entry.failedAt.removeFirst(entry.failedAt.count - Self.maxFailures) }
        }
        server.projects[project] = entry
        servers[call.server] = server
        return true
    }

    /// The event's cwd when it is a plausible absolute path, otherwise "" (unknown):
    /// at most 1024 characters, no control or bidi/format characters.
    static func project(_ cwd: String?) -> String {
        guard let cwd, cwd.hasPrefix("/"), cwd.count <= 1024,
              !cwd.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format })
        else { return "" }
        return cwd
    }

    /// The server's most-called tools, by count then name.
    public func topTools(server: String, limit: Int = 3) -> [MCPToolCount] {
        (servers[server]?.tools ?? [:])
            .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .prefix(limit)
            .map { MCPToolCount(tool: $0.key, calls: $0.value) }
    }

    /// Recent failures per server and known project, most first.
    public func failureSummary(now: Date, window: TimeInterval = MCPStats.window) -> [MCPFailure] {
        var out: [MCPFailure] = []
        for (name, server) in servers {
            for project in server.projects.keys where !project.isEmpty {
                let count = server.failures(in: project, now: now, window: window)
                if count > 0 {
                    out.append(MCPFailure(server: name, count: count, project: (project as NSString).lastPathComponent))
                }
            }
        }
        return out.sorted { ($1.count, $0.server, $0.project) < ($0.count, $1.server, $1.project) }
    }

    /// Configured servers joined with what events showed, plus servers seen only in events. Config
    /// names are matched after Claude Code's sanitising, so "acme.docs" joins `mcp__acme_docs__*`.
    /// A configured server keeps its config name. Sorted by name.
    public func health(configured: [MCPServerRef], now: Date, window: TimeInterval = MCPStats.window) -> [MCPServerHealth] {
        var groups: [String: (names: Set<String>, agents: Set<String>)] = [:]
        for ref in configured { groups[MCPTool.sanitised(ref.name), default: ([], [])].names.insert(ref.name) }
        for ref in configured { groups[MCPTool.sanitised(ref.name)]?.agents.insert(ref.agent) }
        var seen: [String: String] = [:]
        for key in servers.keys.sorted() where seen[MCPTool.sanitised(key)] == nil { seen[MCPTool.sanitised(key)] = key }

        var out: [MCPServerHealth] = []
        for (key, group) in groups {
            out.append(health(name: group.names.sorted()[0], statsKey: seen[key], agents: group.agents, now: now, window: window))
        }
        for (key, statsKey) in seen where groups[key] == nil {
            out.append(health(name: statsKey, statsKey: statsKey, agents: [], now: now, window: window))
        }
        return out.sorted { $0.server < $1.server }
    }

    private func health(name: String, statsKey: String?, agents: Set<String>, now: Date, window: TimeInterval) -> MCPServerHealth {
        let server = statsKey.flatMap { servers[$0] }
        var state = MCPServerHealth.State.configured
        if let server {
            let recent = server.failures(now: now, window: window)
            if server.lastCallFailed {
                if recent > 0 { state = .failing(recent) }
            } else if server.lastWorking != nil {
                state = .working
            }
        }
        return MCPServerHealth(server: name, state: state, agents: agents.sorted(), seenBy: (server?.agents ?? []).sorted(),
                               configured: !agents.isEmpty, lastWorking: server?.lastWorking,
                               topTools: statsKey.map { topTools(server: $0) } ?? [])
    }
}

import Foundation

/// One MCP server an agent has configured: only its name and where it is set.
/// Values (command, args, env, headers, URLs) can hold secrets and are never kept.
public struct MCPServerRef: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        case global
        /// Set for one project folder (absolute path).
        case project(String)
    }

    public let agent: String
    public let scope: Scope
    public let name: String

    public init(agent: String, scope: Scope, name: String) {
        self.agent = agent
        self.scope = scope
        self.name = name
    }
}

/// Reads which MCP servers each agent has configured, names only. Servers are never started.
public enum MCPConfig {
    /// Files bigger than this are skipped (~/.claude.json grows with history).
    public static let maxFileSize = 8 * 1024 * 1024
    public static let maxNameLength = 64
    public static let maxServersPerFile = 64
    public static let maxProjects = 64

    /// Config file names, relative to the home folder or to a project folder.
    /// `read` and `paths` both use these, so change detection covers every file read.
    enum Files {
        static let claude = ".claude.json"
        static let claudeProject = ".mcp.json"
        static let copilot = ".copilot/mcp-config.json"
        static let codex = ".codex/config.toml"
        static let gemini = ".gemini/settings.json"
        static let antigravity = ".gemini/config/mcp_config.json"
        static let openCodeGlobal = ".config/opencode"
        static let openCode = ["opencode.json", "opencode.jsonc"]
    }

    /// Folders under the home that macOS guards with a privacy prompt (or that iCloud may
    /// have to download): never opened, so a session there can't make Visor ask for access.
    static let protectedFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]

    /// The project folders worth opening, from session cwds most recent first: only the home
    /// folder and folders inside it (no other users, /Volumes, network mounts), none in
    /// `protectedFolders`, deduplicated, the `maxProjects` most recent, sorted.
    public static func projectFolders(_ cwds: [String], home: String) -> [String] {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        let guarded = protectedFolders.map { home + "/" + $0 }
        var seen = Set<String>(), kept: [String] = []
        for cwd in cwds where kept.count < maxProjects {
            let path = cwd.count > 1 && cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            guard path == home || path.hasPrefix(home + "/"),
                  !guarded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  seen.insert(path).inserted else { continue }
            kept.append(path)
        }
        return kept.sorted()
    }

    /// Every file `read(home:projects:)` may open, for change detection (`MCPConfigStamp`).
    public static func paths(home: URL, projects: [String]) -> [String] {
        func join(_ folder: String, _ name: String) -> String { (folder as NSString).appendingPathComponent(name) }
        let openCodeHome = join(home.path, Files.openCodeGlobal)
        var out = [Files.claude, Files.copilot, Files.codex, Files.gemini, Files.antigravity].map { join(home.path, $0) }
            + Files.openCode.map { join(openCodeHome, $0) }
        for folder in projectFolders(projects, home: home.path) {
            out += [Files.claudeProject, Files.gemini].map { join(folder, $0) } + Files.openCode.map { join(folder, $0) }
        }
        return out
    }

    /// Every configured server, from the global config files under `home` and the
    /// project files in `projects` (absolute folder paths, such as agent cwds).
    public static func read(home: URL, projects: [String]) -> [MCPServerRef] {
        var refs: [MCPServerRef] = []
        func add(_ agent: String, _ scope: MCPServerRef.Scope, _ names: [String]) {
            refs += names.map { MCPServerRef(agent: agent, scope: scope, name: $0) }
        }
        let folders = projectFolders(projects, home: home.path)

        // Claude Code: ~/.claude.json (global and per project) plus each project's .mcp.json.
        let claude = file(home, Files.claude).flatMap(claudeConfig) ?? ClaudeConfig()
        add("Claude Code", .global, claude.global)
        for (path, servers) in claude.projects.sorted(by: { $0.key < $1.key }) where path.hasPrefix("/") {
            add("Claude Code", .project(path), servers)
        }
        for folder in folders {
            let disabled = claude.disabled[folder] ?? []
            let names = file(folder, Files.claudeProject).map { serverNames($0, key: "mcpServers") } ?? []
            add("Claude Code", .project(folder), names.filter { !disabled.contains($0) })
        }

        add("Copilot CLI", .global, file(home, Files.copilot).map { serverNames($0, key: "mcpServers") } ?? [])
        add("Codex CLI", .global, file(home, Files.codex).map(codexTOML) ?? [])

        add("Gemini CLI", .global, file(home, Files.gemini).map { serverNames($0, key: "mcpServers") } ?? [])
        for folder in folders {
            add("Gemini CLI", .project(folder), file(folder, Files.gemini).map { serverNames($0, key: "mcpServers") } ?? [])
        }

        add("Antigravity", .global, file(home, Files.antigravity).map { serverNames($0, key: "mcpServers") } ?? [])

        add("OpenCode", .global, openCode(in: home.appendingPathComponent(Files.openCodeGlobal).path))
        for folder in folders {
            add("OpenCode", .project(folder), openCode(in: folder))
        }

        var seen = Set<MCPServerRef>()
        return refs.filter { seen.insert($0).inserted }
    }

    /// The server names under `key` in a JSON (or, with `json5`, JSONC) object.
    static func serverNames(_ data: Data, key: String, json5: Bool = false) -> [String] {
        autoreleasepool {
            guard let object = jsonObject(data, json5: json5) else { return [] }
            return names(in: object[key])
        }
    }

    /// A name Visor will keep: non-empty, at most 64 characters, no control or format (bidi, zero-width) characters.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= maxNameLength
            && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
    }

    struct ClaudeConfig {
        var global: [String] = []
        var projects: [String: [String]] = [:]
        var disabled: [String: Set<String>] = [:]
    }

    /// ~/.claude.json: top-level servers, per-project servers and the project's disabled .mcp.json names.
    static func claudeConfig(_ data: Data) -> ClaudeConfig? {
        autoreleasepool {
            guard let object = jsonObject(data, json5: false) else { return nil }
            var config = ClaudeConfig()
            config.global = names(in: object["mcpServers"])
            for (path, value) in object["projects"] as? [String: Any] ?? [:] {
                guard let project = value as? [String: Any] else { continue }
                let servers = names(in: project["mcpServers"])
                if !servers.isEmpty { config.projects[path] = servers }
                if let off = project["disabledMcpjsonServers"] as? [String] {
                    config.disabled[path] = Set(off.prefix(maxServersPerFile).filter(isValidName))
                }
            }
            if config.projects.count > maxProjects {
                let keep = Set(config.projects.keys.sorted().prefix(maxProjects))
                config.projects = config.projects.filter { keep.contains($0.key) }
            }
            return config
        }
    }

    /// Server names in a Codex config.toml, from table headers (`[mcp_servers.name]`, also with
    /// spaces around the dot, quoted names and sub-tables), keys under a bare `[mcp_servers]`
    /// table (`name = {...}`, `name.command = ...`) and root keys `mcp_servers.name.x = ...`.
    /// Values are never parsed; lines inside multi-line strings and lines over 512 characters are skipped.
    static func codexTOML(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var names = Set<String>()
        var table: String?  // nil at the root, "mcp_servers" in the bare table, "" elsewhere
        var inString: String?  // the open multi-line string delimiter
        for raw in text.split(whereSeparator: \.isNewline) {
            if names.count >= maxServersPerFile { break }
            let line = String(raw)
            if let delimiter = inString {
                if line.components(separatedBy: delimiter).count % 2 == 0 { inString = nil }
                continue
            }
            if line.count <= 512 {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                    if tomlMatch(bareTable, line) != nil { table = "mcp_servers" }
                    else {
                        table = ""
                        if let name = tomlMatch(tableHeader, line) { names.insert(name) }
                    }
                } else if table == "mcp_servers", let name = tomlMatch(tableKey, line) {
                    names.insert(name)
                } else if table == nil, let name = tomlMatch(rootKey, line) {
                    names.insert(name)
                }
            }
            for delimiter in multiline where line.components(separatedBy: delimiter).count % 2 == 0 {
                inString = delimiter
                break
            }
        }
        return names.filter(isValidName).sorted()
    }

    private static let multiline = [String(repeating: "\"", count: 3), "'''"]

    /// A TOML key: bare, "basic" or 'literal'; its name is in group 1, 2 or 3.
    private static let tomlKey = #"(?:"([^"\\]*)"|'([^']*)'|([A-Za-z0-9_-]+))"#
    private static let bareTable = try! NSRegularExpression(pattern: #"^\s*\[\s*mcp_servers\s*\]"#)
    private static let tableHeader = try! NSRegularExpression(pattern: #"^\s*\[\s*mcp_servers\s*\.\s*"# + tomlKey + #"\s*(?:[.\]])"#)
    private static let tableKey = try! NSRegularExpression(pattern: #"^\s*"# + tomlKey + #"\s*[.=]"#)
    private static let rootKey = try! NSRegularExpression(pattern: #"^\s*mcp_servers\s*\.\s*"# + tomlKey + #"\s*[.=]"#)

    private static func tomlMatch(_ regex: NSRegularExpression, _ line: String) -> String? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        for group in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: group), in: line) { return String(line[range]) }
        }
        return ""
    }

    /// OpenCode's `mcp` object from opencode.json or opencode.jsonc in `folder`.
    static func openCode(in folder: String) -> [String] {
        let names = Files.openCode.flatMap { file(folder, $0).map { serverNames($0, key: "mcp", json5: true) } ?? [] }
        return Array(Set(names)).sorted()
    }

    private static func names(in value: Any?) -> [String] {
        Array(((value as? [String: Any])?.keys.filter(isValidName) ?? []).sorted().prefix(maxServersPerFile))
    }

    private static func jsonObject(_ data: Data, json5: Bool) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data, options: json5 ? .json5Allowed : []) as? [String: Any]
    }

    private static func file(_ folder: URL, _ name: String) -> Data? { file(folder.path, name) }

    /// A file's bytes, or nil when it is missing, empty, not a regular file or bigger than
    /// `maxFileSize`. Symlinks are followed (dotfile setups); the opened descriptor is checked,
    /// and opened non-blocking, so a FIFO or device can never block the read.
    private static func file(_ folder: String, _ name: String) -> Data? {
        let path = (folder as NSString).appendingPathComponent(name)
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxFileSize,
              let data = try? handle.read(upToCount: maxFileSize + 1), !data.isEmpty, data.count <= maxFileSize else { return nil }
        return data
    }
}

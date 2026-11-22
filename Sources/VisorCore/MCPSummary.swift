import Darwin
import Foundation

/// One server in the Agents tab's MCP list: what it shows, no dates or counts, so the
/// notch redraws only when something visible changes.
public struct MCPRow: Equatable, Sendable {
    public let server: String
    /// Agents whose configs name it, plus agents seen calling it.
    public let agents: [String]
    public let state: MCPServerHealth.State
    /// "working", "failed 3x in web-shop", "configured".
    public let stateText: String
    /// Most-called tool names, most first.
    public let tools: [String]
}

/// The MCP line under the sessions ("MCP 4 · figma failed 3x in web-shop") and its list.
public struct MCPSummary: Equatable, Sendable {
    public static let maxRows = 6
    public static let rowHeight = 28.0
    public static let headerHeight = 16.0
    public static let moreHeight = 16.0
    /// Longer project names are cut in the middle, so a row never outgrows the panel.
    public static let maxProjectLength = 32

    /// Servers configured or seen.
    public let count: Int
    /// The part after "MCP n": the worst failure, "all working", ... or "configured".
    public let detail: String
    public let line: String
    /// A server's last call failed recently.
    public let failing: Bool
    /// At most `maxRows`: failing first, then working, then configured, each by name.
    public let rows: [MCPRow]
    /// Servers past `maxRows`.
    public let more: Int

    /// The open list's height: padding, header, rows and the "+n more" line.
    public var listHeight: Double {
        12 + Self.headerHeight + Double(rows.count) * Self.rowHeight + (more > 0 ? Self.moreHeight : 0)
    }

    /// Nil when no server is configured or seen (the line is hidden).
    public static func make(health: [MCPServerHealth], failures: [MCPFailure]) -> MCPSummary? {
        guard !health.isEmpty else { return nil }
        // failureSummary is most first, so the first match per server is its worst project.
        var worst: [String: MCPFailure] = [:]
        for failure in failures where worst[MCPTool.sanitised(failure.server)] == nil {
            worst[MCPTool.sanitised(failure.server)] = failure
        }
        var all: [(row: MCPRow, rank: Int, failed: Int)] = []
        for server in health {
            let rank: Int, text: String, failed: Int
            switch server.state {
            case .failing(let total):
                let place = worst[MCPTool.sanitised(server.server)]
                failed = place?.count ?? total
                text = "failed \(failed)x" + (place.map { " in \(short($0.project))" } ?? "")
                rank = 0
            case .working: (rank, text, failed) = (1, "working", 0)
            case .configured: (rank, text, failed) = (2, "configured", 0)
            }
            let agents = Array(Set(server.agents + server.seenBy)).sorted()
            all.append((MCPRow(server: server.server, agents: agents, state: server.state, stateText: text,
                               tools: server.topTools.map(\.tool)), rank, failed))
        }
        all.sort { ($0.rank, $0.row.server) < ($1.rank, $1.row.server) }

        let working = all.filter { $0.rank == 1 }.count
        let configured = all.filter { $0.rank == 2 }.count
        let detail: String
        let worstRow = all.filter { $0.rank == 0 }.max { ($0.failed, $1.row.server) < ($1.failed, $0.row.server) }
        if let worstRow {
            detail = "\(worstRow.row.server) \(worstRow.row.stateText)"
        } else if working == all.count {
            detail = "all working"
        } else if working > 0 {
            detail = "\(working) working, \(configured) configured"
        } else {
            detail = "configured"
        }
        let line = worstRow == nil && working == 0 ? "MCP \(all.count) configured" : "MCP \(all.count) · \(detail)"
        return MCPSummary(count: all.count, detail: detail, line: line, failing: worstRow != nil,
                          rows: all.prefix(maxRows).map(\.row), more: max(0, all.count - maxRows))
    }
}

extension MCPSummary {
    /// `name` cut in the middle to at most `maxProjectLength` characters.
    static func short(_ name: String) -> String {
        guard name.count > maxProjectLength else { return name }
        let head = (maxProjectLength - 1) / 2, tail = maxProjectLength - 1 - head
        return String(name.prefix(head)) + "…" + String(name.suffix(tail))
    }
}

/// When to stat and read the MCP config files: one check at a time; a request during a
/// check queues one more; a check reads only when the folders changed since the last read
/// (`last` nil) or, on the work queue, when the stamp differs from `last`.
public struct MCPRefresh: Equatable, Sendable {
    public struct Check: Equatable, Sendable {
        public let folders: [String]
        /// The stamp of the last read of these folders; nil forces a read.
        public let last: MCPConfigStamp?

        public static func check(folders: [String], last: MCPConfigStamp?) -> Check { Check(folders: folders, last: last) }
    }

    public private(set) var folders: [String] = []
    private var readFolders: [String]?
    private var stamp: MCPConfigStamp?
    private var running = false
    private var queued = false

    public init() {}

    /// The project folders to read now. Returns whether they changed.
    @discardableResult
    public mutating func want(folders: [String]) -> Bool {
        guard folders != self.folders else { return false }
        self.folders = folders
        return true
    }

    /// A check to run now, or nil when one is running (it queues one more).
    public mutating func request() -> Check? {
        guard !running else { queued = true; return nil }
        running = true
        return .check(folders: folders, last: readFolders == folders ? stamp : nil)
    }

    /// A check ended with `stamp` for `folders`; returns the queued check, if any.
    public mutating func finished(folders: [String], stamp: MCPConfigStamp) -> Check? {
        running = false
        readFolders = folders
        self.stamp = stamp
        guard queued else { return nil }
        queued = false
        return request()
    }
}

/// Size and modification time of each config file, to tell whether one changed
/// without reading it. Missing files have no entry.
public struct MCPConfigStamp: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let size: Int64
        public let seconds: Int
        public let nanoseconds: Int
    }

    public let entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    public static func of(paths: [String]) -> MCPConfigStamp {
        var entries: [String: Entry] = [:]
        for path in paths {
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            entries[path] = Entry(size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
        }
        return MCPConfigStamp(entries: entries)
    }
}

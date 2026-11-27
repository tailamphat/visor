import Darwin
import Foundation

/// What one earlier Claude Code session of a project tells the MCP advice: which servers
/// its harness listed (by `XRayScanner.key`, with their tokens) and which it called.
/// Only keys and counts, never text.
public struct PastSession: Equatable, Codable, Sendable {
    public var servers: [String: Int]
    public var called: Set<String>

    public init(servers: [String: Int], called: Set<String>) {
        self.servers = servers
        self.called = called
    }
}

/// Reads an earlier session's transcript (and its helpers' `subagents/*.jsonl`) once:
/// the X-ray of its head, and every MCP tool it called.
public enum PastSessionScan {
    private static let callMarker = Array(#""name":"mcp__"#.utf8)
    private static let toolUse = Array(#""tool_use""#.utf8)

    /// Nil when the transcript can't be read or isn't a regular file (a link or a pipe).
    public static func read(_ path: String) -> PastSession? {
        guard isRegularFile(path), FileManager.default.isReadableFile(atPath: path) else { return nil }
        var scanner = XRayScanner()
        var called = Set<String>()
        _ = TranscriptUsage.readLines(of: path, from: 0) { data in
            if !scanner.isDone { scanner.ingest(data) }
            calls(in: data, into: &called)
        }
        let helpers = (path as NSString).deletingPathExtension + "/subagents"
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: helpers)) ?? [])
        where file.hasSuffix(".jsonl") && isRegularFile(helpers + "/" + file) {
            _ = TranscriptUsage.readLines(of: helpers + "/" + file, from: 0) { calls(in: $0, into: &called) }
        }
        var servers: [String: Int] = [:]
        for server in scanner.result?.mcp ?? [] { servers[XRayScanner.key(server.name), default: 0] += server.tokens }
        return PastSession(servers: servers, called: called)
    }

    /// Not a link, pipe or device: `attributesOfItem` doesn't follow links.
    static func isRegularFile(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// MCP servers of the `tool_use` blocks in assistant lines. Only lines holding the
    /// marker are parsed, so a long transcript costs a `memmem` per line.
    static func calls(in data: Data, into called: inout Set<String>) {
        let lines: [Range<Int>] = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>] in
            guard let base = raw.baseAddress else { return [] }
            var found: [Range<Int>] = []
            var start = 0
            while start < raw.count {
                guard let hit = memmem(base + start, raw.count - start, callMarker, callMarker.count) else { break }
                let at = UnsafeRawPointer(hit) - base
                var lineStart = at
                while lineStart > start, raw[lineStart - 1] != 0x0A { lineStart -= 1 }
                var end = raw.count
                if let newline = memchr(base + at, 0x0A, raw.count - at) { end = UnsafeRawPointer(newline) - base }
                if memmem(base + lineStart, end - lineStart, toolUse, toolUse.count) != nil { found.append(lineStart..<end) }
                start = end + 1
            }
            return found
        }
        for range in lines {
            let line = data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String, let server = XRayScanner.server(ofTool: name) {
                    called.insert(XRayScanner.key(server))
                }
            }
        }
    }
}

/// The earlier sessions of a project, read from Claude Code's own transcript folder:
/// each file once, cached by size and modification time. Not thread-safe: use it
/// from one queue.
public final class ProjectHistory: @unchecked Sendable {
    private struct Entry { var size: UInt64; var modified: Date; var session: PastSession? }
    private var cache: [String: Entry] = [:]
    /// Transcripts read, for tests.
    public private(set) var reads = 0

    public init() {}

    /// Whether `folder` is one project folder right inside one of `roots` (Claude Code's
    /// `projects` folders), so a hook's `transcript_path` can't point the scan anywhere else.
    public static func isProjectFolder(_ folder: String, roots: [String]) -> Bool {
        let parent = ((folder as NSString).standardizingPath as NSString).deletingLastPathComponent
        return roots.contains { ($0 as NSString).standardizingPath == parent }
    }

    /// The newest `limit` sessions in `folder` before `current`, newest first. Left out:
    /// `current`, the `live` sessions' transcripts (still running, so not "earlier"), files
    /// changed after `current` was created, and anything that isn't a regular file.
    public func earlier(in folder: String, excluding current: String, live: Set<String> = [],
                        limit: Int = MCPAdvice.recentSessions) -> [PastSession] {
        let currentPath = (current as NSString).standardizingPath
        let skip = Set(live.map { ($0 as NSString).standardizingPath }).union([currentPath])
        let started = (try? FileManager.default.attributesOfItem(atPath: currentPath))?[.creationDate] as? Date
        var files: [(path: String, size: UInt64, modified: Date)] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
            let path = ((folder as NSString).appendingPathComponent(name) as NSString).standardizingPath
            guard !skip.contains(path), let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date,
                  started.map({ modified <= $0 }) ?? true else { continue }
            files.append((path, (attributes[.size] as? NSNumber)?.uint64Value ?? 0, modified))
        }
        let chosen = files.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path }.prefix(limit)
        var sessions: [PastSession] = []
        for file in chosen {
            if let entry = cache[file.path], entry.size == file.size, entry.modified == file.modified {
                if let session = entry.session { sessions.append(session) }
                continue
            }
            reads += 1
            let session = autoreleasepool { PastSessionScan.read(file.path) }
            cache[file.path] = Entry(size: file.size, modified: file.modified, session: session)
            if let session { sessions.append(session) }
        }
        // Keep only what this folder still needs.
        let keep = Set(chosen.map(\.path))
        let prefix = (folder as NSString).standardizingPath + "/"
        cache = cache.filter { !$0.key.hasPrefix(prefix) || keep.contains($0.key) }
        return sessions
    }
}

/// "figma MCP · about 12k tokens a session / Not called in 5 of the last 5 web-shop sessions."
public struct MCPAdvice: Equatable, Sendable {
    public static let recentSessions = 5
    public static let minSessions = 3
    public static let minTokens = 1_000

    public let server: String
    public let tokens: Int
    public let notCalled: Int
    public let sessions: Int
    public let project: String

    public init(server: String, tokens: Int, notCalled: Int, sessions: Int, project: String) {
        self.server = server
        self.tokens = tokens
        self.notCalled = notCalled
        self.sessions = sessions
        self.project = project
    }

    /// The session called this server after all (`mcp__<server>__<tool>`).
    public func isAnswered(byTool name: String) -> Bool {
        XRayScanner.server(ofTool: name).map { XRayScanner.key($0) == XRayScanner.key(server) } ?? false
    }

    public var title: String { "\(server) MCP · about \(HarnessSummary.short(tokens)) tokens a session" }
    public var detail: String { "Not called in \(notCalled) of the last \(sessions) \(project) sessions." }

    /// The biggest server in `current` (at least `minTokens`) that at least `minSessions` of
    /// `past` listed and at least 80% of those didn't call.
    public static func make(current: HarnessXRay, project: String, past: [PastSession]) -> MCPAdvice? {
        var best: MCPAdvice?
        for server in current.mcp where server.tokens >= minTokens {
            let key = XRayScanner.key(server.name)
            let listing = past.filter { $0.servers[key] != nil }
            guard listing.count >= minSessions else { continue }
            let notCalled = listing.filter { !$0.called.contains(key) }.count
            guard notCalled * 5 >= listing.count * 4 else { continue }
            if best.map({ server.tokens > $0.tokens }) ?? true {
                best = MCPAdvice(server: server.name, tokens: server.tokens, notCalled: notCalled, sessions: listing.count, project: project)
            }
        }
        return best
    }
}

/// One part of a row's bar.
public struct HarnessPart: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case systemAndTools, mcp, instructions, skills, prompt }
    public let kind: Kind
    public let tokens: Int
    /// Its share of the bar (0...1); the shares add up to 1 even when estimates ran over.
    public let share: Double
}

/// One session in the Harness list.
public struct HarnessRow: Equatable, Sendable, Identifiable {
    /// The session id.
    public let id: String
    public let project: String
    /// Exact.
    public let total: Int
    /// About; zero parts left out; always in `Kind` order.
    public let parts: [HarnessPart]
    /// The bar's width against the biggest total in the list (0...1).
    public let scale: Double
    /// Hover text: the exact total and every part.
    public let help: String
}

/// The Agents tab's "Harness" line and its list: what each Claude Code session started
/// with before its first prompt, and one MCP advice. Holds only what's shown, so the
/// model changes only when the notch would.
public struct HarnessSummary: Equatable, Sendable {
    public static let maxRows = 4
    public static let headerHeight = 16.0
    public static let rowHeight = 22.0
    public static let moreHeight = 16.0
    public static let keyHeight = 18.0
    public static let adviceGap = 4.0
    public static let adviceRow = 14.0
    public static let adviceSpacing = 2.0
    /// The advice card: two lines in a banner card.
    public static var adviceHeight: Double {
        DesignComponents.Banner.height(rows: [adviceRow, adviceRow], spacing: adviceSpacing)
    }

    public let rows: [HarnessRow]
    public let more: Int
    public let advice: MCPAdvice?
    /// After "Harness ·": "41k before your first word · figma unused".
    public let detail: String

    /// The open list's height: padding, header, rows, "+n more", key and advice.
    public var listHeight: Double {
        12 + Self.headerHeight + Double(rows.count) * Self.rowHeight + (more > 0 ? Self.moreHeight : 0)
            + Self.keyHeight + (advice != nil ? Self.adviceGap + Self.adviceHeight : 0)
    }

    /// Nil when no Claude Code session has an X-ray yet. `advice` is by session id.
    public static func make(sessions: [AgentSession], advice: [String: MCPAdvice]) -> HarnessSummary? {
        let found = sessions.filter { $0.agent == "Claude Code" }.compactMap { session in session.xray.map { (session, $0) } }
            .sorted { $0.1.total != $1.1.total ? $0.1.total > $1.1.total : $0.0.project < $1.0.project }
        guard let biggest = found.first?.1.total, biggest > 0 else { return nil }
        let rows = found.prefix(maxRows).map { session, xray in
            HarnessRow(id: session.id, project: session.project, total: xray.total, parts: parts(of: xray),
                       scale: Double(xray.total) / Double(biggest), help: help(session.project, xray))
        }
        let ids = Set(found.map(\.0.id))
        let pick = advice.filter { ids.contains($0.key) }.values
            .max { ($0.tokens, $1.server) < ($1.tokens, $0.server) }
        let smallest = found.last?.1.total ?? biggest
        var detail = (smallest == biggest ? short(biggest) : "\(short(smallest))-\(short(biggest))") + " before your first word"
        if let pick { detail += " · \(pick.server) unused" }
        return HarnessSummary(rows: Array(rows), more: max(0, found.count - maxRows), advice: pick, detail: detail)
    }

    static func parts(of xray: HarnessXRay) -> [HarnessPart] {
        let all: [(HarnessPart.Kind, Int)] = [(.systemAndTools, xray.systemAndTools), (.mcp, xray.mcpTokens),
                                              (.instructions, xray.instructionTokens), (.skills, xray.skills), (.prompt, xray.prompt)]
        let shown = all.filter { $0.1 > 0 }
        let sum = Double(max(1, shown.reduce(0) { $0 + $1.1 }))
        return shown.map { HarnessPart(kind: $0.0, tokens: $0.1, share: Double($0.1) / sum) }
    }

    static func help(_ project: String, _ xray: HarnessXRay) -> String {
        func count(_ value: Int) -> String { grouped(value) }
        var lines = ["\(project): \(count(xray.total)) tokens at the first reply (exact)",
                     "about \(count(xray.systemAndTools)) system + built-in tools"]
        for server in xray.mcp { lines.append("about \(count(server.tokens)) \(server.name) (MCP, \(server.tools) tools)") }
        for file in xray.instructions {
            let components = (file.path as NSString).pathComponents.suffix(2)
            lines.append("about \(count(file.tokens)) \(components.joined(separator: "/"))")
        }
        if xray.skills > 0 { lines.append("about \(count(xray.skills)) skills") }
        if xray.prompt > 0 { lines.append("about \(count(xray.prompt)) your prompt") }
        return lines.joined(separator: "\n")
    }

    /// "41,000" whatever the locale, so the hover text reads the same everywhere.
    static func grouped(_ value: Int) -> String {
        var digits = String(abs(value)), out = ""
        while digits.count > 3 {
            out = "," + digits.suffix(3) + out
            digits.removeLast(3)
        }
        return (value < 0 ? "-" : "") + digits + out
    }

    /// "900", "12k", "1.2M".
    public static func short(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
        return "\(tokens)"
    }
}

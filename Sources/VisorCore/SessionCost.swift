import Foundation

/// What one session has cost so far at API prices, and its tokens (input,
/// output and cache writes; cache reads would dwarf the rest).
public struct SessionCost: Equatable, Codable, Sendable {
    public var dollars: Double
    public var tokens: Int
    /// Some response had a model without a price, so dollars undercount.
    public var unpriced = false

    public init(dollars: Double, tokens: Int, unpriced: Bool = false) {
        self.dollars = dollars
        self.tokens = tokens
        self.unpriced = unpriced
    }

    /// "$4.12", "$123" from $100, or "48k tok" when nothing had a price; nil
    /// below a cent or a thousand tokens.
    public var label: String? {
        if dollars >= 100 { return "$\(Int(dollars.rounded()))" }
        if dollars >= 0.005 { return String(format: "$%.2f", dollars) }
        guard unpriced, dollars == 0, tokens >= 1000 else { return nil }
        if tokens >= 1_000_000 { return String(format: "%.1fM tok", Double(tokens) / 1_000_000) }
        return "\(tokens / 1000)k tok"
    }
}

/// Where the main transcript's last reply sits against its newest real prompt, for the
/// cache clock: the transcript's own order, never two clocks compared.
public struct TurnReply: Equatable, Codable, Sendable {
    /// The newest real prompt entry's stamp.
    public var promptAt: Date
    /// How many real prompt entries the transcript holds up to it (1 for the first).
    public var promptIndex: Int
    /// The last reply was written after that prompt entry.
    public var replyAfterPrompt: Bool

    public init(promptAt: Date, promptIndex: Int, replyAfterPrompt: Bool) {
        self.promptAt = promptAt
        self.promptIndex = promptIndex
        self.replyAfterPrompt = replyAfterPrompt
    }

    /// Lines Claude Code writes as a user entry that are not something the user typed.
    private static let commandTags = ["<command-name>", "<command-message>", "<local-command-stdout>", "<local-command-caveat>"]

    /// The stamp of a user line that is a real prompt: not a tool result, meta, a helper's
    /// (sidechain) line, the compact summary, a local command or its output, and with text.
    static func promptStamp(_ object: [String: Any]) -> Date? {
        guard object["type"] as? String == "user", object["isMeta"] as? Bool != true,
              object["isSidechain"] as? Bool != true, object["isCompactSummary"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let stamp = (object["timestamp"] as? String).flatMap(ISODate.parse) else { return nil }
        let text: String?
        if let plain = message["content"] as? String {
            text = plain
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        } else {
            text = nil
        }
        guard let text else { return nil }
        let start = text.drop { $0.isWhitespace }
        return commandTags.contains { start.hasPrefix($0) } ? nil : stamp
    }
}

/// Keeps a running cost per Claude Code session from its transcript and its
/// subagents' transcripts (`<session>/subagents/*.jsonl`). Each read parses only
/// the bytes appended since the last one. Not thread-safe: use it from one queue.
public final class SessionCostReader: @unchecked Sendable {
    private struct Tally {
        var path: String
        var offsets: [String: UInt64] = [:]
        /// Responses counted, as hashes of "message id:request id": Claude Code
        /// repeats a response's usage on each of its content blocks.
        var seen = Set<Int>()
        var cost = SessionCost(dollars: 0, tokens: 0)
        /// The harness X-ray of each file, read alongside the cost until its first reply.
        var xrays: [String: XRayScanner] = [:]
        /// Each helper's stats by agent id, from its own transcript.
        var helpers: [String: HelperStats] = [:]
        /// tool_use ids counted, as hashes.
        var toolsSeen = Set<Int>()
        /// The newest reply in the main transcript (not the helpers').
        var lastReply: TokenUsage?
        /// Real prompt entries in the main transcript, the newest one's stamp, and whether
        /// `lastReply` was written after it.
        var prompts = 0
        var promptAt: Date?
        var replyAfterPrompt = false
    }

    private var tallies: [String: Tally] = [:]
    /// Bytes the last `read` consumed, for tests.
    public private(set) var lastBytesRead = 0

    public init() {}

    /// The session's cost after reading whatever is new; nil when the transcript can't be read.
    public func read(transcript path: String, session: String) -> SessionCost? {
        lastBytesRead = 0
        guard PastSessionScan.isRegularFile(path), FileManager.default.isReadableFile(atPath: path) else { return nil }
        var tally = tallies[session].flatMap { $0.path == path ? $0 : nil } ?? Tally(path: path)
        let subagents = (path as NSString).deletingPathExtension + "/subagents"
        // Regular files only: a link or a pipe in a transcript folder is never followed.
        let extra = (isLink(subagents) ? [] : ((try? FileManager.default.contentsOfDirectory(atPath: subagents)) ?? []))
            .filter { $0.hasSuffix(".jsonl") }.sorted().map { subagents + "/" + $0 }
            .filter(PastSessionScan.isRegularFile)
        for file in [path] + extra {
            let size = ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.uint64Value ?? 0
            let start = tally.offsets[file] ?? 0
            // The meta file is read when the helper is new or its transcript grew, until it is done.
            if file != path, let id = HelperStats.agentID(ofFile: file), tally.helpers[id]?.metaDone != true,
               size != start || tally.helpers[id] == nil {
                HelperStats.readMeta(for: file, id: id, into: &tally.helpers)
            }
            if size == start { continue }
            if size < start {
                // Rewritten: everything counted may be gone, so start the whole session over.
                tallies[session] = Tally(path: path)
                return read(transcript: path, session: session)
            }
            consume(file, from: start, into: &tally)
        }
        tallies[session] = tally
        return tally.cost
    }

    private func isLink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// The read offset of one of a session's files, for tests.
    public func offset(of file: String, session: String) -> UInt64? {
        tallies[session]?.offsets[file]
    }

    /// The newest reply of the session's own transcript, for the cache clock.
    public func lastReply(session: String) -> TokenUsage? {
        tallies[session]?.lastReply
    }

    /// The main transcript's last reply against its newest real prompt; nil before any prompt is read.
    public func lastTurn(session: String) -> TurnReply? {
        guard let tally = tallies[session], let promptAt = tally.promptAt else { return nil }
        return TurnReply(promptAt: promptAt, promptIndex: tally.prompts, replyAfterPrompt: tally.replyAfterPrompt)
    }

    /// The session's harness X-ray, once its first reply has been read.
    public func xray(session: String) -> HarnessXRay? {
        guard let tally = tallies[session] else { return nil }
        return tally.xrays[tally.path]?.result
    }

    /// The X-rays of the session's helpers that have replied, by agent id
    /// (from `subagents/agent-<id>.jsonl`).
    public func helperXRays(session: String) -> [String: HarnessXRay] {
        guard let tally = tallies[session] else { return [:] }
        var found: [String: HarnessXRay] = [:]
        for (file, scanner) in tally.xrays where file != tally.path {
            guard let result = scanner.result else { continue }
            var name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            if name.hasPrefix("agent-") { name.removeFirst("agent-".count) }
            found[name] = result
        }
        return found
    }

    /// What each of the session's helpers has cost and done, by agent id.
    /// Each carries its own transcript's X-ray once that has replied.
    public func helperStats(session: String) -> [String: HelperStats] {
        var stats = tallies[session]?.helpers ?? [:]
        for (id, xray) in helperXRays(session: session) where stats[id] != nil { stats[id]?.xray = xray }
        return stats
    }

    /// Lines the X-ray of one file has parsed, for tests.
    func xrayLinesParsed(of file: String, session: String) -> Int? {
        tallies[session]?.xrays[file]?.linesParsed
    }

    /// Drops the tallies of sessions that are gone.
    public func forget(keeping ids: Set<String>) {
        tallies = tallies.filter { ids.contains($0.key) }
    }

    private func consume(_ file: String, from start: UInt64, into tally: inout Tally) {
        let helperID = file == tally.path ? nil : HelperStats.agentID(ofFile: file)
        guard let end = TranscriptUsage.readLines(of: file, from: start, { data in
            if tally.xrays[file]?.isDone != true { tally.xrays[file, default: XRayScanner()].ingest(data) }
            if let helperID { HelperStats.countTools(in: data, id: helperID, seen: &tally.toolsSeen, into: &tally.helpers) }
            TranscriptUsage.forEachUsageLine(in: data, prompts: helperID == nil) { line, user in
                // A real prompt starts a turn: the reply so far is the previous turn's.
                if user, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let stamp = TurnReply.promptStamp(object) {
                    tally.prompts += 1
                    tally.promptAt = stamp
                    tally.replyAfterPrompt = false
                    return
                }
                guard let (key, usage) = TranscriptUsage.parse(line: line) else { return }
                if let helperID { tally.helpers[helperID, default: HelperStats()].context(usage) }
                if let key, !tally.seen.insert(key.hashValue).inserted { return }
                if let helperID { tally.helpers[helperID, default: HelperStats()].add(usage) }
                // A "<synthetic>" reply (API error, interrupt) used no cache: the cache clock keeps the real one.
                if helperID == nil, !HelperStats.isSynthetic(usage),
                   usage.timestamp >= (tally.lastReply?.timestamp ?? .distantPast) {
                    tally.lastReply = usage
                    tally.replyAfterPrompt = true
                }
                tally.cost.tokens += usage.input + usage.output + usage.cacheWrite5m + usage.cacheWrite1h
                if Pricing.price(for: usage.model) == nil {
                    tally.cost.unpriced = true
                } else {
                    tally.cost.dollars += Pricing.cost(of: usage)
                }
            }
        }) else { return }
        lastBytesRead += Int(end - start)
        tally.offsets[file] = end
    }
}

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
    }

    private var tallies: [String: Tally] = [:]
    /// Bytes the last `read` consumed, for tests.
    public private(set) var lastBytesRead = 0

    public init() {}

    /// The session's cost after reading whatever is new; nil when the transcript can't be read.
    public func read(transcript path: String, session: String) -> SessionCost? {
        lastBytesRead = 0
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        var tally = tallies[session].flatMap { $0.path == path ? $0 : nil } ?? Tally(path: path)
        let subagents = (path as NSString).deletingPathExtension + "/subagents"
        let extra = ((try? FileManager.default.contentsOfDirectory(atPath: subagents)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }.sorted().map { subagents + "/" + $0 }
        for file in [path] + extra {
            let size = ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.uint64Value ?? 0
            let start = tally.offsets[file] ?? 0
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

    /// The read offset of one of a session's files, for tests.
    public func offset(of file: String, session: String) -> UInt64? {
        tallies[session]?.offsets[file]
    }

    /// Drops the tallies of sessions that are gone.
    public func forget(keeping ids: Set<String>) {
        tallies = tallies.filter { ids.contains($0.key) }
    }

    private func consume(_ file: String, from start: UInt64, into tally: inout Tally) {
        guard let end = TranscriptUsage.readLines(of: file, from: start, { data in
            TranscriptUsage.forEachUsageLine(in: data) { line in
                guard let (key, usage) = TranscriptUsage.parse(line: line) else { return }
                if let key, !tally.seen.insert(key.hashValue).inserted { return }
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

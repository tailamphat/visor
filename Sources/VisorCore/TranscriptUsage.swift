import Foundation

/// Reads token usage out of Claude Code transcripts (~/.claude/projects/**/*.jsonl)
/// and keeps running totals. Files are read incrementally: each scan only parses
/// bytes appended since the last one, so rescanning is cheap.
///
/// Claude Code writes one line per content block, repeating the same usage on
/// each, so responses are de-duplicated by message id + request id.
///
/// Totals by day are kept as records arrive, so a rescan never walks all history again.
public final class TranscriptUsage: @unchecked Sendable {
    public private(set) var records: [TokenUsage] = []
    /// Cost and tokens by local day (start of day).
    public private(set) var spendDays: [Date: SpendSummary.Day] = [:]
    /// Tokens by day and model, in the ledger's shape.
    public private(set) var tokenDays: [String: [String: TokenCount]] = [:]
    private let calendar: Calendar
    private var offsets: [String: UInt64] = [:]
    /// Responses already counted, as hashes of "message id:request id" (8 bytes
    /// each instead of a ~60-character string; this process only, never saved).
    private var seen = Set<Int>()

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Reads whatever is new in every transcript under `root`.
    /// Returns true when new usage was found.
    @discardableResult
    public func scan(root: URL) -> Bool {
        let before = records.count
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let start = offsets[url.path] ?? 0
            if size == start { continue }
            // A file that shrank was rewritten; start it over (dedupe keeps totals right).
            guard let offset = Self.readLines(of: url.path, from: size < start ? 0 : start, ingest) else { continue }
            offsets[url.path] = offset
        }
        return records.count != before
    }

    /// Reads complete lines of `path` from `offset` in chunks and returns the
    /// offset after the last complete line; nil when the file can't be opened.
    /// Shared with `SessionCostReader`.
    static func readLines(of path: String, from offset: UInt64, _ body: (Data) -> Void) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var offset = offset
        try? handle.seek(toOffset: offset)
        // Chunks keep memory flat on big transcripts. The pool frees the
        // JSON parser's temporaries, which a background queue never drains.
        var carry = Data()
        while true {
            let done: Bool = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { return true }
                var data = carry
                data.append(chunk)
                // Only consume complete lines; a half-written last line waits.
                guard let lastNewline = data.lastIndex(of: 0x0A) else {
                    carry = data
                    return false
                }
                body(data[data.startIndex...lastNewline])
                offset += UInt64(lastNewline - data.startIndex + 1)
                carry = Data(data[(lastNewline + 1)...])
                return false
            }
            if done { break }
        }
        return offset
    }

    static let chunkSize = 4 << 20

    private static let usageMarkerBytes = Array("\"usage\"".utf8)

    /// Parses complete JSONL lines.
    public func ingest(_ data: Data) {
        Self.forEachUsageLine(in: data) { line in
            if let record = Self.parse(line: line) { add(record.key, record.usage) }
        }
    }

    /// Calls `body` with each line of `data` that carries usage. Shared with `SessionCostReader`.
    static func forEachUsageLine(in data: Data, _ body: (Data) -> Void) {
        // memchr and memmem: Data's own byte search went through generic collection code.
        let marker = Self.usageMarkerBytes
        let lines: [Range<Int>] = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>] in
            guard let base = raw.baseAddress else { return [] }
            var found: [Range<Int>] = []
            var start = 0
            while start < raw.count {
                var end = raw.count
                if let newline = memchr(base + start, 0x0A, raw.count - start) {
                    end = UnsafeRawPointer(newline) - base
                }
                // Cheap byte search first: most lines (user turns, tool results) carry no usage.
                if memmem(base + start, end - start, marker, marker.count) != nil { found.append(start..<end) }
                start = end + 1
            }
            return found
        }
        for range in lines {
            body(data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)])
        }
    }

    private func add(_ key: String?, _ usage: TokenUsage) {
        if let key {
            guard seen.insert(key.hashValue).inserted else { return }
        }
        records.append(usage)
        spendDays[calendar.startOfDay(for: usage.timestamp), default: .init()].add(usage)
        TokenLedger.add(claude: usage, to: &tokenDays, calendar: calendar)
    }

    static func date(_ string: String) -> Date? { ISODate.parse(string) }

    static func parse(line: Data) -> (key: String?, usage: TokenUsage)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let stamp = (object["timestamp"] as? String).flatMap(date) else { return nil }
        var record = TokenUsage(model: model, timestamp: stamp,
                                input: usage.int("input_tokens"),
                                output: usage.int("output_tokens"),
                                cacheRead: usage.int("cache_read_input_tokens"),
                                fast: usage["speed"] as? String == "fast")
        if let split = usage["cache_creation"] as? [String: Any] {
            record.cacheWrite5m = split.int("ephemeral_5m_input_tokens")
            record.cacheWrite1h = split.int("ephemeral_1h_input_tokens")
        } else {
            record.cacheWrite5m = usage.int("cache_creation_input_tokens")
        }
        let id = message["id"] as? String
        let request = object["requestId"] as? String
        let key = (id != nil || request != nil) ? "\(id ?? ""):\(request ?? "")" : nil
        return (key, record)
    }
}

/// Spend totals for display.
public struct SpendSummary: Equatable, Sendable {
    public var today: Double = 0
    public var last7Days: Double = 0
    public var last30Days: Double = 0
    /// Cost per day, oldest first, ending today.
    public var daily: [Double] = []
    /// Tokens used today across all kinds.
    public var tokensToday = 0

    public init() {}

    /// Cost and tokens of one day.
    public struct Day: Equatable, Sendable {
        public var cost: Double = 0
        public var tokens = 0
        public init() {}

        mutating func add(_ usage: TokenUsage) {
            cost += usage.cost
            tokens += usage.input + usage.output + usage.cacheRead + usage.cacheWrite5m + usage.cacheWrite1h
        }
    }

    public static func make(from records: [TokenUsage], now: Date = Date(),
                            calendar: Calendar = .current, days: Int = 14) -> SpendSummary {
        var byDay: [Date: Day] = [:]
        for record in records { byDay[calendar.startOfDay(for: record.timestamp), default: Day()].add(record) }
        return make(days: byDay, now: now, calendar: calendar, count: days)
    }

    /// From totals by start of day: one step per day, however many records there are.
    public static func make(days byDay: [Date: Day], now: Date = Date(),
                            calendar: Calendar = .current, count days: Int = 14) -> SpendSummary {
        var summary = SpendSummary()
        let today = calendar.startOfDay(for: now)
        summary.daily = Array(repeating: 0, count: days)
        for (day, total) in byDay {
            guard let ago = calendar.dateComponents([.day], from: day, to: today).day, ago >= 0 else { continue }
            if ago == 0 {
                summary.today += total.cost
                summary.tokensToday += total.tokens
            }
            if ago < 7 { summary.last7Days += total.cost }
            if ago < 30 { summary.last30Days += total.cost }
            if ago < days { summary.daily[days - 1 - ago] += total.cost }
        }
        return summary
    }
}

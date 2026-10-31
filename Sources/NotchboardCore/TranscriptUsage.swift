import Foundation

/// Reads token usage out of Claude Code transcripts (~/.claude/projects/**/*.jsonl)
/// and keeps running totals. Files are read incrementally: each scan only parses
/// bytes appended since the last one, so rescanning is cheap.
///
/// Claude Code writes one line per content block, repeating the same usage on
/// each, so responses are de-duplicated by message id + request id.
public final class TranscriptUsage: @unchecked Sendable {
    public private(set) var records: [TokenUsage] = []
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()

    public init() {}

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
            var offset = size < start ? 0 : start
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            // Chunks keep memory flat on big transcripts. The pool frees the
            // JSON parser's temporaries, which a background queue never drains.
            var carry = Data()
            while true {
                let done: Bool = autoreleasepool {
                    guard let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { return true }
                    var data = carry
                    data.append(chunk)
                    // Only consume complete lines; a half-written last line waits.
                    guard let lastNewline = data.lastIndex(of: 0x0A) else {
                        carry = data
                        return false
                    }
                    ingest(data[data.startIndex...lastNewline])
                    offset += UInt64(lastNewline - data.startIndex + 1)
                    carry = Data(data[(lastNewline + 1)...])
                    return false
                }
                if done { break }
            }
            offsets[url.path] = offset
        }
        return records.count != before
    }

    static let chunkSize = 4 << 20

    private static let usageMarker = Data("\"usage\"".utf8)

    /// Parses complete JSONL lines.
    public func ingest(_ data: Data) {
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            // Cheap byte search first: most lines (user turns, tool results) carry no usage.
            guard line.range(of: Self.usageMarker) != nil else { continue }
            if let record = Self.parse(line: line) { add(record.key, record.usage) }
        }
    }

    private func add(_ key: String?, _ usage: TokenUsage) {
        if let key {
            guard seen.insert(key).inserted else { return }
        }
        records.append(usage)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func date(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? iso.date(from: string)
    }

    static func parse(line: Data) -> (key: String?, usage: TokenUsage)? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String,
              let stamp = (object["timestamp"] as? String).flatMap(date) else { return nil }
        func int(_ dict: [String: Any]?, _ key: String) -> Int { (dict?[key] as? NSNumber)?.intValue ?? 0 }
        var record = TokenUsage(model: model, timestamp: stamp,
                                input: int(usage, "input_tokens"),
                                output: int(usage, "output_tokens"),
                                cacheRead: int(usage, "cache_read_input_tokens"),
                                fast: usage["speed"] as? String == "fast")
        if let split = usage["cache_creation"] as? [String: Any] {
            record.cacheWrite5m = int(split, "ephemeral_5m_input_tokens")
            record.cacheWrite1h = int(split, "ephemeral_1h_input_tokens")
        } else {
            record.cacheWrite5m = int(usage, "cache_creation_input_tokens")
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

    public static func make(from records: [TokenUsage], now: Date = Date(),
                            calendar: Calendar = .current, days: Int = 14) -> SpendSummary {
        var summary = SpendSummary()
        let today = calendar.startOfDay(for: now)
        summary.daily = Array(repeating: 0, count: days)
        for record in records {
            let day = calendar.startOfDay(for: record.timestamp)
            guard let ago = calendar.dateComponents([.day], from: day, to: today).day, ago >= 0 else { continue }
            let cost = record.cost
            if ago == 0 {
                summary.today += cost
                summary.tokensToday += record.input + record.output + record.cacheRead + record.cacheWrite5m + record.cacheWrite1h
            }
            if ago < 7 { summary.last7Days += cost }
            if ago < 30 { summary.last30Days += cost }
            if ago < days { summary.daily[days - 1 - ago] += cost }
        }
        return summary
    }
}

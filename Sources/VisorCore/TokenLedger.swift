import Foundation

/// Tokens of each kind. Cache reads are the conversation re-read from cache on
/// every reply: cheap, and most of the total.
public struct TokenCount: Codable, Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }
    /// The tokens that were new work for the model.
    public var withoutCacheRead: Int { input + output + cacheWrite }

    public static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    /// Short counts for the usage panel: 1.2K, 303K, 4.2M.
    public static func compact(_ value: Int) -> String {
        let magnitude = Double(abs(value))
        let sign = value < 0 ? "-" : ""
        if magnitude >= 1_000_000_000 { return sign + scaled(magnitude / 1_000_000_000) + "B" }
        if magnitude >= 1_000_000 { return sign + scaled(magnitude / 1_000_000) + "M" }
        if magnitude >= 1_000 { return sign + scaled(magnitude / 1_000) + "K" }
        return "\(value)"
    }

    private static func scaled(_ value: Double) -> String {
        let text = value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// Each kind at its larger value.
    func max(_ other: TokenCount) -> TokenCount {
        TokenCount(input: Swift.max(input, other.input), output: Swift.max(output, other.output),
                   cacheRead: Swift.max(cacheRead, other.cacheRead), cacheWrite: Swift.max(cacheWrite, other.cacheWrite))
    }
}

/// Every token used, by day ("yyyy-MM-dd", local time), tool and model, kept
/// by Visor itself: Claude Code deletes old transcripts, so the tools' own logs
/// can't say what was used all time. Saved between launches.
public struct TokenLedger: Codable, Equatable, Sendable {
    /// Day -> "tool|model" -> tokens.
    public private(set) var days: [String: [String: TokenCount]] = [:]

    public init() {}

    /// What a tool's logs say now, by day. A day only grows: what's no longer
    /// in the logs stays, and a larger count replaces a smaller one. Returns
    /// whether anything changed.
    @discardableResult
    public mutating func merge(_ fresh: [String: [String: TokenCount]]) -> Bool {
        var changed = false
        for (day, entries) in fresh {
            for (key, count) in entries {
                let old = days[day]?[key]
                let next = old.map { $0.max(count) } ?? count
                if next != old { days[day, default: [:]][key] = next; changed = true }
            }
        }
        return changed
    }

    static func key(_ tool: String, _ model: String) -> String { "\(tool)|\(model)" }

    /// Model names the same way across tools: Copilot's "claude-sonnet-5.5" is Claude Code's "claude-sonnet-5-5".
    static func modelName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: ".", with: "-")
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Sources

    /// Claude Code's replies by day and model. "<synthetic>" is Claude Code's own placeholder, not a model.
    public static func daily(claude records: [TokenUsage], calendar: Calendar = .current) -> [String: [String: TokenCount]] {
        var out: [String: [String: TokenCount]] = [:]
        for record in records where record.model != "<synthetic>" {
            let count = TokenCount(input: record.input, output: record.output, cacheRead: record.cacheRead,
                                   cacheWrite: record.cacheWrite5m + record.cacheWrite1h)
            let day = dayKey(record.timestamp, calendar: calendar)
            let key = key("Claude Code", modelName(record.model))
            out[day, default: [:]][key] = (out[day]?[key] ?? TokenCount()) + count
        }
        return out
    }

    /// Copilot CLI's session store (~/.copilot/session-store.db), summed in sqlite.
    public static let copilotQuery = """
    SELECT date(created_at, 'localtime') AS day, model,
           SUM(input_tokens) AS input, SUM(output_tokens) AS output,
           SUM(cache_read_tokens) AS cache_read, SUM(cache_write_tokens) AS cache_write
    FROM assistant_usage_events GROUP BY 1, 2
    """

    public static func daily(copilot json: Data) -> [String: [String: TokenCount]]? {
        rows(json, tool: "Copilot CLI")
    }

    /// OpenCode's assistant messages, all time, by day and model. V2 keeps them in
    /// `session_message`, V1 in `message`; V1 is read until V2 has any.
    public static func openCodeQuery(tables: Set<String>) -> String? {
        let columns = """
        date(time_created / 1000, 'unixepoch', 'localtime') AS day,
        COALESCE(json_extract(data, '$.modelID'), 'unknown') AS model,
        COALESCE(json_extract(data, '$.tokens.input'), 0) AS input,
        COALESCE(json_extract(data, '$.tokens.output'), 0) + COALESCE(json_extract(data, '$.tokens.reasoning'), 0) AS output,
        COALESCE(json_extract(data, '$.tokens.cache.read'), 0) AS cache_read,
        COALESCE(json_extract(data, '$.tokens.cache.write'), 0) AS cache_write
        """
        let v2 = "SELECT \(columns) FROM session_message WHERE type = 'assistant'"
        var v1 = "SELECT \(columns) FROM message WHERE json_extract(data, '$.role') = 'assistant'"
        let inner: String
        switch (tables.contains("session_message"), tables.contains("message")) {
        case (true, true):
            v1 += " AND NOT EXISTS (SELECT 1 FROM session_message WHERE type = 'assistant')"
            inner = "\(v2) UNION ALL \(v1)"
        case (true, false): inner = v2
        case (false, true): inner = v1
        case (false, false): return nil
        }
        return """
        SELECT day, model, SUM(input) AS input, SUM(output) AS output, SUM(cache_read) AS cache_read,
               SUM(cache_write) AS cache_write FROM (\(inner)) GROUP BY day, model
        """
    }

    public static func daily(openCode json: Data) -> [String: [String: TokenCount]]? {
        rows(json, tool: "OpenCode")
    }

    /// `sqlite3 -json` rows with day, model, input, output, cache_read, cache_write.
    static func rows(_ json: Data, tool: String) -> [String: [String: TokenCount]]? {
        if json.isEmpty { return [:] }
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
        var out: [String: [String: TokenCount]] = [:]
        for item in list {
            guard let day = item["day"] as? String, let model = item["model"] as? String else { continue }
            func int(_ key: String) -> Int { (item[key] as? NSNumber)?.intValue ?? 0 }
            let count = TokenCount(input: int("input"), output: int("output"), cacheRead: int("cache_read"), cacheWrite: int("cache_write"))
            let key = key(tool, modelName(model))
            out[day, default: [:]][key] = (out[day]?[key] ?? TokenCount()) + count
        }
        return out
    }

    // MARK: Summary

    /// The last `days` days ending today, or all time.
    public func summary(days limit: Int?, now: Date = Date(), calendar: Calendar = .current) -> TokenSummary {
        let today = calendar.startOfDay(for: now)
        let first: Date
        if let limit {
            first = calendar.date(byAdding: .day, value: -(limit - 1), to: today) ?? today
        } else {
            first = days.keys.min().flatMap { Self.date($0, calendar: calendar) } ?? today
        }
        var keys: [String] = []
        var day = first
        while day <= today {
            keys.append(Self.dayKey(day, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        var summary = TokenSummary()
        var models: [String: TokenCount] = [:]
        var tools: [String: TokenCount] = [:]
        for key in keys {
            var dayTotal = TokenCount()
            var byModel: [String: Int] = [:]
            for (entry, count) in days[key] ?? [:] {
                let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
                let tool = parts.first ?? "", model = parts.count > 1 ? parts[1] : ""
                dayTotal = dayTotal + count
                models[entry] = (models[entry] ?? TokenCount()) + count
                tools[tool] = (tools[tool] ?? TokenCount()) + count
                byModel[model, default: 0] += count.total
            }
            summary.series.append(TokenSummary.Day(day: key, byModel: byModel))
            if dayTotal.total > 0 {
                summary.activeDays += 1
                summary.daily.append(TokenSummary.Total(day: key, count: dayTotal))
                if dayTotal.total > summary.peak?.total ?? 0 { summary.peak = (key, dayTotal.total) }
            }
            summary.total = summary.total + dayTotal
        }
        summary.daily.reverse()
        summary.models = models.map { entry, count in
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            return TokenSummary.Model(tool: parts.first ?? "", model: parts.count > 1 ? parts[1] : "", count: count)
        }
        .filter { $0.count.total > 0 }
        .sorted { $0.count.total > $1.count.total }
        summary.tools = tools.map { TokenSummary.Tool(tool: $0.key, count: $0.value) }
            .filter { $0.count.total > 0 }
            .sorted { $0.count.total > $1.count.total }
        return summary
    }

    static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// What the Tokens view shows for a range.
public struct TokenSummary: Equatable, Sendable {
    public struct Model: Equatable, Sendable, Identifiable {
        public var tool: String
        public var model: String
        public var count: TokenCount
        public var id: String { "\(tool)|\(model)" }
    }

    public struct Tool: Equatable, Sendable, Identifiable {
        public var tool: String
        public var count: TokenCount
        public var id: String { tool }
    }

    public struct Day: Equatable, Sendable {
        public var day: String
        /// Model -> total tokens that day.
        public var byModel: [String: Int]
        public var total: Int { byModel.values.reduce(0, +) }
    }

    public struct Total: Equatable, Sendable, Identifiable {
        public var day: String
        public var count: TokenCount
        public var id: String { day }
    }

    public var total = TokenCount()
    public var activeDays = 0
    public var peak: (day: String, total: Int)?
    /// Biggest first.
    public var models: [Model] = []
    public var tools: [Tool] = []
    /// Every day in the range, oldest first, for the chart.
    public var series: [Day] = []
    /// Days with tokens, newest first.
    public var daily: [Total] = []

    public init() {}

    public static func == (a: TokenSummary, b: TokenSummary) -> Bool {
        a.total == b.total && a.activeDays == b.activeDays && a.peak?.day == b.peak?.day && a.peak?.total == b.peak?.total
            && a.models == b.models && a.tools == b.tools && a.series == b.series && a.daily == b.daily
    }
}

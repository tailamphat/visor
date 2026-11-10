import Foundation

/// One assistant response recorded in OpenCode's database.
public struct OpenCodeRow: Equatable, Sendable {
    public var timestamp: Date
    public var cost: Double
    public var input: Int
    public var output: Int
    public var reasoning: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(timestamp: Date, cost: Double = 0, input: Int = 0, output: Int = 0,
                reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.timestamp = timestamp
        self.cost = cost
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var tokens: Int { input + output + reasoning + cacheRead + cacheWrite }
}

/// Cost and tokens over a period.
public struct OpenCodeTotals: Equatable, Sendable {
    public var cost: Double = 0
    public var input = 0
    public var output = 0
    public var reasoning = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init() {}

    public var tokens: Int { input + output + reasoning + cacheRead + cacheWrite }

    mutating func add(_ row: OpenCodeRow) {
        cost += row.cost
        input += row.input
        output += row.output
        reasoning += row.reasoning
        cacheRead += row.cacheRead
        cacheWrite += row.cacheWrite
    }
}

/// What OpenCode has used on this Mac, from the assistant messages in its database.
/// OpenCode records the cost itself, so it is used as-is: free models report zero.
public struct OpenCodeUsage: Equatable, Sendable {
    public var today = OpenCodeTotals()
    public var last7 = OpenCodeTotals()
    public var last30 = OpenCodeTotals()
    /// Tokens per day, oldest first, ending today.
    public var daily: [Int] = []

    public init() {}

    public static func make(from rows: [OpenCodeRow], now: Date = Date(),
                            calendar: Calendar = .current, days: Int = 14) -> OpenCodeUsage {
        var usage = OpenCodeUsage()
        usage.daily = Array(repeating: 0, count: days)
        let today = calendar.startOfDay(for: now)
        for row in rows {
            let day = calendar.startOfDay(for: row.timestamp)
            guard let ago = calendar.dateComponents([.day], from: day, to: today).day, ago >= 0 else { continue }
            if ago == 0 { usage.today.add(row) }
            if ago < 7 { usage.last7.add(row) }
            if ago < 30 { usage.last30.add(row) }
            if ago < days { usage.daily[days - 1 - ago] += row.tokens }
        }
        return usage
    }

    /// The `sqlite3` query for assistant messages since `since`. V2 keeps them in
    /// `session_message` (`type`), V1 in `message` (`data.role`). A database can
    /// have both tables with V2 still empty, so V1 is read until V2 has any.
    public static func query(tables: Set<String>, since: Date) -> String? {
        let since = Int64(since.timeIntervalSince1970 * 1000)
        let columns = """
        time_created / 1000 AS stamp,
        COALESCE(json_extract(data, '$.cost'), 0) AS cost,
        COALESCE(json_extract(data, '$.tokens.input'), 0) AS input,
        COALESCE(json_extract(data, '$.tokens.output'), 0) AS output,
        COALESCE(json_extract(data, '$.tokens.reasoning'), 0) AS reasoning,
        COALESCE(json_extract(data, '$.tokens.cache.read'), 0) AS cache_read,
        COALESCE(json_extract(data, '$.tokens.cache.write'), 0) AS cache_write
        """
        let v2 = "SELECT \(columns) FROM session_message WHERE type = 'assistant' AND time_created >= \(since)"
        var v1 = "SELECT \(columns) FROM message WHERE json_extract(data, '$.role') = 'assistant' AND time_created >= \(since)"
        switch (tables.contains("session_message"), tables.contains("message")) {
        case (true, true):
            v1 += " AND NOT EXISTS (SELECT 1 FROM session_message WHERE type = 'assistant')"
            return "\(v2) UNION ALL \(v1) ORDER BY stamp"
        case (true, false): return "\(v2) ORDER BY stamp"
        case (false, true): return "\(v1) ORDER BY stamp"
        case (false, false): return nil
        }
    }

    /// Rows from `sqlite3 -json`, using the column names in `query(tables:since:)`.
    public static func parse(_ data: Data) -> [OpenCodeRow]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let stamp = (item["stamp"] as? NSNumber)?.doubleValue else { return nil }
            func int(_ key: String) -> Int { (item[key] as? NSNumber)?.intValue ?? 0 }
            return OpenCodeRow(timestamp: Date(timeIntervalSince1970: stamp),
                               cost: (item["cost"] as? NSNumber)?.doubleValue ?? 0,
                               input: int("input"), output: int("output"), reasoning: int("reasoning"),
                               cacheRead: int("cache_read"), cacheWrite: int("cache_write"))
        }
    }
}

/// OpenCode Go's 5-hour, weekly and monthly windows, from the official usage API.
public struct OpenCodeGoLimit: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Percent used, 0...100.
    public var percentUsed: Double
    public var resetsAt: Date?

    public init(id: String, title: String, percentUsed: Double, resetsAt: Date?) {
        self.id = id
        self.title = title
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
    }

    public var percentLeft: Double { max(0, 100 - percentUsed) }
}

public struct OpenCodeGoUsage: Equatable, Sendable {
    public var limits: [OpenCodeGoLimit]

    public init(limits: [OpenCodeGoLimit]) {
        self.limits = limits
    }

    /// The window closest to running out, for the closed notch.
    public var lowest: OpenCodeGoLimit? { limits.min { $0.percentLeft < $1.percentLeft } }

    /// `{"usage":{"rolling":{"percent":1,"resetsAt":"..."},...}}`
    public static func parse(_ data: Data) -> OpenCodeGoUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else { return nil }
        let windows = [("rolling", "Session (5h)"), ("weekly", "Weekly"), ("monthly", "Monthly")]
        var limits: [OpenCodeGoLimit] = []
        for (id, title) in windows {
            guard let item = usage[id] as? [String: Any],
                  let percent = (item["percent"] as? NSNumber)?.doubleValue else { continue }
            limits.append(OpenCodeGoLimit(id: id, title: title,
                                          percentUsed: min(100, max(0, percent)),
                                          resetsAt: (item["resetsAt"] as? String).flatMap(TranscriptUsage.date)))
        }
        return limits.isEmpty ? nil : OpenCodeGoUsage(limits: limits)
    }
}

/// Short token counts for the usage panel: 1.2K, 303K, 4.2M.
public enum TokenCount {
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
}

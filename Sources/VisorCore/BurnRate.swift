import Foundation

/// One reading of a limit: percent used at a moment.
public struct UsageSample: Equatable, Sendable {
    public var date: Date
    public var used: Double
}

/// Recent readings per limit, to tell how fast each is being used. Keeps the
/// last half hour plus the newest reading before it as the baseline.
public struct UsageHistory: Equatable, Sendable {
    public static let span: TimeInterval = 30 * 60
    private var readings: [String: [UsageSample]] = [:]

    public init() {}

    public mutating func record(_ key: String, used: Double, at date: Date = Date()) {
        var list = readings[key] ?? []
        // Usage only grows within a window; a drop means it reset.
        if let last = list.last, used < last.used - 1 { list.removeAll() }
        if let last = list.last, last.used == used, list.count > 1, list[list.count - 2].used == used {
            // A flat run keeps its first and latest reading.
            list[list.count - 1] = UsageSample(date: date, used: used)
        } else {
            list.append(UsageSample(date: date, used: used))
        }
        if let cut = list.lastIndex(where: { $0.date < date - Self.span }), cut > 0 { list.removeFirst(cut) }
        readings[key] = list
    }

    public func samples(_ key: String) -> [UsageSample] { readings[key] ?? [] }
}

/// The history key of each tool's limits.
public enum UsageKey {
    public static func claude(_ kind: String) -> String { "claude." + kind }
    public static func copilot(_ host: String) -> String { "copilot." + host }
    public static func antigravity(_ id: String) -> String { "antigravity." + id }
    public static func openCode(_ id: String) -> String { "opencode." + id }
}

/// When a limit runs out at the current pace, or how much is left when it resets.
public enum BurnForecast: Equatable, Sendable {
    case runsOut(at: Date)
    case lasts(leftAtReset: Double)

    /// The shortest stretch a rate is measured over; shorter is noise.
    static let minimumSpan: TimeInterval = 10 * 60

    /// The pace is the recent readings' when they span ten minutes or more,
    /// else the average since the window began. nil when idle, spent, or too
    /// early to tell.
    public static func make(used: Double, resetsAt: Date?, window: TimeInterval?,
                            history: [UsageSample], now: Date = Date()) -> BurnForecast? {
        guard used < 100, let resetsAt, resetsAt > now else { return nil }
        let perSecond: Double
        if let base = history.first, now.timeIntervalSince(base.date) >= minimumSpan {
            perSecond = (used - base.used) / now.timeIntervalSince(base.date)
        } else if let window {
            let elapsed = window - resetsAt.timeIntervalSince(now)
            guard elapsed >= minimumSpan else { return nil }
            perSecond = used / elapsed
        } else {
            return nil
        }
        // Under 0.1% an hour is idle.
        guard perSecond * 3600 >= 0.1 else { return nil }
        let empty = now + (100 - used) / perSecond
        if empty < resetsAt { return .runsOut(at: empty) }
        return .lasts(leftAtReset: max(0, 100 - used - perSecond * resetsAt.timeIntervalSince(now)))
    }

    /// How long Claude's limits last, by kind.
    public static func window(claude kind: String) -> TimeInterval? {
        switch kind {
        case "session", "five_hour": return 5 * 3600
        case _ where kind.hasPrefix("seven_day") || kind.hasPrefix("weekly"): return 7 * 86_400
        default: return nil
        }
    }

    /// How long OpenCode Go's limits last, by id.
    public static func window(openCode id: String, resetsAt: Date? = nil) -> TimeInterval? {
        switch id {
        case "rolling": return 5 * 3600
        case "weekly": return 7 * 86_400
        case "monthly": return resetsAt.flatMap { monthWindow(endingAt: $0) }
        default: return nil
        }
    }

    /// A monthly allowance (Copilot): from the same day a month before the reset.
    public static func monthWindow(endingAt reset: Date, calendar: Calendar = .current) -> TimeInterval? {
        calendar.date(byAdding: .month, value: -1, to: reset).map { reset.timeIntervalSince($0) }
    }

    /// "42m", "1h 15m"; nil from a day on, where a date reads better.
    public static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds < 86_400 else { return nil }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

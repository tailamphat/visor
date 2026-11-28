import Foundation

/// Whether a finished Claude Code session's prompt cache is still warm, from
/// its last reply and the time it stopped. Pure: no timers, nothing stored.
public enum CacheClock {
    public enum State: Equatable, Sendable {
        case warm(secondsLeft: Int)
        /// What the next reply re-reads and what that costs at the cache-write rate.
        case cold(rereadTokens: Int, dollars: Double)
    }

    static let fiveMinutes = 300.0
    static let oneHour = 3600.0

    /// The cache lives 5 minutes, or 1 hour when the reply wrote any 1-hour cache.
    public static func window(for usage: TokenUsage) -> TimeInterval {
        usage.cacheWrite1h > 0 ? oneHour : fiveMinutes
    }

    /// Nil when there is no last reply or its model has no price.
    public static func state(last: TokenUsage?, stoppedAt stop: Date, now: Date) -> State? {
        guard let last, let price = Pricing.price(for: last.model) else { return nil }
        let window = window(for: last)
        let left = window - max(0, now.timeIntervalSince(stop))
        if left > 0 { return .warm(secondsLeft: Int(left.rounded(.up))) }
        let tokens = last.input + last.cacheRead + last.cacheWrite5m + last.cacheWrite1h
        let rate = window == oneHour ? price.cacheWrite1h : price.cacheWrite5m
        return .cold(rereadTokens: tokens, dollars: Double(tokens) * rate / 1_000_000)
    }

    /// "Cache warm · about 3m left" or "Cache cold · next reply re-reads 142k · about $0.53".
    public static func text(last: TokenUsage?, stoppedAt stop: Date, now: Date) -> String? {
        switch state(last: last, stoppedAt: stop, now: now) {
        case nil: return nil
        case .warm(let seconds)?: return "Cache warm · about \((seconds + 59) / 60)m left"
        case .cold(let tokens, let dollars)?:
            return "Cache cold · next reply re-reads \(Self.tokens(tokens)) · about \(Self.dollars(dollars))"
        }
    }

    /// What a card shows: a short line that fits half the panel, the full sentence
    /// for hover, and whether it is still warm (mint, with the draining bar).
    public struct Line: Equatable, Sendable {
        /// "Cache cold", or the whole warm text: the last piece to give way.
        public let label: String
        /// " · 142k" when cold, else empty: gives way first on a narrow card.
        public let detail: String
        /// " · about $0.53" when cold, else empty: always shown whole.
        public let price: String
        public let help: String
        public let warm: Bool
        public var text: String { label + detail + price }
    }

    /// "Cache warm · about 2m left" or "Cache cold · 142k · about $0.53" (half a panel
    /// at 10 pt holds about 179 pt; the full sentence is `help`);
    /// nil when `state` is nil.
    public static func line(last: TokenUsage?, stoppedAt stop: Date, now: Date) -> Line? {
        guard let state = state(last: last, stoppedAt: stop, now: now),
              let help = text(last: last, stoppedAt: stop, now: now) else { return nil }
        switch state {
        case .warm: return Line(label: help, detail: "", price: "", help: help, warm: true)
        case .cold(let tokens, let dollars):
            return Line(label: "Cache cold", detail: " · \(Self.tokens(tokens))", price: " · about \(Self.dollars(dollars))",
                        help: help, warm: false)
        }
    }

    /// "999", "142k", "1.3M", "2.5B".
    static func tokens(_ count: Int) -> String {
        if count >= 999_950_000 { return String(format: "%.1fB", Double(count) / 1_000_000_000) }
        if count >= 999_500 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return "\(Int((Double(count) / 1000).rounded()))k" }
        return "\(count)"
    }

    /// "$0.53", "$123" from $100, "$15,625" from $1,000; never below "$0.01".
    static func dollars(_ value: Double) -> String {
        value >= 99.995 ? "$" + grouped(Int(value.rounded())) : String(format: "$%.2f", max(0.01, value))
    }

    /// 15625 as "15,625": by hand, so no formatter or locale is involved.
    static func grouped(_ number: Int) -> String {
        var out: [Character] = []
        for (i, digit) in String(number).reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return String(out.reversed())
    }
}

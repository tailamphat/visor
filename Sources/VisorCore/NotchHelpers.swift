import Foundation

/// Keys that answer the approval card while the pointer is over it.
public enum ApprovalKeys {
    /// Return or Enter allows, Esc denies, A always allows (when the card offers
    /// it). Keys held with ⌘, ⌃ or ⌥ are left to the app.
    public static func decision(keyCode: UInt16, characters: String?, modified: Bool, canAlways: Bool) -> ApprovalRequest.Decision? {
        guard !modified else { return nil }
        switch keyCode {
        case 36, 76: return .allow
        case 53: return .deny
        default: return canAlways && characters?.lowercased() == "a" ? .allowAlways : nil
        }
    }
}

/// How full a Claude Code session's context window is, from its transcript.
public enum ContextUsage {
    public static let standardWindow = 200_000
    public static let largeWindow = 1_000_000
    /// How much of the end of a transcript to read: the last reply is near the end.
    public static let tailBytes = 256 * 1024

    /// Tokens in context after the last reply of the main conversation: its
    /// input, read from cache and written to cache. Subagent replies have their
    /// own context and are skipped. Right after a compaction it's unknown until
    /// the next reply. The first line may be cut off where the tail began.
    public static func tokens(inTail data: Data) -> Int? {
        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if object["type"] as? String == "system", object["subtype"] as? String == "compact_boundary" { return nil }
            guard object["type"] as? String == "assistant", object["isSidechain"] as? Bool != true,
                  let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            let count = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
            if count > 0 { return count }
        }
        return nil
    }

    /// The tokens, plus the window the transcript proves: a compaction that
    /// started above 200k can only happen in a 1M window, whatever the count is now.
    public static func reading(inTail data: Data) -> (tokens: Int?, provenWindow: Int?) {
        var proven: Int?
        for line in data.split(separator: 0x0A) where line.count < 4096 {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["subtype"] as? String == "compact_boundary",
                  let pre = ((object["compactMetadata"] as? [String: Any])?["preTokens"] as? NSNumber)?.intValue,
                  pre > standardWindow else { continue }
            proven = largeWindow
        }
        return (tokens(inTail: data), proven)
    }

    /// Transcripts don't say which window a session has: 1M when the model
    /// setting asks for it ("opus[1m]") or the context has grown past 200k.
    public static func window(tokens: Int, model: String?) -> Int {
        model?.contains("[1m]") == true || tokens > standardWindow ? largeWindow : standardWindow
    }
}

/// One usage limit at one moment, from any provider.
public struct LimitReading: Equatable, Sendable {
    public var key: String
    public var agent: String
    public var title: String
    public var percentUsed: Double
    public var resetsAt: Date?

    public init(key: String, agent: String, title: String, percentUsed: Double, resetsAt: Date?) {
        self.key = key
        self.agent = agent
        self.title = title
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
    }

    /// The limits Visor refreshes in the background (Claude every 2 minutes,
    /// OpenCode Go too). Copilot and Antigravity are read only when the Usage
    /// tab opens, so a reset would be noticed only when you're already looking.
    public static func all(plan: PlanUsage?, openCode: OpenCodeGoUsage?) -> [LimitReading] {
        (plan?.limits ?? []).map {
            LimitReading(key: "claude.\($0.kind)", agent: "Claude Code", title: $0.title, percentUsed: $0.percentUsed, resetsAt: $0.resetsAt)
        } + (openCode?.limits ?? []).map {
            LimitReading(key: "opencode.\($0.id)", agent: "OpenCode", title: $0.title, percentUsed: $0.percentUsed, resetsAt: $0.resetsAt)
        }
    }
}

/// A limit that had run out, or nearly, and has just reset.
public struct LimitReturn: Equatable, Sendable {
    public var agent: String
    public var title: String
    public var percentLeft: Double
    /// When Visor first saw it at 100%; nil when it only came close.
    public var ranOutAt: Date?
    public var nextReset: Date?

    public init(agent: String, title: String, percentLeft: Double, ranOutAt: Date?, nextReset: Date?) {
        self.agent = agent
        self.title = title
        self.percentLeft = percentLeft
        self.ranOutAt = ranOutAt
        self.nextReset = nextReset
    }
}

/// Notices limits coming back. Only a limit that was at least `nearlyOut` used
/// counts: an ordinary reset of a limit you weren't short of says nothing.
public struct LimitWatch: Sendable {
    public static let nearlyOut = 90.0

    private var last: [String: LimitReading] = [:]
    private var ranOut: [String: Date] = [:]

    public init() {}

    public mutating func update(_ readings: [LimitReading], now: Date = Date()) -> [LimitReturn] {
        var back: [LimitReturn] = []
        for reading in readings {
            if let before = last[reading.key], before.percentUsed >= Self.nearlyOut,
               reading.percentUsed < before.percentUsed - 30, Self.renewed(before, reading, now: now) {
                back.append(LimitReturn(agent: reading.agent, title: reading.title, percentLeft: max(0, 100 - reading.percentUsed),
                                        ranOutAt: ranOut[reading.key], nextReset: reading.resetsAt))
                ranOut[reading.key] = nil
            }
            if reading.percentUsed >= 100, ranOut[reading.key] == nil { ranOut[reading.key] = now }
            last[reading.key] = reading
        }
        return back
    }

    /// The window rolled over: its reset time passed or moved on.
    private static func renewed(_ before: LimitReading, _ now: LimitReading, now date: Date) -> Bool {
        guard let old = before.resetsAt else { return true }
        return old <= date || (now.resetsAt.map { $0 > old } ?? false)
    }
}

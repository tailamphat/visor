import Foundation

/// The card under a selected helper row in the waterfall: what it is, what it was
/// asked, what it's doing, its tools, context, cost and what it started with.
/// Only labels and counts: never the helper's result text. Claude Code only.
public struct HelperDetail: Equatable, Sendable {
    public enum Line: Equatable, Sendable { case title, task, now, tools, context, cost, started }
    /// The helper's harness: bar parts (about), the exact total ("22k"), and the rows with their about flags.
    public struct Started: Equatable, Sendable {
        public var parts: [HarnessPart]
        public var total: String
        public var rows: [XRayRow]
    }

    public static let padding = 6.0
    public static let lineHeight = 16.0
    /// Context window when the session doesn't know its own.
    static let defaultWindow = 200_000
    static let maxToolNames = 3

    public var title: String
    /// The agent type from its meta file, when it differs from the title.
    public var pill: String?
    public var failed: Bool
    public var duration: String?
    public var task: String
    public var now: String?
    public var tools: String?
    public var contextK: Int?
    public var contextShare = 0.0
    public var cost: String?
    public var started: Started?
    /// The card's lines in order; lines without data are left out.
    public var lines: [Line]
    public var height: Double { 2 * Self.padding + Double(lines.count) * Self.lineHeight }

    /// Nil for the main row, a row that isn't a helper, or a session that isn't Claude Code.
    public init?(session: AgentSession, rowID: String) {
        guard session.agent == "Claude Code", let h = session.helpers.first(where: { $0.id == rowID }) else { return nil }
        let stats = h.stats
        title = h.type
        pill = stats?.agentType.flatMap { $0 == h.type ? nil : $0 }
        failed = h.failed
        duration = h.start.map { HelperWaterfall.elapsed(seconds: (h.end ?? session.lastEvent).timeIntervalSince($0)) }
        task = h.task
        now = h.done ? nil : h.activity
        lines = [.title, .task]
        if now != nil { lines.append(.now) }
        guard let stats else { return }
        if !stats.tools.isEmpty {
            let sorted = stats.tools.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            var parts = sorted.prefix(Self.maxToolNames).map { "\($0.key) \($0.value)" }
            if sorted.count > Self.maxToolNames { parts.append("\(sorted.count - Self.maxToolNames) more") }
            tools = parts.joined(separator: " · ")
            lines.append(.tools)
        }
        if stats.context > 0 {
            contextK = stats.context / 1000
            let window = session.contextWindow.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultWindow
            contextShare = min(1, Double(stats.context) / Double(window))
            lines.append(.context)
        }
        let costParts = [stats.unpriced ? nil : stats.shown.cost, stats.model.map(Self.modelLabel)].compactMap { $0 }
        if !costParts.isEmpty {
            cost = costParts.joined(separator: " · ")
            lines.append(.cost)
        }
        if let xray = stats.xray {
            started = Started(parts: HarnessSummary.parts(of: xray), total: HarnessSummary.short(xray.total),
                              rows: xray.rows)
            lines.append(.started)
        }
    }

    /// "sonnet" from "claude-sonnet-4-5-20250929" or "claude-3-7-sonnet-20250219"; other names as they are.
    public static func modelLabel(_ name: String) -> String {
        let lower = name.lowercased()
        guard lower.hasPrefix("claude-") else { return String(name.prefix(HelperStats.maxName)) }
        let parts = lower.dropFirst("claude-".count).split(separator: "-")
        return parts.first { Int($0) == nil }.map(String.init) ?? lower
    }
}

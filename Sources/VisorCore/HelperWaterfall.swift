import Foundation

/// Text, costs and bar geometry for the helpers trace waterfall (`HelpersList`),
/// built from a `HelperGraph`. Pure: the view only draws what this returns.
public enum HelperWaterfall {
    public struct BarSpec: Equatable, Sendable {
        public var id: String
        public var x: Double
        public var width: Double
        public var state: HelperGraph.State
        public var isMain: Bool
        public var critical: Bool
        public var growTo: Double?
        public var growSeconds: Double?
        public var key: String
    }

    public static let padding = 6.0
    public static let headerHeight = 18.0
    public static let axisHeight = 12.0
    public static let rowHeight = 18.0
    public static let captionHeight = 16.0
    public static let nameWidth = 128.0
    public static let costWidth = 44.0
    public static let gap = 8.0

    /// "Critical path: Plan then builder (14 of 18 min)": the outlined rows' types in start
    /// order, nil when nothing is on the path.
    public static func caption(_ graph: HelperGraph) -> String? {
        let path = graph.rows.enumerated().filter { $0.element.isCritical }
            .sorted { $0.element.x != $1.element.x ? $0.element.x < $1.element.x : $0.offset < $1.offset }
            .map { $0.element.type ?? $0.element.title }
        guard let first = path.first, let last = path.last else { return nil }
        let names = path.count <= 3 ? path.joined(separator: " then ") : "\(first) then \(path.count - 2) more then \(last)"
        let time: String
        if graph.turnSeconds >= 120 {
            time = "\(Int((graph.criticalSeconds / 60).rounded())) of \(Int((graph.turnSeconds / 60).rounded())) min"
        } else {
            time = "\(Int(graph.criticalSeconds.rounded())) of \(Int(graph.turnSeconds.rounded())) s"
        }
        return "Critical path: \(names) (\(time))"
    }

    /// "perf failed" for one failed helper, "2 failed" for more, nil for none.
    public static func failures(_ graph: HelperGraph) -> String? {
        let failed = graph.rows.filter { $0.state == .failed }
        if failed.count > 1 { return "\(failed.count) failed" }
        return failed.first.map { "\($0.type ?? $0.title) failed" }
    }

    /// Cost labels by row id: a helper's own when priced, and "main" for this turn's
    /// spend outside its helpers; missing (blank) when unknown, unpriced or below a cent.
    public static func costs(session: AgentSession) -> [String: String] {
        var out: [String: String] = [:]
        var helperDollars = 0.0
        var allPriced = true
        for h in session.helpers {
            guard let stats = h.stats else { allPriced = false; continue }
            if stats.unpriced { allPriced = false; continue }
            helperDollars += stats.dollars
            if let label = SessionCost(dollars: stats.dollars, tokens: stats.tokens, unpriced: false).label { out[h.id] = label }
        }
        // Main is this turn's spend: the total less the turn's base and the helpers. Unknown when
        // any part is: no base, a helper from an earlier turn (partly in the base), or the cap reached
        // (trimmed helpers' spend would land on main).
        let earlier = session.helpers.contains { h in h.start.map { s in session.turnStart.map { s < $0 } ?? true } ?? false }
        if allPriced, !earlier, session.helpers.count < AgentSession.maxHelpers,
           let base = session.turnCostBase, let total = session.cost, !total.unpriced,
           let label = SessionCost(dollars: max(0, total.dollars - base - helperDollars), tokens: 0, unpriced: false).label {
            out["main"] = label
        }
        return out
    }

    /// A finished turn's length for the header: "45s", "18m", "1h 5m".
    public static func elapsed(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
    }

    /// The waterfall is for Claude Code sessions with helpers (v1).
    public static func shows(_ session: AgentSession) -> Bool {
        session.agent == "Claude Code" && !session.helpers.isEmpty
    }

    /// The card's "Waiting on N helpers" line opens the waterfall.
    public static func opensFromDetail(_ detail: String, session: AgentSession) -> Bool {
        shows(session) && detail.hasPrefix("Waiting on ")
    }

    public static let detailGap = 4.0

    /// With the selected row's detail card, when one shows.
    public static func height(rows: Int, detail: HelperDetail?) -> Double {
        height(rows: rows) + (detail.map { $0.height + detailGap } ?? 0)
    }

    public static func height(rows: Int) -> Double {
        2 * padding + headerHeight + axisHeight + Double(rows) * rowHeight + captionHeight
    }

    /// The bar track's width inside a list `listWidth` wide: what the name and cost columns leave.
    public static func trackWidth(listWidth: Double) -> Double {
        max(0, listWidth - 2 * padding - nameWidth - costWidth - 2 * gap)
    }

    /// One bar per row in points. Running rows also say how far (`growTo`, a width) and how
    /// long (`growSeconds`, the time left on the axis) to grow; `key` leaves out running
    /// widths, so a view rebuilt a moment later with the same key keeps its animations.
    public static func bars(graph: HelperGraph, trackWidth: Double, now: Date) -> [BarSpec] {
        let left = max(0, graph.origin.addingTimeInterval(graph.axisSeconds).timeIntervalSince(now))
        let frame = "\(graph.origin.timeIntervalSince1970)|\(graph.axisSeconds)|\(trackWidth)"
        return graph.rows.map { row in
            let x = min(trackWidth, max(0, row.x * trackWidth))
            let width = min(trackWidth - x, max(0, row.width * trackWidth))
            let running = row.state == .running
            let key = "\(row.id)|\(row.state)|\(row.isCritical)|\(x)|\(running ? "" : "\(width)")|\(frame)"
            return BarSpec(id: row.id, x: x, width: width, state: row.state, isMain: row.id == "main" && row.depth == 0,
                           critical: row.isCritical, growTo: running ? trackWidth - x : nil,
                           growSeconds: running ? left : nil, key: key)
        }
    }

    /// What the bar layers are built from: every bar's key plus the view's height (bars are
    /// placed by row from the top, so a taller view after a new row must rebuild them).
    public static func layerKey(bars: [BarSpec], height: Double) -> [String] {
        bars.map(\.key) + ["height \(height)"]
    }

    /// The selected row, if it was picked in this turn and is still listed.
    public static func selected(_ id: String?, turn: Date?, current: Date?, rows: [String]) -> String? {
        guard let id, turn == current, rows.contains(id) else { return nil }
        return id
    }

    /// A click on a row selects it; a click on the selected row clears it.
    public static func toggle(selected: String?, row: String) -> String? {
        selected == row ? nil : row
    }
}

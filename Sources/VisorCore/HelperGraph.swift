import Foundation

/// The trace waterfall of one session's turn: the session's own row, then its helpers as an
/// indented tree, each with a bar on a shared time axis and the critical path flagged.
/// A pure value: the caller passes `now`, nothing here reads a clock or a file.
public struct HelperGraph: Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, done, failed, queued }
    /// Tree glyphs before a title: │, blank, ├, └.
    public enum Connector: Equatable, Sendable {
        case pipe, blank, tee, elbow
        var text: String {
            switch self {
            case .pipe: return "│ "
            case .blank: return "  "
            case .tee: return "├ "
            case .elbow: return "└ "
            }
        }
    }
    public struct Row: Equatable, Sendable, Identifiable {
        /// "main" for the session, else the helper's id (its Agent call).
        public var id: String
        public var title: String
        /// The helper's type; nil for the session's row.
        public var type: String?
        /// 0 the session, 1 the helpers it started, 2 theirs, ...
        public var depth: Int
        /// One glyph per level (count == depth); empty for the session.
        public var connectors: [Connector]
        public var prefix: String
        /// Bar start and length as fractions of the axis, within 0...1.
        public var x: Double
        public var width: Double
        public var state: State
        public var isCritical: Bool
        public var background: Bool
        /// Filled by the view from the helper's stats; nil here.
        public var cost: Double?
    }
    public struct Tick: Equatable, Sendable {
        public var x: Double
        public var label: String
    }

    /// Axis zero.
    public var origin: Date
    /// Axis length: the last tick sits at the right edge.
    public var axisSeconds: TimeInterval
    public var rows: [Row]
    public var ticks: [Tick]
    /// Flagged rows' titles in path order (by start).
    public var criticalTitles: [String]
    /// Length of the flagged chain, overlaps counted once.
    public var criticalSeconds: TimeInterval
    /// Turn start to the end of the last bar.
    public var turnSeconds: TimeInterval

    /// Tick steps; no 5 min, so 18-24 min turns read in 6 min steps.
    static let steps: [TimeInterval] = [1, 2, 5, 10, 15, 30,
                                        60, 120, 180, 360, 600, 900, 1800,
                                        3600, 7200, 10800, 21600, 43200]
    /// Most intervals on the axis.
    static let maxIntervals = 4.0
    /// Gap that still counts as one sibling waiting for the other.
    static let dependentGap: TimeInterval = 1

    public init(session: AgentSession, now: Date) {
        // A finished turn ends when the session went done or idle (`since`), not at `lastEvent`,
        // which a background helper's own tools keep moving after Stop.
        self.init(title: session.task ?? session.project, start: session.turnStart,
                  end: session.isActive ? nil : session.since, helpers: session.helpers, now: now)
    }

    /// `end` nil means the turn still runs (its bar ends at `now`).
    public init(title: String, start: Date?, end: Date?, helpers: [AgentHelper], now: Date) {
        // A helper left running from an earlier turn starts, on this axis, when this turn did.
        let helpers = helpers.map { h -> AgentHelper in
            var h = h
            if let s = h.start, let turn = start, s < turn { h.start = turn }
            return h
        }
        // Stable order by start (nil last), ties by input order; capped.
        let kept = helpers.indices.sorted { a, b in
            let sa = helpers[a].start ?? .distantFuture, sb = helpers[b].start ?? .distantFuture
            return sa != sb ? sa < sb : a < b
        }.prefix(AgentSession.maxHelpers).map { helpers[$0] }
        let count = kept.count

        // Parent links by agent id (first by start wins); self links ignored.
        var byAgent: [String: Int] = [:]
        for (i, h) in kept.enumerated() { if let a = h.agentID, byAgent[a] == nil { byAgent[a] = i } }
        var linked = [Int?](repeating: nil, count: count)
        var children = [[Int]](repeating: [], count: count)
        for (i, h) in kept.enumerated() {
            if let p = h.parent, let j = byAgent[p], j != i { linked[i] = j; children[j].append(i) }
        }

        // Effective tree: walk from roots with a visited set; a cycle with no root gets its earliest member promoted.
        var parentOf = [Int?](repeating: nil, count: count)
        var treeChildren = [[Int]](repeating: [], count: count)
        var visited = [Bool](repeating: false, count: count)
        var roots: [Int] = []
        func walk(from root: Int) {
            visited[root] = true
            var stack = [root]
            while let n = stack.popLast() {
                for c in children[n] where !visited[c] {
                    visited[c] = true; parentOf[c] = n; treeChildren[n].append(c); stack.append(c)
                }
            }
        }
        for i in 0..<count where linked[i] == nil { roots.append(i); walk(from: i) }
        for i in 0..<count where !visited[i] { roots.append(i); walk(from: i) }
        roots.sort()
        for i in 0..<count { treeChildren[i].sort() }

        // Times.
        func effectiveEnd(_ h: AgentHelper) -> Date { h.end ?? (h.done ? (h.start ?? now) : now) }
        let mainStart = start ?? kept.compactMap(\.start).min() ?? now
        let mainEnd = end ?? now
        let origin = ([mainStart] + kept.compactMap(\.start)).min() ?? mainStart
        let contentEnd = ([mainEnd] + kept.filter { $0.start != nil }.map(effectiveEnd)).max() ?? mainEnd
        let span = max(0, contentEnd.timeIntervalSince(origin))
        let step = Self.steps.first { (span / $0).rounded(.up) <= Self.maxIntervals } ?? Self.steps[Self.steps.count - 1]
        let intervals = max(1, Int((span / step).rounded(.up)))
        let axis = step * Double(intervals)
        self.origin = origin
        axisSeconds = axis
        turnSeconds = span
        ticks = (0...intervals).map { Tick(x: Double($0) * step / axis, label: Self.label(Double($0) * step)) }

        func bar(_ from: Date, _ to: Date) -> (x: Double, width: Double) {
            let x = min(1, max(0, from.timeIntervalSince(origin) / axis))
            let width = max(0, to.timeIntervalSince(from)) / axis
            return (x, min(width, 1 - x))
        }

        // Critical path: back from the latest end through siblings that finish before it starts, or up to the parent;
        // then down each flagged helper's latest-ending children.
        let eligible = (0..<count).filter { kept[$0].start != nil }
        func later(_ a: Int, _ b: Int) -> Bool {
            let ea = effectiveEnd(kept[a]), eb = effectiveEnd(kept[b])
            if ea != eb { return ea > eb }
            let sa = kept[a].start!, sb = kept[b].start!
            return sa != sb ? sa < sb : a < b
        }
        func latest(_ candidates: [Int]) -> Int? { candidates.min { later($0, $1) } }
        var critical = [Bool](repeating: false, count: count)
        if var current = latest(eligible) {
            critical[current] = true
            while true {
                let limit = kept[current].start!.addingTimeInterval(Self.dependentGap)
                let before = eligible.filter {
                    !critical[$0] && parentOf[$0] == parentOf[current] && effectiveEnd(kept[$0]) <= limit
                }
                if let previous = latest(before) {
                    current = previous
                } else if let parent = parentOf[current], kept[parent].start != nil, !critical[parent] {
                    current = parent
                } else { break }
                critical[current] = true
            }
            // Down only from the path's lower ends, so a parent the walk climbed through doesn't branch.
            for flagged in (0..<count).filter({ i in critical[i] && !treeChildren[i].contains { critical[$0] } }) {
                var node = flagged
                while let child = latest(treeChildren[node].filter { kept[$0].start != nil }), !critical[child] {
                    critical[child] = true; node = child
                }
            }
        }
        let path = (0..<count).filter { critical[$0] }   // kept order is start order
        criticalTitles = path.map { kept[$0].task }
        var covered: TimeInterval = 0
        var reach: Date?
        for i in path {
            let s = kept[i].start!, e = effectiveEnd(kept[i])
            let from = max(s, reach ?? s)
            if e > from { covered += e.timeIntervalSince(from) }
            reach = max(reach ?? e, e)
        }
        criticalSeconds = covered

        // Rows: the session, then the tree depth first.
        let mainBar = bar(mainStart, mainEnd)
        var rows = [Row(id: "main", title: title, type: nil, depth: 0, connectors: [], prefix: "",
                        x: mainBar.x, width: mainBar.width, state: end == nil ? .running : .done,
                        isCritical: false, background: false, cost: nil)]
        func emit(_ siblings: [Int], above: [Connector]) {
            for (n, i) in siblings.enumerated() {
                let h = kept[i], last = n == siblings.count - 1
                let connectors = above + [last ? .elbow : .tee]
                let from = h.start ?? now
                let b = bar(from, h.start == nil ? from : effectiveEnd(h))
                let state: State = h.failed ? .failed : h.done ? .done : h.agentID == nil ? .queued : .running
                rows.append(Row(id: h.id, title: h.task, type: h.type, depth: connectors.count, connectors: connectors,
                                prefix: connectors.map(\.text).joined(), x: b.x, width: b.width, state: state,
                                isCritical: critical[i], background: h.background, cost: nil))
                emit(treeChildren[i], above: above + [last ? .blank : .pipe])
            }
        }
        emit(roots, above: [])
        self.rows = rows
    }

    /// "0", "15s", "1m30s", "6m", "1h", "1h30m".
    static func label(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s == 0 { return "0" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m\(s % 60)s" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h\(m)m"
    }
}

import Foundation
import Testing
@testable import VisorCore

private let t0 = Date(timeIntervalSince1970: 2_000_000)
private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

private func helper(_ id: String, type: String = "general-purpose", parent: String? = nil, start: Double?, end: Double?,
                    agentID: String? = "", failed: Bool = false, dollars: Double? = nil, unpriced: Bool = false) -> AgentHelper {
    var h = AgentHelper(id: id, type: type, task: "task \(id)", done: end != nil)
    h.agentID = agentID == "" ? id : agentID
    h.parent = parent
    h.start = start.map(at)
    h.end = end.map(at)
    h.failed = failed
    if let dollars {
        var s = HelperStats()
        s.dollars = dollars
        s.tokens = 50_000
        s.unpriced = unpriced
        h.stats = s
    }
    return h
}

/// The mockup's 18 minute turn: Plan (0-10m) then builder (10m-18m), Explore overlapping, perf failed.
private func mockupGraph(now: Double = 1080) -> HelperGraph {
    HelperGraph(title: "add promo codes", start: t0, end: at(1080), helpers: [
        helper("e", type: "Explore", start: 0, end: 360),
        helper("p", type: "Plan", start: 0, end: 600),
        helper("b", type: "builder", start: 600, end: 1080),
        helper("f", type: "perf", start: 700, end: 760, failed: true),
    ], now: at(now))
}

private func session(agent: String = "Claude Code", total: Double?, unpriced: Bool = false, base: Double? = 0,
                     helpers: [AgentHelper]) -> AgentSession {
    var s = AgentSession(id: "s1", agent: agent, cwd: "/Users/me/web-shop", state: .working("Waiting on 1 helper"), since: t0)
    s.turnStart = t0
    s.turnCostBase = base
    if let total { s.cost = SessionCost(dollars: total, tokens: 100_000, unpriced: unpriced) }
    s.helpers = helpers
    return s
}

@Suite("Helper waterfall")
struct HelperWaterfallTests {
    @Test func captionTwoNames() {
        #expect(HelperWaterfall.caption(mockupGraph()) == "Critical path: Plan then builder (18 of 18 min)")
    }

    @Test func captionManyNamesAndSeconds() {
        let g = HelperGraph(title: "t", start: t0, end: at(50), helpers: [
            helper("a", type: "A", start: 0, end: 10), helper("b", type: "B", start: 10, end: 20),
            helper("c", type: "C", start: 20, end: 30), helper("d", type: "D", start: 30, end: 45),
        ], now: at(50))
        #expect(HelperWaterfall.caption(g) == "Critical path: A then 2 more then D (45 of 50 s)")
    }

    @Test func captionNone() {
        let g = HelperGraph(title: "t", start: t0, end: at(30), helpers: [], now: at(30))
        #expect(HelperWaterfall.caption(g) == nil)
    }

    @Test func failures() {
        #expect(HelperWaterfall.failures(mockupGraph()) == "perf failed")
        let none = HelperGraph(title: "t", start: t0, end: at(30), helpers: [helper("a", start: 0, end: 5)], now: at(30))
        #expect(HelperWaterfall.failures(none) == nil)
        let two = HelperGraph(title: "t", start: t0, end: at(30), helpers: [
            helper("a", start: 0, end: 5, failed: true), helper("b", start: 1, end: 6, failed: true),
        ], now: at(30))
        #expect(HelperWaterfall.failures(two) == "2 failed")
    }

    @Test func costsPricedAndBlank() {
        let s = session(total: 2.40, helpers: [
            helper("a", start: 0, end: 5, dollars: 0.48),
            helper("b", start: 1, end: 6, dollars: 0.81),
            helper("c", start: 2, end: nil),
            helper("d", start: 3, end: 4, dollars: 0.001),
        ])
        let costs = HelperWaterfall.costs(session: s)
        #expect(costs["a"] == "$0.48" && costs["b"] == "$0.81")
        #expect(costs["c"] == nil, "no stats yet: blank")
        #expect(costs["d"] == nil, "below a cent: blank")
        #expect(costs["main"] == nil, "a helper with no stats yet may have spent: main unknown")
    }

    @Test func costsMainFromTurnBase() {
        let helpers = [helper("a", start: 0, end: 5, dollars: 0.50)]
        #expect(HelperWaterfall.costs(session: session(total: 8, base: 5, helpers: helpers))["main"] == "$2.50",
                "earlier turns' spend is not main's")
        #expect(HelperWaterfall.costs(session: session(total: 8, base: nil, helpers: helpers))["main"] == nil)
        let early = [helper("a", start: -30, end: 5, dollars: 0.50)]
        #expect(HelperWaterfall.costs(session: session(total: 8, base: 5, helpers: early))["main"] == nil,
                "a helper from an earlier turn was partly counted in the base")
        let full = (0..<AgentSession.maxHelpers).map { helper("h\($0)", start: Double($0), end: 30, dollars: 0.01) }
        #expect(HelperWaterfall.costs(session: session(total: 8, base: 0, helpers: full))["main"] == nil,
                "at the cap, trimmed helpers' spend is unknown")
    }

    @Test func turnCostBaseOnPrompt() {
        let base = #""session_id":"s1","cwd":"/Users/me/api""#
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"one"}"#))
        #expect(board.sessions[0].turnCostBase == 0, "a first turn starts from nothing")
        board.setCost(SessionCost(dollars: 5, tokens: 1000, unpriced: false), session: "s1")
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"two"}"#))
        #expect(board.sessions[0].turnCostBase == 5)
        board.setCost(nil, session: "s1")
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"three"}"#))
        #expect(board.sessions[0].turnCostBase == nil, "cost unknown at a later prompt: no base")
    }

    @Test func layerKeyIncludesHeight() {
        let g = mockupGraph()
        let bars = HelperWaterfall.bars(graph: g, trackWidth: 200, now: at(1080))
        #expect(HelperWaterfall.layerKey(bars: bars, height: 90) == HelperWaterfall.layerKey(bars: bars, height: 90))
        #expect(HelperWaterfall.layerKey(bars: bars, height: 90) != HelperWaterfall.layerKey(bars: bars, height: 108),
                "a taller view moves the bars")
    }

    @Test func selectionClearsOnNewTurn() {
        let rows = ["main", "b"]
        #expect(HelperWaterfall.selected("b", turn: t0, current: t0, rows: rows) == "b")
        #expect(HelperWaterfall.selected("b", turn: t0, current: at(60), rows: rows) == nil, "a new turn")
        #expect(HelperWaterfall.selected("main", turn: t0, current: at(60), rows: rows) == nil)
        #expect(HelperWaterfall.selected("gone", turn: t0, current: t0, rows: rows) == nil, "row no longer listed")
        #expect(HelperWaterfall.selected(nil, turn: nil, current: t0, rows: rows) == nil)
    }

    @Test func costsUnpricedBlank() {
        let s = session(total: 2.40, helpers: [
            helper("a", start: 0, end: 5, dollars: 0.48),
            helper("u", start: 1, end: 6, dollars: 0, unpriced: true),
        ])
        let costs = HelperWaterfall.costs(session: s)
        #expect(costs["u"] == nil)
        #expect(costs["main"] == nil, "an unpriced helper makes the remainder unknown")
        #expect(costs["a"] == "$0.48")
        #expect(HelperWaterfall.costs(session: session(total: nil, helpers: [helper("a", start: 0, end: 5, dollars: 0.5)]))["main"] == nil)
    }

    @Test func elapsed() {
        #expect(HelperWaterfall.elapsed(seconds: 45) == "45s")
        #expect(HelperWaterfall.elapsed(seconds: 1080) == "18m")
        #expect(HelperWaterfall.elapsed(seconds: 3900) == "1h 5m")
    }

    @Test func opensFromDetail() {
        let s = session(total: nil, helpers: [helper("a", start: 0, end: nil)])
        #expect(HelperWaterfall.opensFromDetail("Waiting on 1 helper", session: s))
        #expect(!HelperWaterfall.opensFromDetail("Editing cart.ts", session: s))
        #expect(!HelperWaterfall.opensFromDetail("Waiting on 1 helper", session: session(total: nil, helpers: [])))
    }

    @Test func opensFromDetailClaudeOnly() {
        for agent in ["Codex CLI", "OpenCode", "Gemini CLI", "Antigravity"] {
            let s = session(agent: agent, total: nil, helpers: [helper("a", start: 0, end: nil)])
            #expect(!HelperWaterfall.opensFromDetail("Waiting on 1 helper", session: s), "\(agent)")
            #expect(!HelperWaterfall.shows(s), "\(agent)")
        }
        #expect(HelperWaterfall.shows(session(total: nil, helpers: [helper("a", start: 0, end: nil)])))
    }

    @Test func heightFor21Rows() {
        let w = HelperWaterfall.self
        #expect(w.height(rows: 21) == 2 * w.padding + w.headerHeight + w.axisHeight + 21 * w.rowHeight + w.captionHeight)
        #expect(w.height(rows: 1) < w.height(rows: 21))
    }

    @Test func barsColoursAndCritical() {
        let g = HelperGraph(title: "t", start: t0, end: nil, helpers: [
            helper("d", start: 0, end: 10),
            helper("r", start: 5, end: nil),
            helper("f", start: 6, end: 8, failed: true),
            helper("q", start: 7, end: nil, agentID: nil),
        ], now: at(20))
        let bars = HelperWaterfall.bars(graph: g, trackWidth: 200, now: at(20))
        let state = Dictionary(uniqueKeysWithValues: bars.map { ($0.id, $0.state) })
        #expect(state == ["main": .running, "d": .done, "r": .running, "f": .failed, "q": .queued])
        #expect(bars.first { $0.id == "main" }?.isMain == true)
        #expect(bars.map(\.critical) == g.rows.map(\.isCritical))
        #expect(bars.contains { $0.critical }, "a critical row is outlined")
    }

    @Test func barsGrowthRunningOnly() {
        // 50 s so far on a 60 s axis (steps 15 s): running bars grow 10 s more to the edge.
        let g = HelperGraph(title: "t", start: t0, end: nil, helpers: [
            helper("d", start: 0, end: 10), helper("r", start: 30, end: nil),
        ], now: at(50))
        #expect(g.axisSeconds == 60)
        let bars = HelperWaterfall.bars(graph: g, trackWidth: 240, now: at(50))
        guard let r = bars.first(where: { $0.id == "r" }), let d = bars.first(where: { $0.id == "d" }),
              let main = bars.first(where: { $0.id == "main" }) else { Issue.record("rows missing"); return }
        #expect(abs(r.x - 120) < 0.001 && abs(r.width - 80) < 0.001)
        #expect(r.growTo.map { abs($0 - 120) < 0.001 } == true, "width that reaches the track's right edge")
        #expect(r.growSeconds.map { abs($0 - 10) < 0.001 } == true)
        #expect(main.growSeconds.map { abs($0 - 10) < 0.001 } == true)
        #expect(d.growTo == nil && d.growSeconds == nil)
    }

    @Test func barsKeyIgnoresRunningWidth() {
        let helpers = [helper("d", start: 0, end: 10), helper("r", start: 12, end: nil)]
        let a = HelperGraph(title: "t", start: t0, end: nil, helpers: helpers, now: at(46))
        let b = HelperGraph(title: "t", start: t0, end: nil, helpers: helpers, now: at(50))
        #expect(a.axisSeconds == b.axisSeconds)
        let ka = HelperWaterfall.bars(graph: a, trackWidth: 200, now: at(46)).map(\.key)
        let kb = HelperWaterfall.bars(graph: b, trackWidth: 200, now: at(50)).map(\.key)
        #expect(!ka.isEmpty && ka == kb)
        var done = helpers
        done[1].done = true; done[1].end = at(30)
        let c = HelperGraph(title: "t", start: t0, end: nil, helpers: done, now: at(50))
        #expect(HelperWaterfall.bars(graph: c, trackWidth: 200, now: at(50)).map(\.key) != kb, "a state change re-keys")
    }

    @Test func barsFitTrack() {
        var helpers: [AgentHelper] = []
        for i in 0..<20 {
            let start = Double(i) * 30
            let end: Double? = i % 3 == 0 ? nil : start + 200
            helpers.append(helper("h\(i)", start: start, end: end))
        }
        let g = HelperGraph(title: "t", start: t0, end: nil, helpers: helpers, now: at(900))
        #expect(g.rows.count == 21)
        for list in [420.0, 396.0] {
            let track = HelperWaterfall.trackWidth(listWidth: list)
            #expect(track >= 150)
            #expect(track + HelperWaterfall.nameWidth + HelperWaterfall.costWidth + 2 * HelperWaterfall.gap + 2 * HelperWaterfall.padding <= list)
            let bars = HelperWaterfall.bars(graph: g, trackWidth: track, now: at(900))
            #expect(bars.count == 21)
            for bar in bars {
                let right: Double = bar.x + bar.width
                let grow: Double = bar.growTo ?? 0
                #expect(bar.x >= 0)
                #expect(right <= track + 0.001)
                #expect(grow <= track + 0.001)
            }
        }
    }

    @Test func selectionToggles() {
        #expect(HelperWaterfall.toggle(selected: nil, row: "b") == "b")
        #expect(HelperWaterfall.toggle(selected: "b", row: "b") == nil)
        #expect(HelperWaterfall.toggle(selected: "a", row: "b") == "b")
    }

    @Test func onlyCurrentTurn() {
        let base = #""session_id":"s1","cwd":"/Users/me/api""#
        func task(_ id: String) -> HookMessage {
            hook("PreToolUse", #"{\#(base),"tool_name":"Agent","tool_use_id":"\#(id)","tool_input":{"description":"job \#(id)","subagent_type":"Explore"}}"#)
        }
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"one"}"#))
        board.apply(task("t1"))
        board.apply(hook("SubagentStart", #"{\#(base),"agent_id":"a1","agent_type":"Explore"}"#))
        board.apply(hook("SubagentStop", #"{\#(base),"agent_id":"a1","agent_type":"Explore"}"#))
        board.apply(hook("Stop", "{\(base)}"))
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"two"}"#))
        board.apply(task("t2"))
        let g = HelperGraph(session: board.sessions[0], now: Date())
        #expect(g.rows.map(\.id) == ["main", "t2"])
    }
}

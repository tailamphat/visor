import Foundation
import Testing
@testable import VisorCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

/// A helper started `start` seconds after t0, ended at `end` (nil = still running).
private func helper(_ id: String, _ task: String? = nil, parent: String? = nil, start: Double?, end: Double?,
                    agentID: String? = "", failed: Bool = false, background: Bool = false) -> AgentHelper {
    var h = AgentHelper(id: id, type: "general-purpose", task: task ?? id, done: end != nil, background: background)
    h.agentID = agentID == "" ? id : agentID
    h.parent = parent
    h.start = start.map { t0.addingTimeInterval($0) }
    h.end = end.map { t0.addingTimeInterval($0) }
    h.failed = failed
    return h
}

private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

@Suite("Helper graph")
struct HelperGraphTests {
    @Test func mainRowOnly() {
        let g = HelperGraph(title: "Fix tests", start: t0, end: at(30), helpers: [], now: at(40))
        #expect(g.rows.count == 1)
        let main = g.rows[0]
        #expect(main.id == "main" && main.title == "Fix tests" && main.depth == 0)
        #expect(main.connectors.isEmpty && main.prefix == "" && main.type == nil)
        #expect(main.state == .done && !main.isCritical)
        #expect(g.ticks.first?.label == "0" && g.ticks.first?.x == 0)
        #expect(g.criticalTitles.isEmpty && g.criticalSeconds == 0 && g.turnSeconds == 30)
    }

    @Test func nestingAndConnectors() {
        let helpers = [
            helper("B", start: 5, end: 9),
            helper("A2", parent: "A", start: 3, end: 4),
            helper("A", start: 1, end: 8),
            helper("A1", parent: "A", start: 2, end: 3),
        ]
        let g = HelperGraph(title: "t", start: t0, end: at(10), helpers: helpers, now: at(10))
        #expect(g.rows.map(\.id) == ["main", "A", "A1", "A2", "B"])
        #expect(g.rows.map(\.depth) == [0, 1, 2, 2, 1])
        #expect(g.rows.map(\.prefix) == ["", "├ ", "│ ├ ", "│ └ ", "└ "])
        #expect(g.rows[3].connectors == [.pipe, .elbow])
        #expect(g.rows[4].connectors == [.elbow])
        #expect(g.rows.allSatisfy { $0.connectors.count == $0.depth })
    }

    @Test func stableOrderByStart() {
        let helpers = [
            helper("x", start: 2, end: 3), helper("y", start: 1, end: 3),
            helper("z", start: 2, end: 3), helper("w", start: nil, end: nil),
        ]
        let g = HelperGraph(title: "t", start: t0, end: at(5), helpers: helpers, now: at(5))
        #expect(g.rows.map(\.id) == ["main", "y", "x", "z", "w"])
        let again = HelperGraph(title: "t", start: t0, end: at(5), helpers: helpers.reversed(), now: at(5))
        #expect(again.rows.map(\.id) == ["main", "y", "z", "x", "w"], "equal starts keep input order")
    }

    @Test func orphanIsTopLevel() {
        let g = HelperGraph(title: "t", start: t0, end: at(5),
                            helpers: [helper("a", start: 1, end: 2), helper("o", parent: "gone", start: 1.5, end: 3)],
                            now: at(5))
        #expect(g.rows.map(\.id) == ["main", "a", "o"])
        #expect(g.rows.map(\.depth) == [0, 1, 1])
        #expect(g.rows.map(\.prefix) == ["", "├ ", "└ "])
    }

    @Test func cyclesNeverLoop() {
        let helpers = [
            helper("self", parent: "self", start: 1, end: 2),
            helper("a", parent: "b", start: 2, end: 4),
            helper("b", parent: "a", start: 3, end: 4),
        ]
        let g = HelperGraph(title: "t", start: t0, end: at(5), helpers: helpers, now: at(5))
        #expect(g.rows.count == 4)
        #expect(Set(g.rows.map(\.id)) == ["main", "self", "a", "b"])
        #expect(g.rows.allSatisfy { $0.depth <= 2 })
        #expect(g.rows.first { $0.id == "self" }?.depth == 1)
    }

    @Test func barFractions() {
        // 0..20 s turn: step 5 s, axis 20 s.
        let g = HelperGraph(title: "t", start: t0, end: at(20), helpers: [helper("a", start: 5, end: 15)], now: at(30))
        #expect(g.axisSeconds == 20 && g.origin == t0)
        #expect(g.rows[0].x == 0 && g.rows[0].width == 1)
        #expect(g.rows[1].x == 0.25 && g.rows[1].width == 0.5)
    }

    @Test func runningEndsAtNow() {
        let g = HelperGraph(title: "t", start: t0, end: nil,
                            helpers: [helper("a", start: 5, end: nil), helper("bad", start: 12, end: 8)], now: at(10))
        // span 10 s: step 5 s, 2 intervals, axis 10 s.
        #expect(g.axisSeconds == 10)
        #expect(g.rows[0].state == .running && g.rows[0].width == 1)
        #expect(g.rows[1].state == .running && g.rows[1].x == 0.5 && g.rows[1].width == 0.5)
        #expect(g.rows[2].width == 0, "end before start never goes negative")
        #expect(g.rows.allSatisfy { $0.x >= 0 && $0.x + $0.width <= 1 + 1e-9 })
    }

    @Test func backgroundOutlivesTurn() {
        let g = HelperGraph(title: "t", start: t0, end: at(10),
                            helpers: [helper("bg", start: 2, end: 18, background: true)], now: at(18))
        #expect(g.axisSeconds == 20)
        let main = g.rows[0], bg = g.rows[1]
        #expect(main.width == 0.5)
        #expect(bg.background && abs(bg.x + bg.width - 0.9) < 1e-9 && bg.x + bg.width > main.x + main.width)
        #expect(g.turnSeconds == 18)
    }

    @Test func criticalPathSequentialSiblings() {
        let m = 60.0
        let helpers = [
            helper("other", "Survey", start: 0, end: 6 * m),
            helper("plan", "Plan", start: 0.5, end: 10 * m),
            helper("build", "builder", start: 10 * m, end: 18 * m),
        ]
        let g = HelperGraph(title: "t", start: t0, end: at(18 * m), helpers: helpers, now: at(18 * m))
        let flagged = Dictionary(uniqueKeysWithValues: g.rows.map { ($0.id, $0.isCritical) })
        #expect(flagged["plan"] == true && flagged["build"] == true && flagged["other"] == false)
        #expect(flagged["main"] == false)
        #expect(g.criticalTitles == ["Plan", "builder"])
        #expect(abs(g.criticalSeconds - (18 * m - 0.5)) < 1e-6)
        #expect(g.turnSeconds == 18 * m)
    }

    @Test func criticalPathExactTurn() {
        let m = 60.0
        let helpers = [
            helper("plan", "Plan", start: 0, end: 10 * m),
            helper("build", "builder", start: 10 * m, end: 18 * m),
            helper("other", "Survey", start: 0, end: 6 * m),
        ]
        let g = HelperGraph(title: "t", start: t0, end: at(18 * m), helpers: helpers, now: at(18 * m))
        #expect(g.criticalTitles == ["Plan", "builder"])
        #expect(g.criticalSeconds == 1080 && g.turnSeconds == 1080)
        #expect(g.ticks.map(\.label) == ["0", "6m", "12m", "18m"])
    }

    @Test func criticalPath() {
        // Latest end is a root: downward, its latest-ending child chain.
        let helpers = [
            helper("r1", start: 0, end: 4),
            helper("r2", start: 1, end: 9),
            helper("c1", parent: "r2", start: 2, end: 5),
            helper("c2", parent: "r2", start: 3, end: 8),
            helper("g", parent: "c2", start: 4, end: 7),
        ]
        let g = HelperGraph(title: "t", start: t0, end: at(10), helpers: helpers, now: at(10))
        let critical = g.rows.filter(\.isCritical).map(\.id)
        #expect(critical == ["r2", "c2", "g"])
        #expect(g.criticalTitles == ["r2", "c2", "g"])
        #expect(g.criticalSeconds == 8)

        // Latest end is a nested background child: the walk climbs to its parent.
        let climb = HelperGraph(title: "t", start: t0, end: at(10),
                                helpers: helpers + [helper("bgc", parent: "r1", start: 2, end: 12, background: true)], now: at(12))
        #expect(climb.rows.filter(\.isCritical).map(\.id) == ["r1", "bgc"])
        #expect(climb.criticalSeconds == 12)

        // Ties on end go to the earlier start.
        let tie = HelperGraph(title: "t", start: t0, end: at(10),
                              helpers: [helper("late", start: 3, end: 9), helper("early", start: 1, end: 9)], now: at(10))
        #expect(tie.rows.filter(\.isCritical).map(\.id) == ["early"])
    }

    @Test func criticalPathClimbDoesNotBranch() {
        // B (background, under P) ends last; the walk climbs P then G. X ran beside P and is not on the path.
        let helpers = [
            helper("G", start: 0, end: 20),
            helper("P", parent: "G", start: 1, end: 5),
            helper("X", parent: "G", start: 2, end: 15),
            helper("B", parent: "P", start: 3, end: 30, background: true),
        ]
        let g = HelperGraph(title: "t", start: t0, end: at(20), helpers: helpers, now: at(30))
        #expect(g.criticalTitles == ["G", "P", "B"])
        #expect(g.rows.first { $0.id == "X" }?.isCritical == false)
        #expect(g.criticalSeconds == 30)
    }

    @Test func sessionEndIgnoresBackgroundEvents() {
        let base = #""session_id":"s1","cwd":"/Users/me/api""#
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"go"}"#), now: at(0))
        board.apply(hook("PreToolUse", #"{\#(base),"tool_name":"Agent","tool_use_id":"t1","tool_input":{"description":"Watch logs","subagent_type":"general-purpose","run_in_background":true}}"#), now: at(1))
        board.apply(hook("SubagentStart", #"{\#(base),"agent_id":"a1","agent_type":"general-purpose"}"#), now: at(2))
        board.apply(hook("PostToolUse", #"{\#(base),"tool_name":"Agent","tool_use_id":"t1","tool_input":{"run_in_background":true}}"#), now: at(3))
        board.apply(hook("Stop", #"{\#(base)}"#), now: at(10))
        board.apply(hook("PreToolUse", #"{\#(base),"agent_id":"a1","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"ls"}}"#), now: at(25))
        #expect(board.sessions[0].state == .done)
        let g = HelperGraph(session: board.sessions[0], now: at(25))
        #expect(g.axisSeconds == 30)
        #expect(g.rows[0].state == .done && abs(g.rows[0].width - 10.0 / 30) < 1e-9, "the turn ended at Stop")
        #expect(g.rows[1].state == .running && abs(g.rows[1].x + g.rows[1].width - 25.0 / 30) < 1e-9)
    }

    @Test func staleHelperClampedToTurn() {
        // A helper whose stop was missed in an earlier turn: it starts, on this axis, when this turn did.
        let g = HelperGraph(title: "t", start: t0, end: at(120),
                            helpers: [helper("stale", start: -3600, end: nil), helper("new", start: 10, end: 100)], now: at(120))
        #expect(g.origin == t0 && g.turnSeconds == 120 && g.axisSeconds == 120)
        #expect(g.ticks.map(\.label) == ["0", "30s", "1m", "1m30s", "2m"])
        #expect(g.rows.map(\.id) == ["main", "stale", "new"])
        #expect(g.rows[1].x == 0 && g.rows[1].width == 1)
    }

    @Test func startlessHelperDoesNotStretchAxis() {
        let g = HelperGraph(title: "t", start: t0, end: at(10),
                            helpers: [helper("old", start: nil, end: nil), helper("a", start: 2, end: 8)], now: at(7200))
        #expect(g.turnSeconds == 10 && g.axisSeconds == 10)
        #expect(g.rows.allSatisfy { $0.x >= 0 && $0.x + $0.width <= 1 + 1e-9 })
    }

    @Test func criticalPathRunning() {
        let helpers = [helper("done", start: 0, end: 8), helper("run", start: 1, end: nil)]
        let g = HelperGraph(title: "t", start: t0, end: nil, helpers: helpers, now: at(10))
        #expect(g.rows.filter(\.isCritical).map(\.id) == ["run"])
        #expect(g.criticalSeconds == 9 && g.turnSeconds == 10)
    }

    @Test func ticks() {
        func labels(_ span: Double) -> [String] {
            HelperGraph(title: "t", start: t0, end: at(span), helpers: [], now: at(span)).ticks.map(\.label)
        }
        #expect(labels(45) == ["0", "15s", "30s", "45s"])
        #expect(labels(20 * 60) == ["0", "6m", "12m", "18m", "24m"])
        #expect(labels(90 * 60) == ["0", "30m", "1h", "1h30m"])
        #expect(labels(0) == ["0", "1s"])
        let g = HelperGraph(title: "t", start: t0, end: at(45), helpers: [], now: at(45))
        #expect(g.ticks.last?.x == 1 && g.ticks.map(\.x) == [0, 1.0 / 3, 2.0 / 3, 1])
    }

    @Test func states() {
        let helpers = [
            helper("d", start: 1, end: 2),
            helper("r", start: 1, end: nil),
            helper("f", start: 1, end: 2, failed: true),
            helper("q", start: 1, end: nil, agentID: nil),
        ]
        let g = HelperGraph(title: "t", start: t0, end: nil, helpers: helpers, now: at(3))
        #expect(g.rows.map(\.state) == [.running, .done, .running, .failed, .queued])
        let finished = HelperGraph(title: "t", start: t0, end: at(3), helpers: [], now: at(3))
        #expect(finished.rows[0].state == .done)
    }

    @Test func cappedAt20() {
        let helpers = (0..<30).map { helper("h\($0)", start: Double($0), end: Double($0) + 1) }
        let g = HelperGraph(title: "t", start: t0, end: at(40), helpers: helpers, now: at(40))
        #expect(g.rows.count == AgentSession.maxHelpers + 1)
        #expect(g.rows.dropFirst().map(\.id) == (0..<20).map { "h\($0)" })
    }

    @Test func realFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-nested-helpers/hooks.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var board = AgentBoard()
        for (n, line) in lines.enumerated() {
            let payload = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let message = HookMessage(event: payload["hook_event_name"] as? String ?? "", pid: 4242, payload: payload)
            board.apply(message, now: at(Double(n)))
        }
        let g = HelperGraph(session: board.sessions[0], now: at(30))
        #expect(g.rows.map(\.title).dropFirst() == ["Nested echo helper", "Run echo hi check", "Read nonexistent file helper"])
        #expect(g.rows.map(\.prefix) == ["", "├ ", "│ └ ", "└ "])
        // Nested echo ends last (15 s); no root ends by its start + 1 s, so nothing before it;
        // downward its latest-ending child Run echo hi. Read nonexistent overlaps and is not on the path.
        #expect(g.rows.map(\.isCritical) == [false, true, true, false])
        #expect(g.criticalTitles == ["Nested echo helper", "Run echo hi check"])
        #expect(g.criticalSeconds == 14 && g.turnSeconds == 17)
        #expect(g.ticks.map(\.label) == ["0", "5s", "10s", "15s", "20s"])
        #expect(g.rows[0].x == 0 && abs(g.rows[0].width - 0.85) < 1e-9)
        #expect(g.rows.allSatisfy { $0.state == .done })
    }

    @Test func costIsOptional() {
        var g = HelperGraph(title: "t", start: t0, end: at(5), helpers: [helper("a", start: 1, end: 2)], now: at(5))
        #expect(g.rows.allSatisfy { $0.cost == nil })
        g.rows[1].cost = 0.42
        #expect(g.rows[1].cost == 0.42)
    }

    @Test func deterministic() {
        let helpers = [helper("a", start: 1, end: nil), helper("b", parent: "a", start: 2, end: 3)]
        let one = HelperGraph(title: "t", start: t0, end: nil, helpers: helpers, now: at(7))
        let two = HelperGraph(title: "t", start: t0, end: nil, helpers: helpers, now: at(7))
        #expect(one == two)
        #expect(one != HelperGraph(title: "t", start: t0, end: nil, helpers: helpers, now: at(9)))
    }
}

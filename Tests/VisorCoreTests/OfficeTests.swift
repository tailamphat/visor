import Foundation
import Testing
@testable import VisorCore

@Suite("Agent office")
struct OfficeTests {
    func session(_ id: String, _ agent: String, _ state: AgentState = .working("Thinking")) -> AgentSession {
        var s = AgentSession(id: id, pid: 1, cwd: "/Users/me/\(id)", state: state, since: Date(), lastEvent: Date())
        s.agent = agent
        return s
    }

    func sessions(_ counts: [(String, Int)], state: AgentState = .working("Thinking")) -> [AgentSession] {
        counts.flatMap { agent, n in (0..<n).map { session("\(agent)-\($0)", agent, state) } }
    }

    /// Each tool is a table, two seats per column; tables flow left to right and wrap.
    @Test func islandsFlowAndWrap() {
        let scene = Office.place(sessions([("Claude Code", 3), ("Copilot CLI", 2), ("Antigravity", 2), ("OpenCode", 1)]))
        let islands = scene.layout.islands
        #expect(islands.map(\.agent) == ["Claude Code", "Copilot CLI", "Antigravity", "OpenCode"])
        #expect(islands.map(\.x) == [8, 68, 106, 144])
        #expect(islands.map(\.width) == [52, 30, 30, 30])
        #expect(islands.allSatisfy { $0.y == 18 }, "room above the first tables for their names and the bars over heads")
        #expect(scene.layout.rows == 1 && scene.layout.height == 133)

        let wide = Office.place(sessions([("Claude Code", 11), ("Copilot CLI", 11)])).layout.islands
        #expect(wide.map(\.x) == [8, 8] && wide.map(\.y) == [18, 84], "the second table doesn't fit beside the first")
    }

    /// A tool with more sessions than one table holds gets a second table.
    @Test func bigGroupsSplit() {
        let islands = Office.place(sessions([("Claude Code", 18)])).layout.islands
        #expect(islands.map(\.seats) == [16, 2])
        #expect(islands.map(\.total) == [18, 18])
    }

    /// Two rows of tables at most; the rest are counted, not drawn.
    @Test func overflowIsCounted() {
        let scene = Office.place(sessions([("Claude Code", 16), ("Copilot CLI", 16), ("Antigravity", 16)]))
        #expect(scene.layout.rows == 2 && scene.agents.count == 32 && scene.hidden == 16)
    }

    /// Seats alternate: top of the table facing you, bottom facing the table.
    @Test func seatsFaceEachOther() {
        let scene = Office.place(sessions([("Claude Code", 3)], state: .working("Edit: a.swift")))
        let a = scene.agents
        #expect(a[0].feet == OfficePoint(x: 23, y: 32) && !a[0].facesUp && a[0].access == 15)
        #expect(a[1].feet == OfficePoint(x: 23, y: 68) && a[1].facesUp && a[1].access == 73)
        #expect(a[2].feet.x == 45 && !a[2].facesUp)
        #expect(a[0].screen == OfficePoint(x: 20, y: 38) && a[1].screen == OfficePoint(x: 20, y: 45))
    }

    /// What an agent is doing decides where it goes.
    @Test func activityPicksTheSpot() {
        #expect(Office.spot(for: .working("Bash: npm test")) == (.terminal, .running))
        #expect(Office.spot(for: .working("Grep: useCart")) == (.docs, .reading))
        #expect(Office.spot(for: .working("Read: App.tsx")) == (.docs, .reading))
        #expect(Office.spot(for: .working("WebFetch: docs.stripe.com")) == (.web, .browsing))
        #expect(Office.spot(for: .working("Edit: main.go")) == (.desk, .typing))
        #expect(Office.spot(for: .working("Thinking")) == (.desk, .thinking))
        #expect(Office.spot(for: .needsApproval("Bash: git push")) == (.you, .approval))
        #expect(Office.spot(for: .asking("Auth library")) == (.you, .question))
        #expect(Office.spot(for: .needsInput) == (.you, .question))
        #expect(Office.spot(for: .done) == (.sofa, .done))
        #expect(Office.spot(for: .idle) == (.desk, .idle), "ready and waiting: dozing at its desk")
    }

    /// Each agent carries its context (whole percent, for the bar over its head) and
    /// when its state began (for the time it's been waiting).
    @Test func agentsCarryContextAndSince() {
        var s = session("a", "Claude Code", .needsApproval("Bash: git push"))
        s.contextTokens = 172_000
        s.contextWindow = 200_000
        let since = Date(timeIntervalSince1970: 1_000)
        s.since = since
        let agent = Office.place([s, session("b", "Copilot CLI")]).agents
        #expect(agent[0].context == 86 && agent[0].since == since)
        #expect(agent[1].context == nil, "no context known: no bar")
    }

    /// Tools Visor knows first, in the notch's order; others after, by name.
    @Test func toolsInOrder() {
        let scene = Office.place([session("a", "OpenCode"), session("b", "Copilot CLI"), session("c", "Claude Code"), session("d", "Codex")])
        #expect(scene.agents.map(\.id) == ["c", "b", "d", "a"])
    }

    /// Agents at the same station stand side by side.
    @Test func sharedSpotsSpreadOut() {
        let scene = Office.place([
            session("a", "Claude Code", .working("Bash: npm test")),
            session("b", "Claude Code", .working("Bash: swift test")),
            session("d", "Claude Code", .needsApproval("Bash: git push")),
            session("e", "Claude Code", .done),
        ])
        let layout = scene.layout
        let a = scene.agents[0], b = scene.agents[1], d = scene.agents[2], e = scene.agents[3]
        #expect(a.feet.y == layout.stationLine && b.feet.y == layout.stationLine && a.facesUp)
        #expect(a.feet.x == OfficeLayout.terminalX - 5.5 && b.feet.x == OfficeLayout.terminalX + 5.5)
        #expect(d.feet == OfficePoint(x: OfficeLayout.youX, y: layout.corridor) && !d.facesUp)
        #expect(e.sits && !e.facesUp)
        #expect(scene.waiting == 1)
    }

    /// The sofa seats three; whoever else is done stays at their desk.
    @Test func sofaSeatsThree() {
        let scene = Office.place((0..<5).map { session("d\($0)", "Claude Code", .done) })
        #expect(scene.agents.filter { $0.spot == .sofa }.count == 3)
        #expect(scene.agents.filter { $0.spot == .desk && $0.activity == .done }.count == 2)
        let seated = scene.agents.filter { $0.spot == .sofa && $0.sits }.count
        #expect(seated == 3)
    }

    /// A crowd at one station packs closer and stays inside the room.
    @Test func crowdsStayInTheRoom() {
        let scene = Office.place((0..<8).map { session("t\($0)", "Claude Code", .working("Bash: make")) })
        let xs = scene.agents.map(\.feet.x)
        let lowest = xs.min() ?? 0, highest = xs.max() ?? 0
        #expect(lowest >= 6 && highest <= OfficeLayout.terminalX + 20)
        #expect(Set(xs).count == 8, "still side by side")
    }

    /// From a seat: out to its aisle, along it to a walkway at the side, down, then across.
    /// Between the corridor and the stations: through the gaps between stations.
    @Test func routesGoAroundTables() {
        let layout = Office.place(sessions([("Claude Code", 2)])).layout
        let seat = OfficePoint(x: 23, y: 32)
        let terminal = OfficePoint(x: OfficeLayout.terminalX, y: layout.stationLine)
        #expect(layout.route(from: seat, access: 15, to: terminal, access: layout.stationLine)
                == [OfficePoint(x: 23, y: 15), OfficePoint(x: 4, y: 15), OfficePoint(x: 4, y: layout.stationLine), terminal])

        let lower = OfficePoint(x: 23, y: 68)
        let you = OfficePoint(x: OfficeLayout.youX, y: layout.corridor)
        #expect(layout.route(from: lower, access: 73, to: you, access: layout.corridor)
                == [OfficePoint(x: 23, y: 73), OfficePoint(x: 82, y: 73), OfficePoint(x: 82, y: layout.corridor), you])

        let along = OfficePoint(x: 100, y: layout.stationLine)
        #expect(layout.route(from: terminal, access: layout.stationLine, to: along, access: layout.stationLine) == [along])
    }
}

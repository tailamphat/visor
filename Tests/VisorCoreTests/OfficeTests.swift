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

    /// Rows of 8 desks, one row taller per 8 sessions; past 16, rows of 10; never more than 3 rows.
    @Test func roomGrowsWithSessions() {
        let one = OfficeLayout(sessions: 1)
        #expect(one.rows == 1 && one.perRow == 8 && one.height == 110)
        #expect(OfficeLayout(sessions: 8).rows == 1)
        #expect(OfficeLayout(sessions: 9).rows == 2)
        let many = OfficeLayout(sessions: 17)
        #expect(many.perRow == 10 && many.rows == 2 && many.cellWidth == 22)
        let crowd = OfficeLayout(sessions: 40)
        #expect(crowd.rows == 3 && crowd.capacity == 30 && crowd.height == 182)
        #expect(OfficeLayout(sessions: 0).rows == 1)
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

    /// Desks are grouped by tool, Claude Code first, any other tool after the known ones,
    /// and each run of a tool's desks in a row is one labelled rug.
    @Test func desksGroupByToolAndWrap() {
        let sessions = [
            session("a", "Copilot CLI"), session("b", "Claude Code"), session("c", "Antigravity"),
            session("d", "Claude Code"), session("e", "OpenCode"), session("f", "Copilot CLI"),
            session("g", "Claude Code"), session("h", "Antigravity"), session("i", "Codex"),
        ]
        let scene = Office.place(sessions)
        #expect(scene.agents.map(\.id) == ["b", "d", "g", "a", "f", "c", "h", "i", "e"])
        #expect(scene.segments == [
            OfficeSegment(agent: "Claude Code", row: 0, column: 0, length: 3, count: 3),
            OfficeSegment(agent: "Copilot CLI", row: 0, column: 3, length: 2, count: 2),
            OfficeSegment(agent: "Antigravity", row: 0, column: 5, length: 2, count: 2),
            OfficeSegment(agent: "Codex", row: 0, column: 7, length: 1, count: 1),
            OfficeSegment(agent: "OpenCode", row: 1, column: 0, length: 1, count: 1),
        ])
        // Each session keeps its desk, wherever it is.
        #expect(scene.agents[0].desk == OfficePoint(x: 9 + 14, y: 16))
        #expect(scene.agents[8].desk == OfficePoint(x: 9 + 14, y: 52))
    }

    /// Agents at the same place stand side by side; at a desk an agent sits facing it.
    @Test func sharedSpotsSpreadOut() {
        let scene = Office.place([
            session("a", "Claude Code", .working("Bash: npm test")),
            session("b", "Claude Code", .working("Bash: swift test")),
            session("c", "Claude Code", .working("Edit: a.swift")),
            session("d", "Claude Code", .needsApproval("Bash: git push")),
            session("e", "Claude Code", .done),
        ])
        let layout = scene.layout
        let a = scene.agents[0], b = scene.agents[1], c = scene.agents[2], d = scene.agents[3], e = scene.agents[4]
        #expect(a.feet.y == layout.stationLine && b.feet.y == layout.stationLine)
        #expect(a.feet.x == OfficeLayout.terminalX - 5.5 && b.feet.x == OfficeLayout.terminalX + 5.5)
        #expect(a.facesUp && !a.sits)
        #expect(c.feet == OfficePoint(x: c.desk.x, y: c.desk.y + 33) && c.facesUp)
        #expect(d.feet == OfficePoint(x: OfficeLayout.youX, y: layout.corridor) && !d.facesUp)
        #expect(e.sits && !e.facesUp)
        #expect(scene.waiting == 1)
    }

    /// Walkways down both sides reach the desks; gaps between stations join the bottom row.
    @Test func routesUseWalkways() {
        let layout = OfficeLayout(sessions: 4)
        let desk = OfficePoint(x: 30, y: 49)
        let terminal = OfficePoint(x: OfficeLayout.terminalX, y: layout.stationLine)
        #expect(layout.route(from: desk, to: terminal) == [OfficePoint(x: 4, y: 49), OfficePoint(x: 4, y: layout.stationLine), terminal])
        let sofa = OfficePoint(x: OfficeLayout.sofaX, y: layout.stationTop + 22)
        let path = layout.route(from: terminal, to: sofa)
        #expect(path.count == 3 && path[0].y == terminal.y && path[1].y == sofa.y && path[0].x == path[1].x)
        let along = OfficePoint(x: 100, y: layout.stationLine)
        #expect(layout.route(from: terminal, to: along) == [along])
        // From the right half, the right walkway.
        let farDesk = OfficePoint(x: 220, y: 49)
        #expect(layout.route(from: farDesk, to: OfficePoint(x: 200, y: layout.corridor)).first == OfficePoint(x: OfficeLayout.width - 4, y: 49))
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

    /// More sessions than desks: the rest are counted, not drawn.
    @Test func overflowIsCounted() {
        let sessions = (0..<34).map { session("s\($0)", "Claude Code") }
        let scene = Office.place(sessions)
        #expect(scene.agents.count == 30 && scene.hidden == 4)
    }
}

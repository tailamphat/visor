import Testing
@testable import VisorCore

@Suite("Office worlds")
struct OfficeWorldTests {
    /// The setting round-trips through its saved name, and anything unknown is the studio.
    @Test func worldsAreSavedByName() {
        for world in OfficeWorld.allCases { #expect(OfficeWorld(saved: world.rawValue) == world) }
        #expect(OfficeWorld(saved: nil) == .studio)
        #expect(OfficeWorld(saved: "holodeck") == .studio)
    }

    /// A session is always the same character, whatever else is in the room.
    @Test func aSessionKeepsItsCharacter() {
        let first = OfficeCast.pick(id: "session-a", count: 10, taken: [])
        #expect(OfficeCast.pick(id: "session-a", count: 10, taken: []) == first)
        #expect((0..<10).contains(first))
    }

    /// Two sessions don't share a character while there are free ones.
    @Test func charactersDontRepeatWhileThereAreFreeOnes() {
        var taken: Set<Int> = []
        for i in 0..<10 { taken.insert(OfficeCast.pick(id: "s\(i)", count: 10, taken: taken)) }
        #expect(taken.count == 10)
        let full = OfficeCast.pick(id: "eleventh", count: 10, taken: taken)
        #expect((0..<10).contains(full), "with everyone cast, a repeat is fine")
        #expect(OfficeCast.pick(id: "x", count: 0, taken: []) == 0)
    }

    /// In a film world, whoever's on break stands around the game table instead
    /// of sitting in a row: left, right, then in front; everyone else stays put.
    @Test func breakGathersAroundTheTable() {
        func s(_ id: String, _ state: AgentState) -> AgentSession { AgentSession(id: id, agent: "Claude Code", cwd: "/Users/me/\(id)", state: state) }
        let scene = Office.place([s("a", .done), s("b", .done), s("c", .done), s("d", .working("Thinking"))])
        let gathered = scene.aroundTheTable()
        let t = scene.layout.stationTop, x = OfficeLayout.sofaX
        let resting = gathered.agents.filter { $0.spot == .sofa }
        #expect(resting.map(\.feet) == [OfficePoint(x: x - 15, y: t + 15), OfficePoint(x: x + 14, y: t + 15), OfficePoint(x: x, y: t + 24)])
        #expect(resting.allSatisfy { !$0.sits && !$0.facesUp && $0.access == $0.feet.y })
        #expect(gathered.agents.filter { $0.spot != .sofa } == scene.agents.filter { $0.spot != .sofa })
    }
}

import Foundation
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

@Suite("Agents list digest")
struct AgentsDigestTests {
    func s(_ id: String, _ agent: String = "Claude Code", _ state: AgentState = .working("Thinking"), ago: Double = 0) -> AgentSession {
        AgentSession(id: id, agent: agent, cwd: "/Users/me/\(id)", state: state, since: Date(timeIntervalSince1970: 1_000_000 - ago))
    }

    /// Up to the limit, everything shows as it does today.
    @Test func smallListsShowEverything() {
        let digest = AgentsDigest(sessions: (0..<8).map { s("s\($0)") }, limit: 8)
        #expect(!digest.capped && digest.top.count == 8 && digest.more == 0)
    }

    /// Past it: whoever needs you first, then the busy ones, then the most recent;
    /// the rest are counted per tool, and idle ones are folded per tool.
    @Test func bigListsShowWhatMattersFirst() {
        var list = (0..<20).map { s("work\($0)", $0 % 3 == 0 ? "Copilot CLI" : "Claude Code", ago: Double($0)) }
        list += (0..<10).map { s("idle\($0)", "Claude Code", .idle, ago: 100) }
        list.append(s("asks", "Claude Code", .needsApproval("Bash: git push"), ago: 500))
        let digest = AgentsDigest(sessions: list, limit: 8)
        #expect(digest.capped)
        #expect(digest.top.first?.id == "asks")
        #expect(digest.top.count == 8 && digest.top.dropFirst().allSatisfy { $0.isActive })
        #expect(digest.top.dropFirst().map(\.id) == (0..<7).map { "work\($0)" }, "the most recent busy ones")
        #expect(digest.more == 23)
        #expect(digest.byTool.map(\.agent) == ["Claude Code", "Copilot CLI"])
        #expect(digest.byTool.map(\.count) == [24, 7])
        #expect(digest.idle.map(\.agent) == ["Claude Code"] && digest.idle.map(\.count) == [10])
    }
}

@Suite("First-launch intro")
struct IntroGateTests {
    /// It plays once, ever: the first launch, or when forced for testing.
    @Test func playsOnceUnlessForced() {
        #expect(IntroGate.shouldPlay(seen: false, environment: [:]))
        #expect(!IntroGate.shouldPlay(seen: true, environment: [:]))
        #expect(IntroGate.shouldPlay(seen: true, environment: ["VISOR_INTRO": "1"]))
        #expect(!IntroGate.shouldPlay(seen: false, environment: ["VISOR_INTRO": "0"]), "and can be turned off, e.g. for screenshots")
    }
}

import Foundation
import Testing
@testable import VisorCore

private let t0 = Date(timeIntervalSince1970: 2_000_000)

private func xray() -> HarnessXRay {
    HarnessXRay(total: 22_000, model: "claude-sonnet-4-5", prompt: 500, skills: 1_500,
                instructions: [XRayFile(path: "/Users/me/web-shop/CLAUDE.md", tokens: 3_000)],
                mcp: [XRayServer(name: "github", tokens: 5_000, tools: 4)], systemAndTools: 12_000)
}

/// The crafted scene: a running builder with everything, a failed perf with nothing but a task.
private func scene(agent: String = "Claude Code") -> AgentSession {
    var s = AgentSession(id: "s1", agent: agent, cwd: "/Users/me/web-shop", state: .working("Waiting on 2 helpers"), since: t0)
    s.turnStart = t0
    s.lastEvent = t0.addingTimeInterval(240)
    s.contextWindow = 200_000
    var b = AgentHelper(id: "b", type: "builder", task: "cart.ts promo codes")
    b.agentID = "ab"
    b.start = t0
    b.activity = "Edit: cart.ts"
    var st = HelperStats()
    st.dollars = 0.81
    st.tokens = 90_000
    st.model = "claude-sonnet-4-5-20250929"
    st.context = 92_000
    st.tools = ["Edit": 9, "Read": 14, "Bash": 4, "Grep": 2, "Glob": 1]
    st.toolCalls = 30
    st.agentType = "general-purpose"
    st.xray = xray()
    b.stats = st
    var f = AgentHelper(id: "f", type: "perf", task: "measure", done: true)
    f.agentID = "af"
    f.start = t0.addingTimeInterval(10)
    f.end = t0.addingTimeInterval(55)
    f.failed = true
    s.helpers = [b, f]
    return s
}

private func detail(_ s: AgentSession = scene(), _ id: String) throws -> HelperDetail {
    try #require(HelperDetail(session: s, rowID: id))
}

@Suite("HelperDetail")
struct HelperDetailTests {
    @Test func noneForMainOrUnknown() {
        #expect(HelperDetail(session: scene(), rowID: "main") == nil)
        #expect(HelperDetail(session: scene(), rowID: "nope") == nil)
        #expect(HelperDetail(session: scene(), rowID: "b") != nil)
    }

    @Test func claudeOnly() {
        for agent in ["Codex CLI", "OpenCode", "Gemini CLI", "Antigravity"] {
            #expect(HelperDetail(session: scene(agent: agent), rowID: "b") == nil)
        }
    }

    @Test func titleAndDuration() throws {
        let b = try #require(HelperDetail(session: scene(), rowID: "b"))
        #expect(b.title == "builder")
        #expect(b.pill == "general-purpose")
        #expect(!b.failed)
        #expect(b.duration == "4m")
        let f = try #require(HelperDetail(session: scene(), rowID: "f"))
        #expect(f.failed)
        #expect(f.duration == "45s")
        #expect(f.pill == nil)
    }

    @Test func nowOnlyRunning() throws {
        #expect(try detail(scene(), "b").now == "Edit: cart.ts")
        var s = scene()
        s.helpers[0].done = true
        #expect(try detail(s, "b").now == nil)
    }

    @Test func toolsLine() throws {
        let b = try #require(HelperDetail(session: scene(), rowID: "b"))
        #expect(b.tools == "Read 14 · Edit 9 · Bash 4 · 2 more")
        #expect(try detail(scene(), "f").tools == nil)
    }

    @Test func contextShare() throws {
        let b = try #require(HelperDetail(session: scene(), rowID: "b"))
        #expect(b.contextK == 92)
        #expect(abs(b.contextShare - 0.46) < 0.001)
        var s = scene()
        s.contextWindow = nil
        s.helpers[0].stats?.context = 400_000
        #expect(try detail(s, "b").contextShare == 1)
    }

    @Test func costAndModel() throws {
        #expect(try detail(scene(), "b").cost == "$0.81 · sonnet")
        var s = scene()
        s.helpers[0].stats?.unpriced = true
        #expect(try detail(s, "b").cost == "sonnet")
    }

    @Test func modelLabel() {
        #expect(HelperDetail.modelLabel("claude-sonnet-4-5-20250929") == "sonnet")
        #expect(HelperDetail.modelLabel("claude-opus-4-1") == "opus")
        #expect(HelperDetail.modelLabel("gpt-5") == "gpt-5")
        #expect(HelperDetail.modelLabel("claude-3-5-haiku-20241022") == "haiku")
        #expect(HelperDetail.modelLabel("claude-3-7-sonnet-20250219") == "sonnet")
    }

    @Test func startedParts() throws {
        let started = try #require(try detail(scene(), "b").started)
        #expect(started.total == "22k")  // exact, like the Harness line; only the split is about
        #expect(started.parts.map(\.kind) == [.systemAndTools, .mcp, .instructions, .skills, .prompt])
        #expect(abs(started.parts.reduce(0) { $0 + $1.share } - 1) < 0.0001)
        let rest = started.rows.filter { $0.kind != .total }
        #expect(!rest.isEmpty)
        #expect(rest.allSatisfy { $0.about })
        #expect(started.rows.first { $0.kind == .total }?.about == false)
    }

    @Test func linesForFixture() throws {
        let b = try #require(HelperDetail(session: scene(), rowID: "b"))
        #expect(b.lines == [.title, .task, .now, .tools, .context, .cost, .started])
        let f = try #require(HelperDetail(session: scene(), rowID: "f"))
        #expect(f.lines == [.title, .task])
    }

    @Test func heightCountsLines() throws {
        let b = try #require(HelperDetail(session: scene(), rowID: "b"))
        let f = try #require(HelperDetail(session: scene(), rowID: "f"))
        #expect(b.height == 2 * HelperDetail.padding + 7 * HelperDetail.lineHeight)
        #expect(f.height == 2 * HelperDetail.padding + 2 * HelperDetail.lineHeight)
    }

    @Test func heightWithDetail() throws {
        let b = try #require(HelperDetail(session: scene(), rowID: "b"))
        let w = HelperWaterfall.self
        #expect(w.height(rows: 3, detail: b) == w.height(rows: 3) + b.height + w.detailGap)
        #expect(w.height(rows: 3, detail: nil) == w.height(rows: 3))
    }
}

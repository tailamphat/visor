import Foundation
import Testing
@testable import VisorCore

private func reply(_ id: String, model: String = "claude-haiku-4-5", input: Int = 100, output: Int = 50,
                   cacheRead: Int = 0, cacheWrite: Int = 0, tool: String? = nil, toolID: String? = nil) -> String {
    let content = tool.map { #"[{"type":"tool_use","id":"\#(toolID ?? "t_" + id)","name":"\#($0)","input":{}}]"# } ?? "[]"
    return #"{"type":"assistant","isSidechain":true,"requestId":"req_\#(id)","timestamp":"2026-11-23T10:00:00Z","message":{"id":"msg_\#(id)","model":"\#(model)","content":\#(content),"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheWrite)}}}"#
}

@Suite("HelperStats")
struct HelperStatsTests {
    let dir: URL
    let main: String
    let subs: String
    let reader = SessionCostReader()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("visor-hs-\(UUID().uuidString)")
        subs = dir.path + "/s1/subagents"
        try FileManager.default.createDirectory(atPath: subs, withIntermediateDirectories: true)
        main = dir.path + "/s1.jsonl"
        try Data((reply("m") + "\n").utf8).write(to: URL(fileURLWithPath: main))
    }

    private func helper(_ id: String, _ lines: [String], meta: String? = nil) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: "\(subs)/agent-\(id).jsonl"))
        if let meta { try Data(meta.utf8).write(to: URL(fileURLWithPath: "\(subs)/agent-\(id).meta.json")) }
    }

    private func append(_ id: String, _ text: String) throws {
        let h = try #require(FileHandle(forWritingAtPath: "\(subs)/agent-\(id).jsonl"))
        defer { try? h.close() }
        try h.seekToEnd(); h.write(Data(text.utf8))
    }

    private func stats(_ id: String) -> HelperStats? {
        _ = reader.read(transcript: main, session: "s1")
        return reader.helperStats(session: "s1")[id]
    }

    @Test func costOncePerMessage() throws {
        try helper("a1", [reply("1"), reply("1"), reply("2")])
        let s = try #require(stats("a1"))
        #expect(s.tokens == 300)
        #expect(s.dollars > 0)
        #expect(!s.unpriced)
    }

    @Test func contextIsLastReply() throws {
        try helper("a1", [reply("1", input: 10, cacheRead: 1000, cacheWrite: 5), reply("2", model: "claude-sonnet-4-5", input: 20, cacheRead: 3000, cacheWrite: 7)])
        let s = try #require(stats("a1"))
        #expect(s.context == 3027)
        #expect(s.model == "claude-sonnet-4-5")
    }

    @Test func helperStatsCarryXRay() throws {
        try helper("a1", [reply("1", input: 10, cacheRead: 2000)])
        let s = try #require(stats("a1"))
        let xray = try #require(s.xray)
        #expect(xray.total == 2010)
        #expect(s.xray == reader.helperXRays(session: "s1")["a1"])
    }

    @Test func toolCountsOnceEach() throws {
        try helper("a1", [reply("1", tool: "Bash", toolID: "t1"), reply("1", tool: "Bash", toolID: "t1"),
                           reply("2", tool: "Bash"), reply("3", tool: "Read")])
        let s = try #require(stats("a1"))
        #expect(s.tools == ["Bash": 2, "Read": 1])
        #expect(s.toolCalls == 3)
    }

    @Test func capsNames() throws {
        var lines: [String] = []
        for i in 0..<30 { lines.append(reply("\(i)", tool: "Tool\(i)")) }
        lines.append(reply("long", tool: String(repeating: "x", count: 200)))
        try helper("a1", lines)
        let s = try #require(stats("a1"))
        #expect(s.tools.count <= HelperStats.maxTools)
        #expect(s.tools.keys.allSatisfy { $0.count <= HelperStats.maxName })
        #expect(s.toolCalls == 31)
    }

    @Test func metaLinksHelper() throws {
        try helper("a1", [reply("1")], meta: #"{"toolUseId":"toolu_9","parentAgentId":"p1","agentType":"Explore","model":"claude-haiku-4-5"}"#)
        let s = try #require(stats("a1"))
        #expect(s.toolUseID == "toolu_9")
        #expect(s.parentAgentID == "p1")
        #expect(s.agentType == "Explore")
    }

    @Test func metaWrittenLaterIsPickedUpThenNotReread() throws {
        try helper("a1", [reply("1")])
        #expect(stats("a1")?.toolUseID == nil)
        try Data(#"{"toolUseId":"toolu_1"}"#.utf8).write(to: URL(fileURLWithPath: "\(subs)/agent-a1.meta.json"))
        _ = try append("a1", reply("2") + "\n")
        #expect(stats("a1")?.toolUseID == "toolu_1")
        try Data(#"{"toolUseId":"toolu_2"}"#.utf8).write(to: URL(fileURLWithPath: "\(subs)/agent-a1.meta.json"))
        _ = try append("a1", reply("3") + "\n")
        #expect(stats("a1")?.toolUseID == "toolu_1")
    }

    @Test func capsMetaStrings() throws {
        let long = String(repeating: "y", count: 500)
        try helper("a1", [reply("1")], meta: #"{"toolUseId":"\#(long)","agentType":"\#(long)"}"#)
        let s = try #require(stats("a1"))
        #expect((s.toolUseID ?? "").count <= HelperStats.maxID)
        #expect((s.agentType ?? "").count <= HelperStats.maxName)
    }

    @Test func skipsSymlinks() throws {
        let real = dir.path + "/real.jsonl"
        try Data((reply("1") + "\n").utf8).write(to: URL(fileURLWithPath: real))
        try FileManager.default.createSymbolicLink(atPath: "\(subs)/agent-a1.jsonl", withDestinationPath: real)
        #expect(stats("a1") == nil)
    }

    @Test func skipsSymlinkedSubagentsFolder() throws {
        let elsewhere = dir.path + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try Data((reply("1") + "\n").utf8).write(to: URL(fileURLWithPath: elsewhere + "/agent-a1.jsonl"))
        try FileManager.default.removeItem(atPath: subs)
        try FileManager.default.createSymbolicLink(atPath: subs, withDestinationPath: elsewhere)
        #expect(stats("a1") == nil)
    }

    @Test func ignoresSyntheticReplies() throws {
        try helper("a1", [reply("1", input: 10, cacheRead: 990),
                          reply("2", model: "<synthetic>", input: 0, output: 0)])
        let s = try #require(stats("a1"))
        #expect(s.model == "claude-haiku-4-5")
        #expect(s.context == 1000)
        #expect(!s.unpriced)
    }

    @Test func longIdsKeepUpTo128() throws {
        let long = String(repeating: "z", count: 100)
        try helper("a1", [reply("1")], meta: #"{"toolUseId":"\#(long)"}"#)
        #expect(stats("a1")?.toolUseID == long)
    }

    @Test func finishedMetaIsReadOnce() throws {
        try helper("a1", [reply("1")], meta: #"{"finished":true}"#)
        #expect(stats("a1")?.metaDone == true)
    }

    @Test func incrementalAndRewrite() throws {
        try helper("a1", [reply("1")])
        #expect(stats("a1")?.tokens == 150)
        try append("a1", reply("2") + "\n")
        #expect(stats("a1")?.tokens == 300)
        try helper("a1", [reply("9", input: 1, output: 1)])
        #expect(stats("a1")?.tokens == 2)
        reader.forget(keeping: [])
        #expect(reader.helperStats(session: "s1").isEmpty)
    }

    @Test func realFixtureStats() throws {
        let fx = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-nested-helpers")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("visor-hsr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fx.appendingPathComponent("main.jsonl"), to: tmp.appendingPathComponent("s.jsonl"))
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("s"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fx.appendingPathComponent("subagents"), to: tmp.appendingPathComponent("s/subagents"))
        let r = SessionCostReader()
        _ = r.read(transcript: tmp.appendingPathComponent("s.jsonl").path, session: "s")
        let all = r.helperStats(session: "s")
        #expect(all.count == 3)
        let nested = try #require(all["a0df93125a344e958"])
        #expect(nested.toolUseID == "toolu_01UozCToGog5vyzYbCunNxz9")
        #expect(nested.parentAgentID == "aa4eb4f3833ee7f21")
        #expect(nested.tools["Bash"] == 1)
        #expect(nested.context > 0)
    }
}

@Suite("AgentBoardHelpers")
struct AgentBoardHelperStatsTests {
    private func call(_ id: String) -> HookMessage {
        hook("PreToolUse", #"{"session_id":"s1","cwd":"/Users/me/api","tool_name":"Agent","tool_use_id":"\#(id)","tool_input":{"description":"d","subagent_type":"Explore"}}"#)
    }
    private func start(_ id: String) -> HookMessage {
        hook("SubagentStart", #"{"session_id":"s1","cwd":"/Users/me/api","agent_id":"\#(id)","agent_type":"Explore"}"#)
    }

    @Test func statsLinkAndStore() {
        var board = AgentBoard()
        board.apply(call("t1"))
        board.apply(call("t2"))
        board.apply(start("a2"))
        board.apply(start("a1"))
        var st = HelperStats(); st.toolUseID = "t2"; st.tokens = 5
        board.setHelperStats(["a2": st], session: "s1")
        #expect(board.sessions[0].helpers.map(\.agentID) == ["a1", "a2"])
        #expect(board.sessions[0].helpers[1].stats?.tokens == 5)
        #expect(board.sessions[0].helpers[0].stats == nil)
        let before = board
        board.setHelperStats(["a2": st], session: "s1")
        #expect(board == before)
    }

    @Test func statsOnlyShowInDisplayedForm() {
        var board = AgentBoard()
        board.apply(call("t1"))
        board.apply(start("a1"))
        var st = HelperStats(); st.toolUseID = "t1"; st.context = 10_100; st.tokens = 10
        board.setHelperStats(["a1": st], session: "s1")
        var next = board
        st.context = 10_900; st.tokens = 20   // same 10k, no label
        next.setHelperStats(["a1": st], session: "s1")
        #expect(next != board && !next.differsVisibly(from: board))
        st.context = 12_000
        next.setHelperStats(["a1": st], session: "s1")
        #expect(next.differsVisibly(from: board))
    }

    @Test func pillAndStartedShowOnTheirOwn() {
        var board = AgentBoard()
        board.apply(call("t1"))
        board.apply(start("a1"))
        var st = HelperStats(); st.toolUseID = "t1"
        board.setHelperStats(["a1": st], session: "s1")
        var typed = board
        st.agentType = "general-purpose"
        typed.setHelperStats(["a1": st], session: "s1")
        #expect(typed.differsVisibly(from: board))
        var started = typed
        st.xray = HarnessXRay(total: 22_000, model: "claude-sonnet-4-5", prompt: 0, skills: 0, instructions: [], mcp: [], systemAndTools: 22_000)
        started.setHelperStats(["a1": st], session: "s1")
        #expect(started.differsVisibly(from: typed))
    }

    @Test func statsForAHelperThatIsGoneAreDropped() {
        var board = AgentBoard()
        board.apply(call("t1"))
        board.apply(start("a1"))
        var st = HelperStats(); st.tokens = 1
        board.setHelperStats(["a1": st, "gone": st], session: "s1")
        board.setHelperStats(["a1": st], session: "nope")
        #expect(board.sessions[0].helpers.count == 1)
    }
}

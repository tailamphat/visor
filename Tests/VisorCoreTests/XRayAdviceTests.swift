import Foundation
import Testing
@testable import VisorCore

/// Transcript lines for an earlier session: tools listed before the first reply, then calls.
private enum Past {
    static func tools(_ names: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "attachment", "attachment": [
            "type": "deferred_tools_delta", "addedNames": names, "addedLines": names, "removedNames": [String]()]])
        return String(decoding: data, as: UTF8.self)
    }

    static func surfaced(_ name: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "attachment", "attachment": [
            "type": "deferred_tools_delta", "addedNames": [String](), "addedLines": [String](), "removedNames": [String](),
            "surfacedDefinitions": [["name": name, "description": "Reads a file"]]]])
        return String(decoding: data, as: UTF8.self)
    }

    static let reply = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-5","usage":{"input_tokens":2,"cache_creation_input_tokens":20000,"cache_read_input_tokens":0,"output_tokens":5}}}"#

    static func call(_ name: String, id: String = "2") -> String {
        #"{"type":"assistant","message":{"id":"m\#(id)","model":"claude-opus-4-5","content":[{"type":"tool_use","id":"toolu_\#(id)","name":"\#(name)","input":{}}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}"#
    }

    static func prompt(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }

    /// A session that lists figma and github tools; `calls` are tool names it called.
    static func session(listing: [String] = ["mcp__figma__get_file", "mcp__github__search"], calls: [String] = []) -> [String] {
        [tools(listing), prompt("hi"), reply] + calls.enumerated().map { call($0.element, id: "\($0.offset + 2)") }
    }
}

private func xray(_ servers: [(String, Int)], total: Int = 41_000) -> HarnessXRay {
    let mcp = servers.map { XRayServer(name: $0.0, tokens: $0.1, tools: 3) }
    return HarnessXRay(total: total, model: "claude-opus-4-5", prompt: 200, skills: 3_000,
                       instructions: [XRayFile(path: "/Users/me/web-shop/CLAUDE.md", tokens: 6_000)],
                       mcp: mcp, systemAndTools: total - 9_200 - mcp.reduce(0) { $0 + $1.tokens })
}

private func past(_ servers: [String: Int], called: Set<String> = []) -> PastSession {
    PastSession(servers: servers, called: called)
}

@Suite("XRay advice")
struct XRayAdviceTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("visor-advice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Writes a transcript `name`.jsonl, `age` seconds old.
    @discardableResult
    private func write(_ name: String, _ lines: [String], age: TimeInterval = 0) throws -> String {
        let path = dir.appendingPathComponent(name + ".jsonl").path
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
        return path
    }

    private let current = xray([("figma", 12_000), ("github", 4_000)])
    private let listed = ["figma": 12_000, "github": 4_000]

    @Test func flagsServerUncalledInMostRecentSessions() throws {
        let sessions = (0..<5).map { _ in past(listed, called: ["github"]) }
        let advice = try #require(MCPAdvice.make(current: current, project: "web-shop", past: sessions))
        #expect(advice.server == "figma" && advice.tokens == 12_000)
        #expect(advice.notCalled == 5 && advice.sessions == 5)
        #expect(advice.title == "figma MCP · about 12k tokens a session")
        #expect(advice.detail == "Not called in 5 of the last 5 web-shop sessions.")
    }

    @Test func needsThreeEarlierSessions() {
        #expect(MCPAdvice.make(current: current, project: "web-shop", past: [past(listed), past(listed)]) == nil)
        #expect(MCPAdvice.make(current: current, project: "web-shop", past: [past(listed), past(listed), past(listed)]) != nil)
    }

    @Test func calledTooOftenGetsNone() {
        let twice = [past(listed, called: ["figma"]), past(listed, called: ["figma"]), past(listed), past(listed), past(listed)]
        #expect(MCPAdvice.make(current: current, project: "web-shop", past: twice)?.server != "figma")
        let once = [past(listed, called: ["figma"]), past(listed), past(listed), past(listed), past(listed)]
        let advice = MCPAdvice.make(current: current, project: "web-shop", past: once)
        #expect(advice?.server == "figma" && advice?.notCalled == 4 && advice?.sessions == 5)
    }

    @Test func sessionsWithoutTheServerDontCount() {
        let sessions = [past(listed), past(listed), past(["github": 4_000]), past(["github": 4_000]), past(["github": 4_000])]
        #expect(MCPAdvice.make(current: xray([("figma", 12_000)]), project: "web-shop", past: sessions) == nil)
    }

    @Test func smallServerGetsNone() {
        let sessions = (0..<5).map { _ in past(["figma": 900]) }
        #expect(MCPAdvice.make(current: xray([("figma", 900)]), project: "web-shop", past: sessions) == nil)
    }

    @Test func picksTheBiggest() {
        let both = ["figma": 12_000, "slack": 3_000]
        let sessions = (0..<5).map { _ in past(both) }
        #expect(MCPAdvice.make(current: xray([("slack", 3_000), ("figma", 12_000)]), project: "web-shop", past: sessions)?.server == "figma")
    }

    @Test func displayNameMatchesToolId() throws {
        let path = try write("a", Past.session(listing: ["mcp__claude_ai_Figma__get"], calls: ["mcp__claude_ai_Figma__get"]))
        let session = try #require(PastSessionScan.read(path))
        #expect(session.called.contains(XRayScanner.key("claude.ai Figma")))
        #expect(session.servers[XRayScanner.key("claude.ai Figma")] != nil)
    }

    @Test func callsInHelpersCount() throws {
        let path = try write("a", Past.session())
        let helpers = dir.appendingPathComponent("a/subagents")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try Data((Past.call("mcp__figma__get_file") + "\n").utf8).write(to: helpers.appendingPathComponent("agent-x.jsonl"))
        let session = try #require(PastSessionScan.read(path))
        #expect(session.called == ["figma"])
    }

    @Test func textMentionIsNotACall() throws {
        let path = try write("a", Past.session() + [Past.prompt("why is mcp__figma__get_file slow? \\\"name\\\":\\\"mcp__figma__x\\\""),
                                                   Past.surfaced("mcp__figma__get_file")])
        let session = try #require(PastSessionScan.read(path))
        #expect(session.called.isEmpty)
        #expect(session.servers.keys.sorted() == ["figma", "github"])
    }

    @Test func onlyLastFiveCount() throws {
        for index in 0..<5 { try write("new\(index)", Past.session(), age: Double(index) * 10) }
        try write("old0", Past.session(calls: ["mcp__figma__get_file"]), age: 1000)
        try write("old1", Past.session(calls: ["mcp__figma__get_file"]), age: 1100)
        let sessions = ProjectHistory().earlier(in: dir.path, excluding: dir.appendingPathComponent("cur.jsonl").path)
        #expect(sessions.count == 5)
        #expect(sessions.allSatisfy { $0.called.isEmpty })
    }

    @Test func excludesTheCurrentSession() throws {
        for index in 0..<3 { try write("p\(index)", Past.session(), age: 100 + Double(index)) }
        let cur = try write("cur", Past.session(calls: ["mcp__figma__get_file"]))
        let history = ProjectHistory()
        let sessions = history.earlier(in: dir.path, excluding: cur)
        #expect(sessions.count == 3 && sessions.allSatisfy { $0.called.isEmpty })
        #expect(history.reads == 3)
    }

    @Test func unchangedFileIsNotReadAgain() throws {
        for index in 0..<3 { try write("p\(index)", Past.session(), age: 100 + Double(index)) }
        let history = ProjectHistory()
        let cur = dir.appendingPathComponent("cur.jsonl").path
        _ = history.earlier(in: dir.path, excluding: cur)
        #expect(history.reads == 3)
        _ = history.earlier(in: dir.path, excluding: cur)
        #expect(history.reads == 3)
        try write("p1", Past.session(calls: ["mcp__figma__get_file"]), age: 50)
        let sessions = history.earlier(in: dir.path, excluding: cur)
        #expect(history.reads == 4)
        #expect(sessions.filter { $0.called.contains("figma") }.count == 1)
    }

    @Test func keepsNoText() throws {
        let path = try write("a", Past.session() + [Past.prompt("secret plan for octocat")])
        let session = try #require(PastSessionScan.read(path))
        let encoded = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        #expect(!encoded.contains("secret") && !encoded.contains("get_file"))
    }

    @Test func liveSessionsDontCount() throws {
        for index in 0..<3 { try write("p\(index)", Past.session(calls: ["mcp__figma__get_file"]), age: 100 + Double(index)) }
        let live = try ["l0", "l1"].map { try write($0, Past.session(), age: 10) }
        let cur = dir.appendingPathComponent("cur.jsonl").path
        let history = ProjectHistory()
        let sessions = history.earlier(in: dir.path, excluding: cur, live: Set(live))
        #expect(sessions.count == 3 && sessions.allSatisfy { $0.called == ["figma"] })
        #expect(history.reads == 3)
    }

    @Test func laterSessionsDontCount() throws {
        for index in 0..<3 { try write("p\(index)", Past.session(), age: 100 + Double(index)) }
        let cur = try write("cur", Past.session(), age: 50)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-50)], ofItemAtPath: cur)
        try write("later", Past.session(calls: ["mcp__figma__get_file"]), age: 0)
        let sessions = ProjectHistory().earlier(in: dir.path, excluding: cur)
        #expect(sessions.count == 3 && sessions.allSatisfy { $0.called.isEmpty })
    }

    @Test func linksAndPipesAreSkipped() throws {
        for index in 0..<3 { try write("p\(index)", Past.session(), age: 100 + Double(index)) }
        let target = try write("p0", Past.session(), age: 100)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link.jsonl").path, withDestinationPath: target)
        #expect(mkfifo(dir.appendingPathComponent("pipe.jsonl").path, 0o600) == 0)
        let history = ProjectHistory()
        let sessions = history.earlier(in: dir.path, excluding: dir.appendingPathComponent("cur.jsonl").path)
        #expect(sessions.count == 3 && history.reads == 3)

        let helpers = dir.appendingPathComponent("p1/subagents")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let called = try write("calls", [Past.call("mcp__figma__get_file")], age: 500)
        try FileManager.default.createSymbolicLink(atPath: helpers.appendingPathComponent("agent-x.jsonl").path, withDestinationPath: called)
        #expect(mkfifo(helpers.appendingPathComponent("agent-y.jsonl").path, 0o600) == 0)
        #expect(PastSessionScan.read(dir.appendingPathComponent("p1.jsonl").path)?.called.isEmpty == true)
        #expect(PastSessionScan.read(dir.appendingPathComponent("link.jsonl").path) == nil)
    }

    @Test func onlyFoldersInsideTheProjectsRoot() {
        let roots = ["/Users/me/.claude/projects"]
        #expect(ProjectHistory.isProjectFolder("/Users/me/.claude/projects/-Users-me-web-shop", roots: roots))
        #expect(!ProjectHistory.isProjectFolder("/Users/me/.claude/projects", roots: roots))
        #expect(!ProjectHistory.isProjectFolder("/tmp/web-shop", roots: roots))
        #expect(!ProjectHistory.isProjectFolder("/Users/me/.claude/projects/../../evil", roots: roots))
        #expect(!ProjectHistory.isProjectFolder("/Users/me/.claude/projects/a/b", roots: roots))
    }

    @Test func answeredByItsOwnCall() {
        let advice = MCPAdvice(server: "claude.ai Figma", tokens: 12_000, notCalled: 5, sessions: 5, project: "web-shop")
        #expect(advice.isAnswered(byTool: "mcp__claude_ai_Figma__get_file"))
        #expect(!advice.isAnswered(byTool: "mcp__github__search"))
        #expect(!advice.isAnswered(byTool: "Bash"))
    }

    @Test func unreadableFileIsNil() {
        #expect(PastSessionScan.read(dir.appendingPathComponent("missing.jsonl").path) == nil)
    }
}

@Suite("XRay UI")
struct XRayUITests {
    private func session(_ id: String, project: String, agent: String = "Claude Code", xray: HarnessXRay?) -> AgentSession {
        var session = AgentSession(id: id, agent: agent, cwd: "/Users/me/\(project)", state: .idle)
        session.xray = xray
        return session
    }

    @Test func summaryNilWithoutXRay() {
        #expect(HarnessSummary.make(sessions: [session("a", project: "web-shop", xray: nil)], advice: [:]) == nil)
        #expect(HarnessSummary.make(sessions: [], advice: [:]) == nil)
    }

    @Test func onlyClaudeSessions() throws {
        let summary = try #require(HarnessSummary.make(sessions: [
            session("a", project: "web-shop", xray: xray([("figma", 12_000)])),
            session("b", project: "docs", agent: "Copilot CLI", xray: xray([]))], advice: [:]))
        #expect(summary.rows.map(\.project) == ["web-shop"])
    }

    @Test func rowsShareOneScale() throws {
        let summary = try #require(HarnessSummary.make(sessions: [
            session("b", project: "api", xray: xray([], total: 23_000)),
            session("a", project: "web-shop", xray: xray([("figma", 12_000)], total: 41_000))], advice: [:]))
        #expect(summary.rows.map(\.project) == ["web-shop", "api"])
        #expect(summary.rows[0].scale == 1)
        #expect(abs(summary.rows[1].scale - 23.0 / 41.0) < 0.001)
        #expect(summary.detail == "23k-41k before your first word")
    }

    @Test func partsInFixedOrder() throws {
        let summary = try #require(HarnessSummary.make(sessions: [session("a", project: "web-shop", xray: xray([("figma", 12_000), ("github", 4_000)]))], advice: [:]))
        let row = summary.rows[0]
        #expect(row.parts.map(\.kind) == [.systemAndTools, .mcp, .instructions, .skills, .prompt])
        #expect(row.parts[1].tokens == 16_000)
        #expect(row.total == 41_000)
        #expect(summary.detail == "41k before your first word")

        var none = xray([])
        none.skills = 0
        let bare = try #require(HarnessSummary.make(sessions: [session("a", project: "x", xray: none)], advice: [:]))
        #expect(!bare.rows[0].parts.contains { $0.kind == .mcp || $0.kind == .skills })
    }

    @Test func sharesFillTheBarEvenWhenEstimatesRunOver() throws {
        var over = xray([("figma", 30_000)], total: 20_000)
        over.systemAndTools = 0
        let summary = try #require(HarnessSummary.make(sessions: [session("a", project: "web-shop", xray: over)], advice: [:]))
        let shares = summary.rows[0].parts.map(\.share)
        #expect(abs(shares.reduce(0, +) - 1) < 0.0001)
        #expect(shares.allSatisfy { $0 > 0 })
    }

    @Test func helpListsEveryServerAndFile() throws {
        let summary = try #require(HarnessSummary.make(sessions: [session("a", project: "web-shop", xray: xray([("figma", 12_000), ("github", 4_000)]))], advice: [:]))
        let help = summary.rows[0].help
        #expect(help.contains("41,000 tokens at the first reply (exact)"))
        #expect(help.contains("about 12,000 figma") && help.contains("about 4,000 github"))
        #expect(help.contains("web-shop/CLAUDE.md"))
        #expect(help.contains("about 3,000 skills"))
    }

    @Test func adviceAndLineDetail() throws {
        let advice = MCPAdvice(server: "figma", tokens: 12_000, notCalled: 5, sessions: 5, project: "web-shop")
        let summary = try #require(HarnessSummary.make(sessions: [session("a", project: "web-shop", xray: xray([("figma", 12_000)]))],
                                                       advice: ["a": advice, "gone": MCPAdvice(server: "slack", tokens: 20_000, notCalled: 3, sessions: 3, project: "old")]))
        #expect(summary.advice == advice)
        #expect(summary.detail == "41k before your first word · figma unused")
    }

    @Test func listHeightCountsRowsAdviceAndMore() throws {
        let sessions = (0..<6).map { session("s\($0)", project: "p\($0)", xray: xray([], total: 20_000 + $0)) }
        let summary = try #require(HarnessSummary.make(sessions: sessions, advice: [:]))
        #expect(summary.rows.count == HarnessSummary.maxRows && summary.more == 2)
        let base = 12 + HarnessSummary.headerHeight + 4 * HarnessSummary.rowHeight + HarnessSummary.moreHeight + HarnessSummary.keyHeight
        #expect(summary.listHeight == base)
        let advice = MCPAdvice(server: "figma", tokens: 12_000, notCalled: 5, sessions: 5, project: "p0")
        let withAdvice = try #require(HarnessSummary.make(sessions: sessions, advice: ["s0": advice]))
        #expect(withAdvice.listHeight == base + HarnessSummary.adviceGap + HarnessSummary.adviceHeight)
    }

    @Test func boardKeepsTheFirstXRay() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", #"{"session_id":"s1","cwd":"/Users/me/web-shop"}"#))
        board.setXRay(xray([("figma", 12_000)]), session: "s1")
        board.setXRay(xray([], total: 99_000), session: "s1")
        #expect(board.sessions[0].xray?.total == 41_000)
    }

    @Test func differsVisiblyOnceOnXRay() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", #"{"session_id":"s1","cwd":"/Users/me/web-shop"}"#))
        var next = board
        next.setXRay(xray([("figma", 12_000)]), session: "s1")
        #expect(next.differsVisibly(from: board))
        var same = next
        same.setXRay(xray([], total: 1), session: "s1")
        #expect(!same.differsVisibly(from: next))
    }

    @Test func oldSessionsFileLoads() throws {
        let board: AgentBoard = {
            var board = AgentBoard()
            board.apply(hook("SessionStart", #"{"session_id":"s1","cwd":"/Users/me/web-shop"}"#))
            return board
        }()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(board.sessions[0])) as? [String: Any])
        object["xray"] = nil
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.xray == nil && decoded.id == "s1")
    }
}

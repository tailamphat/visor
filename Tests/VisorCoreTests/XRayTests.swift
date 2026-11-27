import Foundation
import Testing
@testable import VisorCore

/// Transcript lines as Claude Code writes them before and at the first reply.
private enum Line {
    static func reply(input: Int = 2, write: Int = 25303, read: Int = 29688, model: String = "claude-opus-4-5", id: String = "1") -> String {
        #"{"type":"assistant","requestId":"req_\#(id)","timestamp":"2026-11-23T10:00:00Z","message":{"id":"msg_\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read),"output_tokens":10}}}"#
    }

    static func prompt(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }

    static let meta = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>xxxxxxxxxxxxxxxx</local-command-caveat>"}}"#

    static func attachment(_ body: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "attachment", "attachment": body])
        return String(decoding: data, as: UTF8.self)
    }

    static func tools(_ names: [String], removed: [String] = [], surfaced: [[String: Any]] = []) -> String {
        attachment(["type": "deferred_tools_delta", "addedNames": names, "addedLines": names,
                    "removedNames": removed, "surfacedDefinitions": surfaced])
    }

    static func skills(_ content: String) -> String {
        attachment(["type": "skill_listing", "content": content, "skillCount": 2, "isInitial": true])
    }

    static func instructions(_ files: [(String, String)]) -> String {
        attachment(["type": "instructions", "files": files.map { ["path": $0.0, "type": "Project", "content": $0.1] }])
    }

    static func blocks(_ names: [String], _ texts: [String]) -> String {
        attachment(["type": "mcp_instructions_delta", "addedNames": names, "addedBlocks": texts, "removedNames": []])
    }
}

private func scan(_ lines: [String]) -> XRayScanner {
    var scanner = XRayScanner()
    scanner.ingest(Data(lines.map { $0 + "\n" }.joined().utf8))
    return scanner
}

private func about(_ text: String) -> Int { (text.utf8.count + 3) / 4 }

@Suite("XRay")
struct XRayTests {
    let dir: URL
    let path: String

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("visor-xray-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("s1.jsonl").path
    }

    private func write(_ lines: [String], to file: String? = nil) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: file ?? path))
    }

    private func append(_ text: String, to file: String? = nil) throws {
        let handle = try #require(FileHandle(forWritingAtPath: file ?? path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(Data(text.utf8))
    }

    @Test func totalIsFirstReplyInputPlusCacheTokens() throws {
        let xray = try #require(scan([Line.prompt("hi"), Line.reply()]).result)
        #expect(xray.total == 2 + 25303 + 29688)
        #expect(xray.model == "claude-opus-4-5")
    }

    @Test func totalReadsTheCacheWriteSplitWhenOnlyItIsGiven() throws {
        let line = #"{"type":"assistant","message":{"model":"claude-opus-4-5","usage":{"input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":20},"cache_read_input_tokens":7}}}"#
        #expect(scan([line]).result?.total == 132)
    }

    @Test func syntheticEmptyReplyIsSkipped() {
        let scanner = scan([Line.reply(input: 0, write: 0, read: 0, model: "<synthetic>")])
        #expect(!scanner.isDone)
    }

    @Test func laterRepliesDoNotChangeIt() throws {
        let first = try #require(scan([Line.skills("abcd"), Line.reply()]).result)
        let more = try #require(scan([Line.skills("abcd"), Line.reply(), Line.skills(String(repeating: "x", count: 400)),
                                      Line.reply(input: 999, write: 99999, read: 999999, id: "2")]).result)
        #expect(more == first)
    }

    @Test func mcpSplitPerServer() throws {
        let definition: [String: Any] = ["name": "mcp__github__a",
                                         "definition": ["name": "mcp__github__a", "description": String(repeating: "d", count: 400)]]
        let block = String(repeating: "i", count: 800)
        let xray = try #require(scan([
            Line.tools(["Read", "mcp__github__a", "mcp__github__b", "mcp__chrome__c"], surfaced: [definition]),
            Line.blocks(["github"], [block]),
            Line.reply(),
        ]).result)
        try #require(xray.mcp.map(\.name) == ["github", "chrome"])
        #expect(xray.mcp.map(\.tools) == [2, 1])
        let schema = try JSONSerialization.data(withJSONObject: definition["definition"]!).count
        let github = "mcp__github__a".utf8.count + schema + "mcp__github__b".utf8.count + block.utf8.count
        #expect(xray.mcp[0].tokens == (github + 3) / 4)
        #expect(xray.mcp[1].tokens == about("mcp__chrome__c"))
    }

    @Test func instructionBlocksMatchToolServersLoosely() throws {
        let xray = try #require(scan([
            Line.tools(["mcp__claude_ai_Docs__read"]),
            Line.blocks(["claude.ai Docs"], ["some text"]),
            Line.reply(),
        ]).result)
        try #require(xray.mcp.count == 1)
        #expect(xray.mcp[0].tools == 1)
    }

    @Test func removedToolsLeaveTheServer() throws {
        let xray = try #require(scan([
            Line.tools(["mcp__github__a", "mcp__chrome__c"]),
            Line.tools([], removed: ["mcp__chrome__c"]),
            Line.reply(),
        ]).result)
        #expect(xray.mcp.map(\.name) == ["github"])
    }

    @Test func skillsFromSkillListing() throws {
        let content = String(repeating: "s", count: 1001)
        #expect(scan([Line.skills(content), Line.reply()]).result?.skills == about(content))
    }

    @Test func instructionFilesKeepPathAndTokensOnly() throws {
        let secret = "octocat-private-note " + String(repeating: "m", count: 300)
        let xray = try #require(scan([
            Line.instructions([("/Users/me/proj/CLAUDE.md", "# Rules\nbe kind"),
                               ("/Users/me/.claude/projects/proj/memory/MEMORY.md", secret)]),
            Line.reply(),
        ]).result)
        #expect(xray.instructions == [XRayFile(path: "/Users/me/proj/CLAUDE.md", tokens: about("# Rules\nbe kind")),
                                      XRayFile(path: "/Users/me/.claude/projects/proj/memory/MEMORY.md", tokens: about(secret))])
        let encoded = String(decoding: try JSONEncoder().encode(xray), as: UTF8.self)
        #expect(!encoded.contains("octocat-private-note"))
        #expect(!encoded.contains("be kind"))
    }

    @Test func remainderIsSystemAndTools() throws {
        let xray = try #require(scan([
            Line.meta,
            Line.tools(["mcp__github__a"]),
            Line.skills(String(repeating: "s", count: 400)),
            Line.instructions([("/Users/me/proj/CLAUDE.md", String(repeating: "c", count: 800))]),
            Line.prompt("fix the build please"),
            Line.reply(),
        ]).result)
        #expect(xray.prompt == about("fix the build please"))
        #expect(xray.systemAndTools == xray.total - xray.mcpTokens - xray.skills - xray.instructionTokens - xray.prompt)
        #expect(xray.systemAndTools > 0)
    }

    @Test func partsNeverExceedTotal() throws {
        let xray = try #require(scan([
            Line.skills(String(repeating: "s", count: 4000)),
            Line.instructions([("/Users/me/proj/CLAUDE.md", String(repeating: "c", count: 2000))]),
            Line.reply(input: 100, write: 0, read: 0),
        ]).result)
        #expect(xray.skills + xray.instructionTokens + xray.systemAndTools == 100)
        #expect(xray.systemAndTools < 3)
        #expect(xray.skills > xray.instructionTokens)
    }

    @Test func rowsMarkPartsAbout() throws {
        let xray = try #require(scan([Line.skills("abcdefgh"), Line.reply()]).result)
        let rows = xray.rows
        #expect(rows.first?.kind == .total && rows.first?.about == false)
        #expect(rows.dropFirst().allSatisfy { $0.about })
        #expect(rows.map(\.kind) == [.total, .systemAndTools, .skills])
    }

    @Test func noReplyYetIsNil() {
        let scanner = scan([Line.skills("abc"), Line.prompt("hi")])
        #expect(scanner.result == nil && !scanner.isDone)
    }

    @Test func instructionBlockNameWinsOverToolId() throws {
        let xray = try #require(scan([
            Line.tools(["mcp__claude_ai_Claude_Docs__read"]),
            Line.blocks(["claude.ai Claude Docs"], ["some text"]),
            Line.reply(),
        ]).result)
        #expect(xray.mcp.map(\.name) == ["claude.ai Claude Docs"])
    }

    /// The shape Claude Code 2.1.332 writes when the project has a CLAUDE.md
    /// and auto memory (checked against real transcripts, anonymised here).
    @Test func realInstructionsShape() throws {
        let line = #"{"parentUuid":"x","isSidechain":false,"type":"attachment","attachment":{"type":"instructions","files":[{"path":"/Users/me/proj/CLAUDE.md","type":"Project","content":"Notes\nrules here"},{"path":"/Users/me/.claude/projects/-Users-me-proj/memory/MEMORY.md","type":"AutoMem","content":"- octocat likes tabs"}]},"cwd":"/Users/me/proj"}"#
        let xray = try #require(scan([line, Line.reply()]).result)
        #expect(xray.instructions.map(\.path) == ["/Users/me/proj/CLAUDE.md", "/Users/me/.claude/projects/-Users-me-proj/memory/MEMORY.md"])
        #expect(xray.instructionTokens == about("Notes\nrules here") + about("- octocat likes tabs"))
    }

    @Test func givesUpAfterRepliesWithoutUsage() {
        let synthetic = Line.reply(input: 0, write: 0, read: 0, model: "<synthetic>")
        var scanner = scan([Line.prompt("hi"), synthetic, Line.prompt("again"), synthetic, Line.prompt("once more"), synthetic])
        #expect(scanner.isDone && scanner.result == nil)
        let parsed = scanner.linesParsed
        scanner.ingest(Data((Array(repeating: Line.prompt("tool output"), count: 100) + [Line.reply()]).map { $0 + "\n" }.joined().utf8))
        #expect(scanner.linesParsed == parsed && scanner.result == nil)
    }

    @Test func oneSyntheticReplyStillWaitsForTheRealOne() {
        let synthetic = Line.reply(input: 0, write: 0, read: 0, model: "<synthetic>")
        #expect(scan([Line.prompt("hi"), synthetic, Line.prompt("hi"), Line.reply()]).result?.total == 2 + 25303 + 29688)
    }

    // MARK: Through the session reader

    /// The real run from item I1 (`Fixtures/claude-nested-helpers`), written
    /// compactly as Claude Code does (the fixture is pretty-spaced for reading).
    @Test func realFixtureMainAndHelpers() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-nested-helpers")
        func compact(_ source: URL, to target: String) throws {
            let lines = try String(contentsOf: source, encoding: .utf8).split(separator: "\n").map { line -> String in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            }
            try write(lines, to: target)
        }
        try compact(fixture.appendingPathComponent("main.jsonl"), to: path)
        let subagents = dir.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let helpers = try FileManager.default.contentsOfDirectory(atPath: fixture.appendingPathComponent("subagents").path)
            .filter { $0.hasSuffix(".jsonl") }
        for name in helpers {
            try compact(fixture.appendingPathComponent("subagents/" + name), to: subagents.appendingPathComponent(name).path)
        }
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        let xray = try #require(reader.xray(session: "s1"))
        #expect(xray.total == 2 + 14813 + 11837)
        #expect(xray.mcpTokens > 0 && xray.skills > 0)
        #expect(xray.mcp.map(\.name) == ["claude.ai Claude Docs"])
        let byAgent = reader.helperXRays(session: "s1")
        #expect(Set(byAgent.keys) == ["a0df93125a344e958", "aa4eb4f3833ee7f21", "ad387ef141e3adaed"])
        #expect(byAgent.values.allSatisfy { $0.total > 0 })
    }

    @Test func readsAcrossAppendsAndHalfLines() throws {
        let lines = [Line.tools(["mcp__github__a"]), Line.skills("abcdefgh"), Line.prompt("hi"), Line.reply()]
        let whole = lines.map { $0 + "\n" }.joined()
        let cut = whole.index(whole.startIndex, offsetBy: whole.count - 40)
        try Data(whole[..<cut].utf8).write(to: URL(fileURLWithPath: path))
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        #expect(reader.xray(session: "s1") == nil)
        try append(String(whole[cut...]))
        _ = reader.read(transcript: path, session: "s1")
        #expect(reader.xray(session: "s1") == scan(lines).result)
        #expect(reader.xray(session: "s1") != nil)
    }

    @Test func stopsParsingOnceDone() throws {
        try write([Line.skills("abc"), Line.reply()])
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        let before = try #require(reader.xrayLinesParsed(of: path, session: "s1"))
        try append(Array(repeating: Line.skills("more") + "\n", count: 1000).joined() + Line.reply(id: "2") + "\n")
        let cost = reader.read(transcript: path, session: "s1")
        #expect(reader.xrayLinesParsed(of: path, session: "s1") == before)
        #expect(cost?.tokens == 2 * (2 + 25303 + 10))
    }

    @Test func helperTranscriptGetsItsOwnXRay() throws {
        try write([Line.prompt("hi"), Line.reply()])
        let subagents = dir.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try write([Line.prompt("look into it"), Line.reply(input: 3, write: 5000, read: 0, id: "h")],
                  to: subagents.appendingPathComponent("agent-abc.jsonl").path)
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        #expect(reader.xray(session: "s1")?.total == 2 + 25303 + 29688)
        let helpers = reader.helperXRays(session: "s1")
        #expect(Array(helpers.keys) == ["abc"])
        #expect(helpers["abc"]?.total == 5003)
    }

    @Test func rewriteStartsOver() throws {
        try write([Line.reply(input: 1, write: 9999, read: 9999)])
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        try write([Line.reply(input: 1, write: 1, read: 1)])
        _ = reader.read(transcript: path, session: "s1")
        #expect(reader.xray(session: "s1")?.total == 3)
    }

    @Test func forgetDropsXRay() throws {
        try write([Line.reply()])
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        #expect(reader.xray(session: "s1") != nil)
        reader.forget(keeping: [])
        #expect(reader.xray(session: "s1") == nil)
        #expect(reader.helperXRays(session: "s1").isEmpty)
    }

    /// `VISOR_REAL=1 scripts/test.sh --filter realXRay` checks this Mac's newest transcripts.
    /// Prints counts only, never paths or text.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VISOR_REAL"] != nil))
    func realXRay() throws {
        let root = NSHomeDirectory() + "/.claude/projects"
        var files: [(String, Date)] = []
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root + "/" + folder)) ?? [] where name.hasSuffix(".jsonl") {
                let file = root + "/" + folder + "/" + name
                let date = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? .distantPast
                files.append((file, date))
            }
        }
        var found = 0
        for (index, (file, _)) in files.sorted(by: { $0.1 > $1.1 }).prefix(5).enumerated() {
            let reader = SessionCostReader()
            let start = Date()
            _ = reader.read(transcript: file, session: "s")
            let elapsed = Date().timeIntervalSince(start)
            guard let xray = reader.xray(session: "s") else { print("realXRay \(index): no reply yet"); continue }
            found += 1
            let parts = xray.mcpTokens + xray.skills + xray.instructionTokens + xray.prompt + xray.systemAndTools
            #expect(parts == xray.total)
            print("realXRay \(index): total \(xray.total) system+tools \(xray.systemAndTools) mcp \(xray.mcpTokens) (\(xray.mcp.count) servers, \(xray.mcp.map(\.tools).reduce(0, +)) tools) instructions \(xray.instructionTokens) (\(xray.instructions.count) files) skills \(xray.skills) prompt \(xray.prompt) helpers \(reader.helperXRays(session: "s").count) read \(String(format: "%.2f", elapsed)) s")
        }
        #expect(found > 0)
    }
}

import Foundation
import Testing
@testable import VisorCore

/// One assistant response line as Claude Code writes it.
private func response(_ id: String, model: String = "claude-opus-4-5", input: Int = 1000, output: Int = 500) -> String {
    #"{"type":"assistant","requestId":"req_\#(id)","timestamp":"2026-11-23T10:00:00Z","message":{"id":"msg_\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
}

/// What one default response costs on opus-4-5 ($5 in, $25 out per million).
private let one = (1000.0 * 5 + 500.0 * 25) / 1_000_000

@Suite("Session cost")
struct SessionCostTests {
    let dir: URL
    let path: String

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("visor-cost-\(UUID().uuidString)")
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

    private func close(_ a: Double?, _ b: Double) -> Bool { abs((a ?? -1) - b) < 1e-9 }

    @Test func sumsPricedResponses() throws {
        try write([response("1"), #"{"type":"user","message":{"content":"hi"}}"#, response("2")])
        let reader = SessionCostReader()
        let cost = reader.read(transcript: path, session: "s1")
        #expect(close(cost?.dollars, 2 * one))
        #expect(cost?.tokens == 3000 && cost?.unpriced == false)
    }

    @Test func readsOnlyNewBytes() throws {
        try write([response("1")])
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        try append(response("2") + "\n")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).intValue
        let cost = reader.read(transcript: path, session: "s1")
        #expect(close(cost?.dollars, 2 * one))
        #expect(reader.lastBytesRead == response("2").utf8.count + 1)
        #expect(reader.offset(of: path, session: "s1") == UInt64(size))
        let again = reader.read(transcript: path, session: "s1")
        #expect(again == cost && reader.lastBytesRead == 0)
    }

    @Test func halfWrittenLineWaits() throws {
        try write([response("1")])
        let line = response("2")
        try append(String(line.prefix(40)))
        let reader = SessionCostReader()
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, one))
        try append(String(line.dropFirst(40)) + "\n")
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, 2 * one))
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, 2 * one))
    }

    @Test func countsEachResponseOnce() throws {
        try write([response("1"), response("1"), response("1")])
        #expect(close(SessionCostReader().read(transcript: path, session: "s1")?.dollars, one))
    }

    @Test func includesSubagentTranscripts() throws {
        try write([response("1")])
        let sub = dir.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let agent = sub.appendingPathComponent("agent-a.jsonl").path
        try write([response("a1")], to: agent)
        let reader = SessionCostReader()
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, 2 * one))
        try append(response("a2") + "\n", to: agent)
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, 3 * one))
    }

    @Test func unpricedModelShowsTokens() throws {
        try write([response("1", model: "gpt-5", input: 40_000, output: 8_000)])
        let cost = try #require(SessionCostReader().read(transcript: path, session: "s1"))
        #expect(cost.dollars == 0 && cost.unpriced && cost.tokens == 48_000)
        #expect(cost.label == "48k tok")
    }

    @Test func labelFormats() {
        #expect(SessionCost(dollars: 0.004, tokens: 10).label == nil)
        #expect(SessionCost(dollars: 0.86, tokens: 10).label == "$0.86")
        #expect(SessionCost(dollars: 4.123, tokens: 10).label == "$4.12")
        #expect(SessionCost(dollars: 123.4, tokens: 10).label == "$123")
        #expect(SessionCost(dollars: 0, tokens: 1_200_000, unpriced: true).label == "1.2M tok")
        #expect(SessionCost(dollars: 0, tokens: 0, unpriced: true).label == nil)
    }

    @Test func shrunkFileStartsOver() throws {
        try write([response("1"), response("2"), response("3")])
        let reader = SessionCostReader()
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, 3 * one))
        try write([response("9")])
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, one))
    }

    @Test func newPathStartsOver() throws {
        try write([response("1"), response("2")])
        let other = dir.appendingPathComponent("s2.jsonl").path
        try write([response("1")], to: other)
        let reader = SessionCostReader()
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, 2 * one))
        #expect(close(reader.read(transcript: other, session: "s1")?.dollars, one))
    }

    @Test func forgetDropsTally() throws {
        try write([response("1")])
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        reader.forget(keeping: [])
        #expect(reader.offset(of: path, session: "s1") == nil)
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, one))
    }

    @Test func shrunkSubagentFileStartsSessionOver() throws {
        try write([response("1")])
        let sub = dir.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let agent = sub.appendingPathComponent("agent-a.jsonl").path
        try write([response("a1"), response("a2")], to: agent)
        let reader = SessionCostReader()
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, 3 * one))
        try write([response("a9")], to: agent)
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, 2 * one), "main once plus the rewritten helper")
    }

    @Test func subagentFileAddedLaterIsCounted() throws {
        try write([response("1")])
        let reader = SessionCostReader()
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, one))
        let sub = dir.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write([response("b1")], to: sub.appendingPathComponent("agent-b.jsonl").path)
        #expect(close(reader.read(transcript: path, session: "s1")?.dollars, 2 * one))
        #expect(reader.lastBytesRead == response("b1").utf8.count + 1, "only the new helper's bytes")
    }

    /// `VISOR_REAL=1 scripts/test.sh --filter realSessionCost` times the first and a repeat read of this Mac's largest transcript.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VISOR_REAL"] != nil))
    func realSessionCost() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var largest: (path: String, size: Int) = ("", 0)
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])!
        where url.pathExtension == "jsonl" && !url.path.contains("/subagents/") {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > largest.size { largest = (url.path, size) }
        }
        let reader = SessionCostReader()
        let start = Date()
        let cost = reader.read(transcript: largest.path, session: "real")
        let first = Date().timeIntervalSince(start)
        let again = Date()
        _ = reader.read(transcript: largest.path, session: "real")
        print(String(format: "largest transcript %.1f MB, cost %@, first read %.3fs, repeat %.4fs",
                     Double(largest.size) / 1e6, cost?.label ?? "-", first, Date().timeIntervalSince(again)))
        #expect(first < 2)
    }

    @Test func missingTranscriptGivesNothing() {
        #expect(SessionCostReader().read(transcript: dir.appendingPathComponent("none.jsonl").path, session: "s1") == nil)
    }

    // C1 I3b: the cache clock's turn comes from transcript order, never from comparing clocks.
    private func prompt(_ text: String, at stamp: String, extra: String = "") -> String {
        #"{"type":"user",\#(extra)"timestamp":"\#(stamp)","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func reply(_ id: String, at stamp: String) -> String {
        #"{"type":"assistant","requestId":"req_\#(id)","timestamp":"\#(stamp)","message":{"id":"msg_\#(id)","model":"claude-opus-4-5","usage":{"input_tokens":10,"output_tokens":5}}}"#
    }

    @Test func lastTurnFollowsTranscriptOrder() throws {
        try write([prompt("one", at: "2026-11-23T10:00:00.000Z"), reply("a", at: "2026-11-23T10:00:02.000Z"),
                   prompt("two", at: "2026-11-23T10:00:05.000Z")])
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        let before = try #require(reader.lastTurn(session: "s1"))
        #expect(!before.replyAfterPrompt && before.promptIndex == 2)
        #expect(before.promptAt == ISODate.parse("2026-11-23T10:00:05.000Z"))
        // A reply stamped 0.9 s before the prompt but written after it belongs to it.
        try append(reply("b", at: "2026-11-23T10:00:04.100Z") + "\n")
        _ = reader.read(transcript: path, session: "s1")
        let after = try #require(reader.lastTurn(session: "s1"))
        #expect(after.replyAfterPrompt && after.promptIndex == 2)
        // In one read the same.
        let fresh = SessionCostReader()
        _ = fresh.read(transcript: path, session: "s1")
        #expect(fresh.lastTurn(session: "s1") == after)
    }

    @Test func promptEntrySkipsToolResultsMetaAndHelpers() throws {
        try write([prompt("one", at: "2026-11-23T10:00:00.000Z"), reply("a", at: "2026-11-23T10:00:02.000Z"),
                   #"{"type":"user","timestamp":"2026-11-23T10:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
                   prompt("Caveat", at: "2026-11-23T10:00:04.000Z", extra: #""isMeta":true,"#),
                   prompt("side", at: "2026-11-23T10:00:04.000Z", extra: #""isSidechain":true,"#),
                   prompt("<command-name>/context</command-name>", at: "2026-11-23T10:00:05.000Z"),
                   prompt("<local-command-stdout>Context 40k</local-command-stdout>", at: "2026-11-23T10:00:05.000Z"),
                   prompt("This session is being continued", at: "2026-11-23T10:00:06.000Z", extra: #""isCompactSummary":true,"#),
                   #"{"type":"user","timestamp":"2026-11-23T10:00:07.000Z","message":{"role":"user","content":[{"type":"image","source":{}}]}}"#])
        let sub = dir.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write([prompt("helper task", at: "2026-11-23T10:00:08.000Z")], to: sub.appendingPathComponent("agent-a.jsonl").path)
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        let turn = try #require(reader.lastTurn(session: "s1"))
        #expect(turn.replyAfterPrompt && turn.promptIndex == 1)
        #expect(turn.promptAt == ISODate.parse("2026-11-23T10:00:00.000Z"))
    }

    // I3 QA case 12: /context, /cost, a compact summary, a tool result, meta and sidechain lines after
    // a finished turn leave its line (the reply still follows the real prompt).
    @Test func qaCase12SlashCommandsKeepTheLine() throws {
        try write([prompt("fix it", at: "2026-11-23T10:00:00.000Z"), reply("a", at: "2026-11-23T10:00:02.000Z")])
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        let before = try #require(reader.lastTurn(session: "s1"))
        try append([prompt("<command-name>/context</command-name>", at: "2026-11-23T10:01:00.000Z"),
                    prompt("<local-command-stdout>Context 40k</local-command-stdout>", at: "2026-11-23T10:01:00.000Z"),
                    prompt("<command-name>/cost</command-name>\\n<command-message>cost</command-message>", at: "2026-11-23T10:01:05.000Z"),
                    prompt("  <local-command-caveat>Caveat</local-command-caveat>", at: "2026-11-23T10:01:05.000Z"),
                    prompt("Summary", at: "2026-11-23T10:02:00.000Z", extra: #""isCompactSummary":true,"#),
                    #"{"type":"user","timestamp":"2026-11-23T10:02:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"x"}]}}"#,
                    prompt("meta", at: "2026-11-23T10:02:02.000Z", extra: #""isMeta":true,"#),
                    prompt("side", at: "2026-11-23T10:02:03.000Z", extra: #""isSidechain":true,"#)].joined(separator: "\n") + "\n")
        _ = reader.read(transcript: path, session: "s1")
        #expect(reader.lastTurn(session: "s1") == before)
        #expect(before.replyAfterPrompt)
    }

    // I3 QA cases 10 and 11: a reply from before the prompt (minutes, or 0.5 s for a queued prompt) is not this turn's.
    @Test func qaCases10And11ReplyBeforePromptIsNotThisTurns() throws {
        for (replyAt, promptAt) in [("2026-11-23T09:55:00.000Z", "2026-11-23T10:00:00.000Z"),
                                    ("2026-11-23T10:00:00.000Z", "2026-11-23T10:00:00.500Z")] {
            try write([prompt("one", at: "2026-11-23T09:50:00.000Z"), reply("a", at: replyAt), prompt("two", at: promptAt)])
            let reader = SessionCostReader()
            _ = reader.read(transcript: path, session: "s1")
            let turn = try #require(reader.lastTurn(session: "s1"))
            #expect(!turn.replyAfterPrompt && turn.promptIndex == 2, "reply at \(replyAt)")
        }
    }

    @Test func noPromptEntryNoTurn() throws {
        try write([reply("a", at: "2026-11-23T10:00:02.000Z")])
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        #expect(reader.lastTurn(session: "s1") == nil)
    }
}

@Suite("Session cost last reply")
struct SessionCostLastReplyTests {
    private func line(_ id: String, at time: String, write1h: Int = 0, read: Int = 0) -> String {
        #"{"type":"assistant","requestId":"req_\#(id)","timestamp":"\#(time)","message":{"id":"msg_\#(id)","model":"claude-opus-4-5","usage":{"input_tokens":7,"output_tokens":1,"cache_read_input_tokens":\#(read),"cache_creation":{"ephemeral_5m_input_tokens":3,"ephemeral_1h_input_tokens":\#(write1h)}}}}"#
    }

    @Test func keepsLastMainReply() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("visor-last-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("s1.jsonl").path
        try Data((line("1", at: "2026-11-23T10:00:00Z") + "\n" + line("2", at: "2026-11-23T10:01:00Z", write1h: 9, read: 500) + "\n").utf8).write(to: URL(fileURLWithPath: path))
        // A helper replies later than the main transcript: it must not count.
        try Data((line("h", at: "2026-11-23T10:05:00Z", read: 99) + "\n").utf8)
            .write(to: dir.appendingPathComponent("s1/subagents/agent-a.jsonl"))
        let reader = SessionCostReader()
        #expect(reader.lastReply(session: "s1") == nil)
        _ = reader.read(transcript: path, session: "s1")
        let last = try #require(reader.lastReply(session: "s1"))
        #expect(last.input == 7 && last.cacheRead == 500 && last.cacheWrite5m == 3 && last.cacheWrite1h == 9)
        #expect(last.model == "claude-opus-4-5")
        #expect(last.timestamp == ISODate.parse("2026-11-23T10:01:00Z"))
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        handle.write(Data((line("3", at: "2026-11-23T10:02:00Z", read: 700) + "\n").utf8))
        try handle.close()
        _ = reader.read(transcript: path, session: "s1")
        #expect(reader.lastReply(session: "s1")?.cacheRead == 700)
    }

    @Test func syntheticReplyIsNotTheLastReply() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("visor-synth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("s1.jsonl").path
        // An API error or interrupt: Claude Code writes a "<synthetic>" reply with no usage.
        let synthetic = line("x", at: "2026-11-23T10:03:00Z").replacingOccurrences(of: "claude-opus-4-5", with: "<synthetic>")
        try Data((line("1", at: "2026-11-23T10:01:00Z", read: 500) + "\n" + synthetic + "\n").utf8).write(to: URL(fileURLWithPath: path))
        let reader = SessionCostReader()
        _ = reader.read(transcript: path, session: "s1")
        #expect(reader.lastReply(session: "s1")?.model == "claude-opus-4-5")
        #expect(reader.lastReply(session: "s1")?.cacheRead == 500)
    }
}

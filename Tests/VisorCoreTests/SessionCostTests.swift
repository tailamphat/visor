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
}

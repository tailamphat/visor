import Foundation
import Testing
@testable import VisorCore

@Suite("Token sources")
struct TokenSourcesTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // MARK: Codex CLI

    /// Codex writes running totals; each event counts what changed since the last one.
    /// Cached input is part of input; reasoning is part of output.
    @Test func codexCountsTheChangeInRunningTotals() {
        let lines = [
            #"{"timestamp":"2026-11-01T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-11-01T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":50,"reasoning_output_tokens":20},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":50}}}}"#,
            #"{"timestamp":"2026-11-01T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            #"{"timestamp":"2026-11-02T09:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":2500,"output_tokens":80},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":1900,"output_tokens":30}}}}"#,
        ].joined(separator: "\n")
        let days = TokenLedger.daily(codex: Data(lines.utf8), calendar: calendar)
        #expect(days["2026-11-01"]?["Codex CLI|gpt-5-5"] == TokenCount(input: 400, output: 50, cacheRead: 600))
        #expect(days["2026-11-02"]?["Codex CLI|gpt-5-5"] == TokenCount(input: 100, output: 30, cacheRead: 1900))
    }

    /// A running total that drops is a new count: the last response counts on its own.
    /// One that dips a little is a stale snapshot and is skipped.
    @Test func codexHandlesResetsAndStaleSnapshots() {
        let lines = [
            #"{"timestamp":"2026-11-01T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"output_tokens":100}}}}"#,
            #"{"timestamp":"2026-11-01T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9950,"output_tokens":100}}}}"#,
            #"{"timestamp":"2026-11-01T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"output_tokens":10},"last_token_usage":{"input_tokens":200,"output_tokens":10}}}}"#,
        ].joined(separator: "\n")
        let days = TokenLedger.daily(codex: Data(lines.utf8), calendar: calendar)
        #expect(days["2026-11-01"]?["Codex CLI|codex"] == TokenCount(input: 10200, output: 110), "no model seen: Codex itself")
    }

    // MARK: Gemini CLI

    /// A saved chat: messages with tokens and a model. When the total includes the
    /// cached tokens in input, they're taken out of input; thoughts count as output, tool use as input.
    @Test func geminiChatMessages() {
        let json = #"""
        {"sessionId":"s","messages":[
          {"id":"1","type":"user","timestamp":"2026-11-03T08:00:00Z"},
          {"id":"2","type":"gemini","timestamp":"2026-11-03T08:00:05Z","model":"gemini-3.5-pro",
           "tokens":{"input":1000,"output":100,"cached":400,"thoughts":50,"tool":10,"total":1160}},
          {"id":"3","type":"gemini","timestamp":"2026-11-03T08:01:00Z","model":"gemini-3.5-pro",
           "tokens":{"input":300,"output":20,"cached":200,"thoughts":0,"tool":0,"total":520}}
        ]}
        """#
        let days = TokenLedger.daily(gemini: Data(json.utf8), fallback: Date(), calendar: calendar)
        #expect(days["2026-11-03"]?["Gemini CLI|gemini-3-5-pro"] == TokenCount(input: 610 + 300, output: 170, cacheRead: 600))
    }

    /// Newer Gemini CLI writes one JSON object per line.
    @Test func geminiJSONLines() {
        let lines = [
            #"{"type":"user","timestamp":"2026-11-04T08:00:00Z"}"#,
            #"{"type":"gemini","timestamp":"2026-11-04T08:00:05Z","model":"gemini-3.8-flash","tokens":{"input":50,"output":5}}"#,
        ].joined(separator: "\n")
        let days = TokenLedger.daily(gemini: Data(lines.utf8), fallback: Date(), calendar: calendar)
        #expect(days["2026-11-04"]?["Gemini CLI|gemini-3-8-flash"] == TokenCount(input: 50, output: 5))
    }

    // MARK: Antigravity CLI

    /// One generation as agy stores it: field 1 holds the model name (#19) and
    /// usage (#4: #2 input, #3 output, #4 cache write, #5 cache read).
    static func generation(model: String, input: Int, output: Int, cacheWrite: Int = 0, cacheRead: Int = 0) -> Data {
        func varint(_ value: Int) -> [UInt8] {
            var v = UInt64(value), out: [UInt8] = []
            repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0
            return out
        }
        func field(_ number: Int, _ value: Int) -> [UInt8] { varint(number << 3) + varint(value) }
        func bytes(_ number: Int, _ data: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(data.count) + data }
        let usage = field(2, input) + field(3, output) + field(4, cacheWrite) + field(5, cacheRead)
        let chat = bytes(19, Array(model.utf8)) + bytes(4, usage) + bytes(9, field(2, 1))
        return Data(bytes(1, chat))
    }

    @Test func antigravityGenerations() {
        // trajectory_metadata_blob.data: #2 = {#1: seconds}
        let created = Data([0x12, 0x06, 0x08] + [0x80, 0xE6, 0xB5, 0xC6, 0x06])  // 1_768_000_000 + something
        let start = TokenLedger.antigravityCreated(created)
        #expect(start != nil)
        let gens = [Self.generation(model: "gemini-3.8-flash-n", input: 6917, output: 164),
                    Self.generation(model: "gemini-3.8-flash-n", input: 100, output: 10, cacheRead: 5000)]
        let day = TokenLedger.dayKey(start!, calendar: calendar)
        let days = TokenLedger.daily(antigravity: gens, created: start!, calendar: calendar)
        #expect(days[day]?["Antigravity|gemini-3-8-flash-n"] == TokenCount(input: 7017, output: 174, cacheRead: 5000))
        #expect(TokenLedger.daily(antigravity: [Data([0xFF])], created: start!, calendar: calendar).isEmpty, "garbage is skipped")
    }
}

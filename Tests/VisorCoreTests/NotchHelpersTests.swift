import Foundation
import Testing
@testable import VisorCore

@Suite("Approval keys")
struct ApprovalKeysTests {
    @Test func returnAllowsEscDeniesAAlways() {
        #expect(ApprovalKeys.decision(keyCode: 36, characters: "\r", modified: false, canAlways: true) == .allow)
        #expect(ApprovalKeys.decision(keyCode: 76, characters: "\u{3}", modified: false, canAlways: true) == .allow, "keypad Enter")
        #expect(ApprovalKeys.decision(keyCode: 53, characters: "\u{1b}", modified: false, canAlways: true) == .deny)
        #expect(ApprovalKeys.decision(keyCode: 0, characters: "a", modified: false, canAlways: true) == .allowAlways)
        #expect(ApprovalKeys.decision(keyCode: 0, characters: "A", modified: false, canAlways: true) == .allowAlways)
    }

    @Test func otherKeysAndShortcutsAreLeftAlone() {
        #expect(ApprovalKeys.decision(keyCode: 0, characters: "a", modified: false, canAlways: false) == nil, "no Always on this card")
        #expect(ApprovalKeys.decision(keyCode: 0, characters: "a", modified: true, canAlways: true) == nil, "⌘A")
        #expect(ApprovalKeys.decision(keyCode: 36, characters: "\r", modified: true, canAlways: true) == nil)
        #expect(ApprovalKeys.decision(keyCode: 1, characters: "s", modified: false, canAlways: true) == nil)
    }
}

@Suite("Context window")
struct ContextUsageTests {
    static func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    static func assistant(input: Int, cacheRead: Int, cacheWrite: Int, sidechain: Bool = false) -> String {
        line(["type": "assistant", "isSidechain": sidechain,
              "message": ["model": "claude-opus-5-5", "role": "assistant",
                          "usage": ["input_tokens": input, "cache_read_input_tokens": cacheRead,
                                    "cache_creation_input_tokens": cacheWrite, "output_tokens": 900]]])
    }

    static func tail(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    @Test func lastMainReplyCounts() {
        let data = Self.tail([
            Self.assistant(input: 10, cacheRead: 50_000, cacheWrite: 1_000),
            Self.line(["type": "user", "message": ["role": "user", "content": "go on"]]),
            Self.assistant(input: 4, cacheRead: 139_860, cacheWrite: 1_575),
            Self.assistant(input: 2, cacheRead: 5_000, cacheWrite: 0, sidechain: true),
            Self.line(["type": "system", "subtype": "turn_duration", "durationMs": 1200]),
        ])
        #expect(ContextUsage.tokens(inTail: data) == 141_439, "subagent replies have their own context")
    }

    @Test func aCutFirstLineIsSkipped() {
        let data = Data(("ut_tokens\":3}}}\n" + Self.assistant(input: 1, cacheRead: 999, cacheWrite: 0)).utf8)
        #expect(ContextUsage.tokens(inTail: data) == 1_000)
    }

    @Test func unknownRightAfterCompaction() {
        let data = Self.tail([
            Self.assistant(input: 4, cacheRead: 190_000, cacheWrite: 0),
            Self.line(["type": "system", "subtype": "compact_boundary", "compactMetadata": ["preTokens": 190_004]]),
        ])
        #expect(ContextUsage.tokens(inTail: data) == nil)
        #expect(ContextUsage.tokens(inTail: Data()) == nil)
    }

    @Test func compactBoundaryAfterReplyClears() {
        let data = Self.tail([
            Self.assistant(input: 4, cacheRead: 150_000, cacheWrite: 0),
            Self.line(["type": "user", "message": ["role": "user", "content": "next"]]),
            Self.line(["type": "system", "subtype": "compact_boundary", "compactMetadata": ["preTokens": 150_004]]),
            Self.line(["type": "user", "message": ["role": "user", "content": "go"]]),
        ])
        #expect(ContextUsage.reading(inTail: data).tokens == nil)
        #expect(ContextUsage.reading(inTail: data).provenWindow == nil, "under 200k proves nothing")
    }

    @Test func compactPreTokensProveLargeWindow() {
        let data = Self.tail([
            Self.line(["type": "system", "subtype": "compact_boundary", "compactMetadata": ["preTokens": 565_140]]),
            Self.assistant(input: 4, cacheRead: 50_000, cacheWrite: 0),
        ])
        let reading = ContextUsage.reading(inTail: data)
        #expect(reading.tokens == 50_004)
        var board = AgentBoard()
        board.apply(HookMessage(event: "SessionStart", pid: 1, payload: ["session_id": "s1", "cwd": "/x/app"]))
        board.setContext(tokens: reading.tokens, model: nil, provenWindow: reading.provenWindow, session: "s1")
        #expect(board.sessions[0].contextWindow == 1_000_000)
    }

    @Test func restoredSessionHasNoStaleContext() throws {
        var board = AgentBoard()
        board.apply(HookMessage(event: "SessionStart", pid: 1, payload: ["session_id": "s1", "cwd": "/x/app"]))
        board.setContext(tokens: 150_000, model: nil, session: "s1")
        let restored = AgentBoard.restored(from: try board.saved(), isAlive: { _ in true })
        #expect(restored.sessions.count == 1)
        #expect(restored.sessions[0].contextPercent == nil)
    }

    @Test func contextReadAfterSessionEndIgnored() {
        var board = AgentBoard()
        board.apply(HookMessage(event: "SessionStart", pid: 1, payload: ["session_id": "s1", "cwd": "/x/app"]))
        board.apply(HookMessage(event: "SessionEnd", pid: 1, payload: ["session_id": "s1"]))
        board.setContext(tokens: 100_000, model: nil, session: "s1")
        #expect(board.sessions.isEmpty)
    }

    @Test func clearStartsNewSessionWithoutContext() {
        var board = AgentBoard()
        board.apply(HookMessage(event: "SessionStart", pid: 1, payload: ["session_id": "s1", "cwd": "/x/app"]))
        board.setContext(tokens: 100_000, model: nil, session: "s1")
        board.apply(HookMessage(event: "SessionEnd", pid: 1, payload: ["session_id": "s1"]))
        board.apply(HookMessage(event: "SessionStart", pid: 1, payload: ["session_id": "s2", "cwd": "/x/app"]))
        #expect(board.sessions.count == 1)
        #expect(board.sessions[0].contextPercent == nil)
    }

    @Test func windowIs200kUnlessTheModelOrTheCountSaysMore() {
        #expect(ContextUsage.window(tokens: 150_000, model: nil) == 200_000)
        #expect(ContextUsage.window(tokens: 150_000, model: "opus[1m]") == 1_000_000)
        #expect(ContextUsage.window(tokens: 250_000, model: "opus") == 1_000_000)
    }

    @Test func sessionsKeepTheLargerWindowAndPublishVisibleChanges() {
        var board = AgentBoard()
        board.apply(HookMessage(event: "SessionStart", pid: 1, payload: ["session_id": "s1", "cwd": "/x/app"]))
        let before = board
        board.setContext(tokens: 300_000, model: nil, session: "s1")
        #expect(board.sessions[0].contextPercent == 30)
        #expect(board.differsVisibly(from: before))
        // Compacted down: still a 1M session.
        board.setContext(tokens: 50_000, model: nil, session: "s1")
        #expect(board.sessions[0].contextPercent == 5)
        let same = board
        board.setContext(tokens: 50_400, model: nil, session: "s1")
        #expect(!board.differsVisibly(from: same), "less than a percent is not worth redrawing")
    }
}

@Suite("Limit is back")
struct LimitWatchTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func claude(_ used: Double, resets: TimeInterval) -> LimitReading {
        LimitReading(key: "claude.five_hour", agent: "Claude Code", title: "Session (5h)", percentUsed: used,
                     resetsAt: start.addingTimeInterval(resets))
    }

    @Test func aUsedUpLimitThatResetsIsBack() {
        var watch = LimitWatch()
        #expect(watch.update([claude(80, resets: 3600)], now: start).isEmpty)
        #expect(watch.update([claude(100, resets: 3600)], now: start.addingTimeInterval(600)).isEmpty)
        let back = watch.update([claude(0, resets: 3600 + 5 * 3600)], now: start.addingTimeInterval(3605))
        #expect(back == [LimitReturn(agent: "Claude Code", title: "Session (5h)", percentLeft: 100,
                                     ranOutAt: start.addingTimeInterval(600),
                                     nextReset: start.addingTimeInterval(3600 + 5 * 3600))])
        #expect(watch.update([claude(2, resets: 3600 + 5 * 3600)], now: start.addingTimeInterval(3700)).isEmpty, "only once")
    }

    @Test func nearlyUsedUpCountsTooWithoutARanOutTime() {
        var watch = LimitWatch()
        _ = watch.update([claude(93, resets: 60)], now: start)
        let back = watch.update([claude(1, resets: 60 + 5 * 3600)], now: start.addingTimeInterval(120))
        #expect(back.first?.ranOutAt == nil && back.first?.percentLeft == 99)
    }

    @Test func ordinaryResetsAndFirstReadingsStaySilent() {
        var watch = LimitWatch()
        #expect(watch.update([claude(95, resets: 60)], now: start).isEmpty, "first reading after launch")
        var quiet = LimitWatch()
        _ = quiet.update([claude(60, resets: 60)], now: start)
        #expect(quiet.update([claude(0, resets: 60 + 5 * 3600)], now: start.addingTimeInterval(120)).isEmpty, "wasn't needed")
    }

    @Test func readingsFromClaudeAndOpenCode() {
        let plan = PlanUsage(limits: [PlanLimit(kind: "five_hour", percentUsed: 100, resetsAt: start, severity: "normal")])
        let go = OpenCodeGoUsage(limits: [OpenCodeGoLimit(id: "weekly", title: "Weekly", percentUsed: 40, resetsAt: nil)])
        let readings = LimitReading.all(plan: plan, openCode: go)
        #expect(readings.map(\.key) == ["claude.five_hour", "opencode.weekly"])
        #expect(readings.map(\.agent) == ["Claude Code", "OpenCode"])
        #expect(readings[0].title == "Session (5h)")
    }
}

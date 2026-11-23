import Foundation
import Testing
@testable import VisorCore

@Suite("Stuck detector")
struct StuckTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let error = "FAIL src/rate.test.ts > allows 10 per minute\n  expected 10, got 9"

    func message(_ event: String, _ tool: String = "Bash", _ input: [String: Any] = ["command": "npm test"],
                 session: String = "a", agentID: String? = nil, extra: [String: Any] = [:]) -> HookMessage {
        var payload: [String: Any] = ["session_id": session, "tool_name": tool, "tool_input": input]
        if let agentID { payload["agent_id"] = agentID }
        payload.merge(extra) { $1 }
        return HookMessage(event: event, pid: 1, payload: payload)
    }

    /// One call: its PreToolUse, then success or failure. Returns the peek, if any.
    @discardableResult
    func run(_ watch: inout StuckWatch, _ command: String = "npm test", failed: Bool = true, session: String = "a",
             agentID: String? = nil, at: Date? = nil) -> Stuck? {
        let now = at ?? t0
        _ = watch.record(message("PreToolUse", "Bash", ["command": command], session: session, agentID: agentID), agent: "Claude Code", at: now)
        let post = failed
            ? message("PostToolUseFailure", "Bash", ["command": command], session: session, agentID: agentID, extra: ["error": error])
            : message("PostToolUse", "Bash", ["command": command], session: session, agentID: agentID)
        return watch.record(post, agent: "Claude Code", at: now)
    }

    func read(_ watch: inout StuckWatch, _ tool: String = "Read") {
        _ = watch.record(message("PreToolUse", tool, ["file_path": "/Users/me/api/src/rate.ts"]), agent: "Claude Code", at: t0)
        _ = watch.record(message("PostToolUse", tool, ["file_path": "/Users/me/api/src/rate.ts"]), agent: "Claude Code", at: t0)
    }

    func edit(_ watch: inout StuckWatch, session: String = "a") {
        let input = ["file_path": "/Users/me/api/src/rate.ts", "old_string": "9", "new_string": "10"]
        _ = watch.record(message("PreToolUse", "Edit", input, session: session), agent: "Claude Code", at: t0)
        _ = watch.record(message("PostToolUse", "Edit", input, session: session), agent: "Claude Code", at: t0)
    }

    func stuckWatch() -> StuckWatch {
        var watch = StuckWatch()
        for _ in 0..<3 { run(&watch) }
        return watch
    }

    // MARK: When it shows

    @Test func threeFailuresInARow() throws {
        var watch = StuckWatch()
        #expect(run(&watch) == nil)
        #expect(run(&watch) == nil)
        let stuck = try #require(run(&watch))
        #expect(stuck.kind == .failing && stuck.count == 3)
        #expect(stuck.label == "npm test" && stuck.session == "a" && stuck.agent == "Claude Code")
        #expect(stuck.error == "FAIL src/rate.test.ts > allows 10 per minute")
        #expect(stuck.short == "failed 3x")
        #expect(watch.active(at: t0).count == 1)
    }

    @Test func readsDoNotBreakTheRow() {
        var watch = StuckWatch()
        run(&watch); read(&watch)
        run(&watch); read(&watch, "Grep")
        #expect(run(&watch)?.kind == .failing)
    }

    @Test func differentCallBreaksTheRow() {
        var watch = StuckWatch()
        run(&watch)
        run(&watch, "ls", failed: false)
        run(&watch)
        #expect(run(&watch) == nil)
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func sameCallFourTimesWithoutEdit() throws {
        var watch = StuckWatch()
        for _ in 0..<3 {
            #expect(run(&watch) == nil)
            run(&watch, "ls", failed: false)
        }
        let stuck = try #require(run(&watch))
        #expect(stuck.kind == .looping && stuck.count == 4 && stuck.short == "4x, no edits")
    }

    @Test func editResetsTheCount() {
        var watch = StuckWatch()
        for _ in 0..<3 { run(&watch); run(&watch, "ls", failed: false) }
        edit(&watch)
        #expect(run(&watch) == nil)
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func failingEditsCanBeStuck() {
        var watch = StuckWatch()
        let input = ["file_path": "/Users/me/api/src/rate.ts", "old_string": "x", "new_string": "y"]
        var last: Stuck?
        for _ in 0..<3 {
            _ = watch.record(message("PreToolUse", "Edit", input), agent: "Claude Code", at: t0)
            last = watch.record(message("PostToolUseFailure", "Edit", input, extra: ["error": "String to replace not found"]), agent: "Claude Code", at: t0)
        }
        #expect(last?.kind == .failing && last?.label == "Edit rate.ts")
    }

    @Test func successResetsTheCount() {
        var watch = StuckWatch()
        for _ in 0..<3 { run(&watch); run(&watch, "ls", failed: false) }
        run(&watch, failed: false)
        #expect(run(&watch) == nil)
    }

    @Test func peeksOncePerCall() {
        var watch = stuckWatch()
        #expect(run(&watch) == nil)
        #expect(run(&watch) == nil)
        #expect(watch.active(at: t0).first?.count == 5)
    }

    // MARK: Every way it ends

    @Test func clearsOnSuccess() {
        var watch = stuckWatch()
        run(&watch, failed: false)
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func clearsOnDifferentCall() {
        var watch = stuckWatch()
        read(&watch)
        #expect(watch.active(at: t0).count == 1, "a read is not moving on")
        _ = watch.record(message("PreToolUse", "Bash", ["command": "git diff"]), agent: "Claude Code", at: t0)
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func clearsOnEdit() {
        var watch = stuckWatch()
        _ = watch.record(message("PreToolUse", "Edit", ["file_path": "/Users/me/api/src/rate.ts"]), agent: "Claude Code", at: t0)
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func clearsOnNewPrompt() {
        for event in ["UserPromptSubmit", "SessionStart"] {
            var watch = stuckWatch()
            _ = watch.record(HookMessage(event: event, pid: 1, payload: ["session_id": "a"]), agent: "Claude Code", at: t0)
            #expect(watch.active(at: t0).isEmpty)
            #expect(run(&watch) == nil, "counts start over after \(event)")
        }
    }

    @Test func clearsOnStop() {
        var watch = stuckWatch()
        _ = watch.record(HookMessage(event: "Stop", pid: 1, payload: ["session_id": "a"]), agent: "Claude Code", at: t0)
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func clearsOnSessionEnd() {
        var watch = stuckWatch()
        _ = watch.record(HookMessage(event: "SessionEnd", pid: 1, payload: ["session_id": "a"]), agent: "Claude Code", at: t0)
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func clearsWhenAgentExits() {
        var watch = stuckWatch()
        for _ in 0..<3 { run(&watch, session: "b") }
        watch.forget(keeping: ["b"])
        #expect(watch.active(at: t0).map(\.session) == ["b"])
        watch.forget(keeping: [])
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func clearsSubagentOnSubagentStop() {
        var watch = StuckWatch()
        for _ in 0..<3 { run(&watch, agentID: "h1") }
        run(&watch, "git status", failed: false)
        #expect(watch.active(at: t0).count == 1, "the main agent's calls are its own")
        _ = watch.record(HookMessage(event: "SubagentStop", pid: 1, payload: ["session_id": "a", "agent_id": "h1"]), agent: "Claude Code", at: t0)
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func safetyTimeoutIsOnlyAFallback() {
        var watch = stuckWatch()
        #expect(watch.nextChange(after: t0) == t0 + 900)
        #expect(watch.active(at: t0 + 899).count == 1)
        #expect(watch.active(at: t0 + 901).isEmpty)
        run(&watch, at: t0 + 600)
        #expect(watch.nextChange(after: t0 + 600) == t0 + 1500)
        #expect(StuckWatch().nextChange(after: t0) == nil)
    }

    @Test func ignoreHoldsUntilProgress() throws {
        var watch = stuckWatch()
        let stuck = try #require(watch.active(at: t0).first)
        watch.ignore(stuck)
        #expect(watch.active(at: t0).isEmpty)
        #expect(run(&watch) == nil && run(&watch) == nil)
        #expect(watch.active(at: t0).isEmpty)
        edit(&watch)
        run(&watch); run(&watch)
        #expect(run(&watch) != nil)
    }

    // MARK: Other agents

    @Test func copilotFailures() {
        func line(_ event: String, _ extra: String = "") -> HookMessage {
            HookMessage.parse(Data(#"{"event":"\#(event)","provider":"copilot","pid":1,"raw":{"sessionId":"c","toolName":"bash","toolArgs":{"command":"npm test"}\#(extra)}}"#.utf8))!
        }
        var watch = StuckWatch()
        for _ in 0..<2 {
            _ = watch.record(line("preToolUse"), agent: "Copilot CLI", at: t0)
            _ = watch.record(line("postToolUseFailure"), agent: "Copilot CLI", at: t0)
        }
        _ = watch.record(line("preToolUse"), agent: "Copilot CLI", at: t0)
        let stuck = watch.record(line("postToolUse", #","toolResult":{"resultType":"failure","textResultForLlm":"exit 1"}"#), agent: "Copilot CLI", at: t0)
        #expect(stuck?.kind == .failing && stuck?.count == 3 && stuck?.error == "exit 1")
    }

    @Test func antigravityRepeats() {
        // No outcome from Antigravity: only back-to-back runs count, five of them.
        func line(_ event: String) -> HookMessage {
            HookMessage.parse(Data(#"{"event":"\#(event)","provider":"antigravity","pid":1,"raw":{"conversationId":"g","toolCall":{"name":"run_command","args":{"CommandLine":"npm test"}}}}"#.utf8))!
        }
        var watch = StuckWatch()
        var last: Stuck?
        for i in 0..<5 {
            _ = watch.record(line("PreToolUse"), agent: "Antigravity", at: t0)
            last = watch.record(line("PostToolUse"), agent: "Antigravity", at: t0)
            if i < 4 { #expect(last == nil) }
        }
        #expect(last?.kind == .looping && last?.short == "5x, no edits" && last?.label == "npm test")
    }

    // MARK: Cost and privacy

    @Test func stateStaysBounded() {
        var watch = StuckWatch()
        for i in 0..<1000 { run(&watch, "echo \(i)", failed: false) }
        for i in 0..<1000 {
            _ = watch.record(message("PreToolUse", "Bash", ["command": "echo \(i)"]), agent: "Claude Code", at: t0)
        }
        #expect(watch.repeatCount(actor: "a|") <= StuckWatch.maxCalls)
        _ = watch.record(HookMessage(event: "Stop", pid: 1, payload: ["session_id": "a"]), agent: "Claude Code", at: t0)
        #expect(watch.actorCount == 0)
    }

    @Test func errorIsOneShortLine() {
        #expect(StuckWatch.errorLine("\n\n   Exit code 1\nsecond line") == "Exit code 1")
        #expect(StuckWatch.errorLine(String(repeating: "x", count: 500))?.count == 120)
        #expect(StuckWatch.errorLine("  \n ") == nil)
        #expect(StuckWatch.label(tool: "Bash", input: ["command": String(repeating: "y", count: 200) + "\nmore"]).count <= 60)
    }

    // MARK: Gate findings

    @Test func subagentEditIsProgressForTheSession() {
        var watch = StuckWatch()
        let input = ["file_path": "/Users/me/api/src/rate.ts", "old_string": "9", "new_string": "10"]
        for _ in 0..<5 {
            run(&watch)
            _ = watch.record(message("PreToolUse", "Edit", input, agentID: "h1"), agent: "Claude Code", at: t0)
            _ = watch.record(message("PostToolUse", "Edit", input, agentID: "h1"), agent: "Claude Code", at: t0)
        }
        #expect(watch.active(at: t0).isEmpty)
    }

    @Test func callsWithoutAKnownFieldAreToldApart() {
        var watch = StuckWatch()
        for issue in 1...4 {
            let input: [String: Any] = ["owner": "octocat", "issue_number": issue]
            _ = watch.record(message("PreToolUse", "mcp__github__get_issue", input), agent: "Claude Code", at: t0)
            _ = watch.record(message("PostToolUseFailure", "mcp__github__get_issue", input), agent: "Claude Code", at: t0)
        }
        #expect(watch.active(at: t0).isEmpty)
        #expect(StuckWatch.key(tool: "Task", input: ["prompt": "a"]) != StuckWatch.key(tool: "Task", input: ["prompt": "b"]))
        #expect(StuckWatch.key(tool: "Task", input: ["a": 1, "b": 2]) == StuckWatch.key(tool: "Task", input: ["b": 2, "a": 1]))
    }

    @Test func antigravityNeedsBackToBackRuns() {
        func line(_ event: String, _ command: String) -> HookMessage {
            HookMessage.parse(Data(#"{"event":"\#(event)","provider":"antigravity","pid":1,"raw":{"conversationId":"g","toolCall":{"name":"run_command","args":{"CommandLine":"\#(command)"}}}}"#.utf8))!
        }
        var watch = StuckWatch()
        for _ in 0..<6 {
            for command in ["gh run view 123", "sleep 30"] {
                _ = watch.record(line("PreToolUse", command), agent: "Antigravity", at: t0)
                _ = watch.record(line("PostToolUse", command), agent: "Antigravity", at: t0)
            }
        }
        #expect(watch.active(at: t0).isEmpty, "polling with other calls between is not a loop")
    }

    @Test func successEndsIgnoreAndAllowsANewPeek() throws {
        var watch = stuckWatch()
        watch.ignore(try #require(watch.active(at: t0).first))
        run(&watch, failed: false)
        run(&watch); run(&watch)
        #expect(run(&watch) != nil)
    }

    @Test func compactKeepsTheCounts() {
        var watch = stuckWatch()
        _ = watch.record(HookMessage(event: "SessionStart", pid: 1, payload: ["session_id": "a", "source": "compact"]), agent: "Claude Code", at: t0)
        #expect(watch.active(at: t0).count == 1)
    }

    @Test func generationMovesOnlyWhenWarningsChange() throws {
        var watch = StuckWatch()
        let start = watch.generation
        run(&watch); run(&watch)
        #expect(watch.generation == start)
        run(&watch)
        let shown = watch.generation
        #expect(shown != start)
        read(&watch)
        #expect(watch.generation == shown)
        watch.ignore(try #require(watch.active(at: t0).first))
        #expect(watch.generation != shown)
    }
}

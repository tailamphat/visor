import Foundation
import Testing
@testable import VisorCore

@Suite("Helper badge and failure peek")
struct HelperNoticeTests {
    func base(_ session: String) -> String { #""session_id":"\#(session)","cwd":"/Users/me/web-shop""# }

    func call(_ id: String, type: String = "perf", task: String = "Check speed", session: String = "s1",
              provider: String = "claude", parent: String? = nil) -> HookMessage {
        let agent = parent.map { #","agent_id":"\#($0)""# } ?? ""
        return hook("PreToolUse", provider: provider,
                    #"{\#(base(session))\#(agent),"tool_name":"Agent","tool_use_id":"\#(id)","tool_input":{"description":"\#(task)","subagent_type":"\#(type)"}}"#)
    }
    func done(_ id: String, session: String = "s1") -> HookMessage {
        hook("PostToolUse", #"{\#(base(session)),"tool_name":"Agent","tool_use_id":"\#(id)","tool_input":{}}"#)
    }
    func fail(_ id: String, session: String = "s1", provider: String = "claude", interrupt: Bool = false) -> HookMessage {
        hook("PostToolUseFailure", provider: provider,
             #"{\#(base(session)),"tool_name":"Agent","tool_use_id":"\#(id)","tool_input":{},"is_interrupt":\#(interrupt)}"#)
    }

    /// Applies a message and returns what failed with it, as AppDelegate does.
    func step(_ board: inout AgentBoard, _ message: HookMessage) -> HelperFailure? {
        let before = board
        board.apply(message)
        return HelperFailure.mayFail(message) ? HelperFailure.new(before: before, after: board) : nil
    }

    func fanOut(_ count: Int, finished: Int = 0) -> AgentBoard {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", #"{\#(base("s1")),"prompt":"go"}"#))
        for i in 0..<count { board.apply(call("t\(i)")) }
        for i in 0..<finished { board.apply(done("t\(i)")) }
        return board
    }

    @Test func badgeCountsRunningHelpers() {
        var board = fanOut(6, finished: 4)
        #expect(HelperProgress.of(board, agent: "Claude Code").running == 2)
        #expect(HelperProgress.of(board, agent: "Claude Code").badge == "2")
        // A nested helper counts too.
        board.apply(hook("SubagentStart", #"{\#(base("s1")),"agent_id":"a5","agent_type":"perf"}"#))
        board.apply(call("n1", parent: "a5"))
        #expect(HelperProgress.of(board, agent: "Claude Code").running == 3)
        for i in 0..<6 { board.apply(done("t\(i)")) }
        board.apply(done("n1"))
        #expect(HelperProgress.of(board, agent: "Claude Code").badge == nil, "nothing running: no badge")
    }

    @Test func badgeCapsAtNine() {
        #expect(HelperProgress.of(fanOut(12), agent: "Claude Code").badge == "9+")
        #expect(HelperProgress.of(fanOut(9), agent: "Claude Code").badge == "9")
    }

    @Test func noBadgeForOtherAgents() {
        var board = AgentBoard()
        board.apply(hook("PreToolUse", provider: "copilot", #"{\#(base("c1")),"tool_name":"Task","tool_use_id":"t1","tool_input":{"description":"Find","subagent_type":"Explore"}}"#))
        #expect(board.sessions[0].runningHelpers == 1)
        let progress = HelperProgress.of(board, agent: board.sessions[0].agent)
        #expect(progress.badge == nil && progress.text == nil)
        #expect(NotchMarks.make(board, approvalsFrom: []).shown.first?.helpers == 0)
    }

    @Test func marksCarryTheCount() {
        #expect(NotchMarks.make(fanOut(3, finished: 1), approvalsFrom: []).shown.first?.helpers == 2)
    }

    @Test func progressText() {
        #expect(HelperProgress.of(fanOut(6, finished: 4), agent: "Claude Code").text == "helpers 4 of 6 done")
        #expect(HelperProgress.of(AgentBoard(), agent: "Claude Code").text == nil)
    }

    @Test func slotHelpIncludesProgress() {
        let board = fanOut(6, finished: 4)
        let marks = NotchMarks.make(board, approvalsFrom: [])
        #expect(HelperProgress.slotHelp(marks: marks, progress: HelperProgress.of(board, agent: "Claude Code"))
                == "Claude Code: 1 · helpers 4 of 6 done")
        let idle = NotchMarks.make(fanOut(0), approvalsFrom: [])
        #expect(HelperProgress.slotHelp(marks: idle, progress: HelperProgress.of(fanOut(0), agent: "Claude Code")) == "Claude Code: 1")
    }

    @Test func failureFromAgentCallFailure() {
        var board = fanOut(2)
        let failure = step(&board, fail("t1"))
        #expect(failure?.text == "perf helper failed")
        #expect(failure?.session == "s1" && failure?.agent == "Claude Code")
    }

    @Test func nameUsesTaskForGeneralPurpose() {
        var board = AgentBoard()
        board.apply(call("t1", type: "general-purpose", task: "Lint cart"))
        #expect(step(&board, fail("t1"))?.text == "Lint cart helper failed")
    }

    @Test func longNameIsCut() {
        var board = AgentBoard()
        board.apply(call("t1", type: "general-purpose", task: "Rewrite the whole checkout flow"))
        #expect(step(&board, fail("t1"))?.text == "Rewrite the who… helper failed")
    }

    @Test func finishingIsNotFailure() {
        var board = fanOut(2)
        #expect(step(&board, done("t0")) == nil)
        board.apply(hook("SubagentStart", #"{\#(base("s1")),"agent_id":"a1","agent_type":"perf"}"#))
        #expect(step(&board, hook("SubagentStop", #"{\#(base("s1")),"agent_id":"a1"}"#)) == nil)
    }

    @Test func interruptIsNotFailure() {
        var board = fanOut(1)
        #expect(step(&board, fail("t0", interrupt: true)) == nil)
    }

    @Test func innerToolFailureIsNotFailure() {
        var board = fanOut(1)
        board.apply(hook("SubagentStart", #"{\#(base("s1")),"agent_id":"a1","agent_type":"perf"}"#))
        #expect(step(&board, hook("PostToolUseFailure", #"{\#(base("s1")),"agent_id":"a1","tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/nope"}}"#)) == nil)
    }

    @Test func failuresMerge() throws {
        var board = fanOut(3)
        board.apply(call("x1", type: "builder", session: "s2"))
        let first = try #require(step(&board, fail("t0")))
        let second = try #require(step(&board, fail("t1")))
        let merged = HelperFailure.merge(shown: first, new: second)
        #expect(merged.text == "2 helpers failed")
        let other = try #require(step(&board, fail("x1", session: "s2")))
        #expect(HelperFailure.merge(shown: merged, new: other).text == "builder helper failed", "another session replaces")
        #expect(HelperFailure.merge(shown: nil, new: first) == first)
    }

    @Test func claudeOnly() {
        var board = AgentBoard()
        board.apply(hook("PreToolUse", provider: "copilot", #"{\#(base("c1")),"tool_name":"Task","tool_use_id":"t1","tool_input":{"description":"Find","subagent_type":"Explore"}}"#))
        #expect(step(&board, fail("t1", session: "c1", provider: "copilot")) == nil)
    }
    @Test func backgroundHelperAfterStopStillCounts() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", #"{\#(base("s1")),"prompt":"go"}"#))
        board.apply(hook("PreToolUse", #"{\#(base("s1")),"tool_name":"Agent","tool_use_id":"b1","tool_input":{"description":"Watch","subagent_type":"perf","run_in_background":true}}"#))
        board.apply(hook("PostToolUse", #"{\#(base("s1")),"tool_name":"Agent","tool_use_id":"b1","tool_input":{"run_in_background":true}}"#))
        board.apply(hook("Stop", "{\(base("s1"))}"))
        let progress = HelperProgress.of(board, agent: "Claude Code")
        #expect(progress.badge == "1" && progress.text == "helpers 0 of 1 done")
        // A finished session's done helpers say nothing.
        var finished = fanOut(2, finished: 2)
        finished.apply(hook("Stop", "{\(base("s1"))}"))
        #expect(HelperProgress.of(finished, agent: "Claude Code").text == nil)
    }

    @Test func marksCarryTheProgress() {
        let mark = NotchMarks.make(fanOut(6, finished: 4), approvalsFrom: []).shown.first
        #expect(mark?.helperProgress == HelperProgress(running: 2, total: 6))
    }

    @Test func nestedHelperFailureNamesTheNestedOne() {
        var board = AgentBoard()
        board.apply(call("t1", type: "planner"))
        board.apply(hook("SubagentStart", #"{\#(base("s1")),"agent_id":"a5","agent_type":"planner"}"#))
        board.apply(call("n1", type: "reviewer", parent: "a5"))
        let failure = step(&board, hook("PostToolUseFailure", #"{\#(base("s1")),"agent_id":"a5","tool_name":"Agent","tool_use_id":"n1","tool_input":{},"is_interrupt":false}"#))
        #expect(failure?.text == "reviewer helper failed")
    }

    @Test func namesDropControlAndFormatCharacters() {
        var board = AgentBoard()
        board.apply(call("t1", type: #"\u202EAppro\u200Bval\nneeded\u0007"#))  // JSON escapes, as a hook would send
        #expect(step(&board, fail("t1"))?.text == "Approval needed helper failed")
        board.apply(call("t2", type: #"\u202E\u200B"#))
        #expect(step(&board, fail("t2"))?.text == "Helper helper failed", "nothing printable left: a plain name")
    }

    @Test func mergedNamesAreCapped() {
        var merged: HelperFailure?
        for i in 0..<50 { merged = HelperFailure.merge(shown: merged, new: HelperFailure(session: "s1", agent: "Claude Code", names: ["h\(i)"])) }
        #expect(merged?.count == 50 && merged?.names == ["h47", "h48", "h49"])
        #expect(merged?.text == "50 helpers failed")
    }
}

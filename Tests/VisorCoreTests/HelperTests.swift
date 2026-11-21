import Foundation
import Testing
@testable import VisorCore

@Suite("Subagent helpers")
struct HelperTests {
    let base = #""session_id":"s1","cwd":"/Users/me/api""#
    func task(_ id: String, _ description: String, type: String = "Explore", background: Bool = false) -> HookMessage {
        hook("PreToolUse", #"{\#(base),"tool_name":"Task","tool_use_id":"\#(id)","tool_input":{"description":"\#(description)","subagent_type":"\#(type)","run_in_background":\#(background)}}"#)
    }

    /// Parallel helpers are told apart by agent_id, matched to their Task call by type, and finish on SubagentStop.
    @Test func parallelHelpers() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"go"}"#))
        board.apply(task("t1", "Study Dia notes", type: "web-fetch"))
        board.apply(task("t2", "Check plugin API"))
        #expect(board.sessions[0].helpers.count == 2 && board.sessions[0].state == .working("Waiting on 2 helpers"))
        board.apply(hook("SubagentStart", #"{\#(base),"agent_id":"a2","agent_type":"Explore"}"#))
        board.apply(hook("SubagentStart", #"{\#(base),"agent_id":"a1","agent_type":"web-fetch"}"#))
        #expect(board.sessions[0].helpers.map(\.agentID) == ["a1", "a2"])

        // A helper's own tools change its line, not the parent's.
        board.apply(hook("PreToolUse", #"{\#(base),"agent_id":"a1","agent_type":"web-fetch","tool_name":"WebFetch","tool_input":{"url":"https://dia.so/releases"}}"#))
        #expect(board.sessions[0].helpers[0].activity == "WebFetch: dia.so")
        #expect(board.sessions[0].state == .working("Waiting on 2 helpers"))

        board.apply(hook("SubagentStop", #"{\#(base),"agent_id":"a2","agent_type":"Explore"}"#))
        #expect(board.sessions[0].helpers[1].done && board.sessions[0].runningHelpers == 1)
        #expect(board.sessions[0].state == .working("Waiting on 1 helper"))
        board.apply(hook("SubagentStop", #"{\#(base),"agent_id":"a1"}"#))
        #expect(board.sessions[0].state == .working("Thinking"))

        // Finished helpers stay until the next prompt.
        board.apply(hook("Stop", "{\(base)}"))
        #expect(board.sessions[0].helpers.count == 2)
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"next"}"#))
        #expect(board.sessions[0].helpers.isEmpty)
    }

    /// Without SubagentStart/Stop (Copilot), a foreground Task's PostToolUse ends it; a background one keeps running.
    @Test func endsWithoutSubagentHooks() {
        var board = AgentBoard()
        board.apply(task("t1", "Find usages"))
        board.apply(task("t2", "Watch the build", background: true))
        board.apply(hook("PostToolUse", #"{\#(base),"tool_name":"Task","tool_use_id":"t1","tool_input":{}}"#))
        board.apply(hook("PostToolUse", #"{\#(base),"tool_name":"Task","tool_use_id":"t2","tool_input":{"run_in_background":true}}"#))
        #expect(board.sessions[0].helpers.map(\.done) == [true, false])
    }

    /// A helper's PostToolUse clears its line; the parent's own tools never finish a running helper.
    @Test func postToolUseRouting() {
        var board = AgentBoard()
        board.apply(task("t1", "Find usages"))
        board.apply(hook("SubagentStart", #"{\#(base),"agent_id":"a1","agent_type":"Explore"}"#))
        board.apply(hook("PreToolUse", #"{\#(base),"agent_id":"a1","tool_name":"Read","tool_input":{"file_path":"/Users/me/api/main.swift"}}"#))
        #expect(board.sessions[0].helpers[0].activity != nil)
        board.apply(hook("PostToolUse", #"{\#(base),"agent_id":"a1","tool_name":"Read","tool_input":{"file_path":"/Users/me/api/main.swift"}}"#))
        #expect(board.sessions[0].helpers[0].activity == nil)
        #expect(!board.sessions[0].helpers[0].done)

        board.apply(task("t2", "Check docs"))
        board.apply(hook("PostToolUse", #"{\#(base),"tool_name":"Read","tool_input":{"file_path":"/Users/me/api/a.swift"}}"#))
        #expect(board.sessions[0].helpers.map(\.done) == [false, false])
    }

    /// Many helpers: the session keeps at most `maxHelpers`, dropping finished ones first.
    @Test func manyHelpersAreCapped() {
        var board = AgentBoard()
        for i in 0..<40 {
            board.apply(task("t\(i)", "Job \(i)"))
            if i < 30 { board.apply(hook("PostToolUse", #"{\#(base),"tool_name":"Task","tool_use_id":"t\#(i)","tool_input":{}}"#)) }
        }
        let helpers = board.sessions[0].helpers
        #expect(helpers.count == AgentSession.maxHelpers)
        #expect(helpers.filter { !$0.done }.count == 10, "running ones are never dropped for finished ones")
        #expect(board.sessions[0].state == .working("Waiting on 10 helpers"))
    }

    /// The list shows running helpers first, at most `rows`, and says how many more.
    @Test func listRows() {
        var session = AgentSession(id: "s", agent: "Claude Code", cwd: "/a", state: .idle)
        session.helpers = (0..<9).map { AgentHelper(id: "h\($0)", type: "Explore", task: "Job \($0)", done: $0 < 4) }
        let shown = session.helperRows(limit: 6)
        #expect(shown.rows.count == 6 && shown.more == 3)
        #expect(shown.rows.prefix(5).allSatisfy { !$0.done }, "running first")
    }
}

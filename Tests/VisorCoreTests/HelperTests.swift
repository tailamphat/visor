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

@Suite("Helper graph model")
struct HelperModelTests {
    let base = #""session_id":"s1","cwd":"/Users/me/api""#
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func agentCall(_ event: String = "PreToolUse", id: String, _ description: String = "Job", parent: String? = nil,
                   type: String = "general-purpose", background: Bool = false, extra: String = "", provider: String = "claude") -> HookMessage {
        let owner = parent.map { #","agent_id":"\#($0)","agent_type":"general-purpose""# } ?? ""
        return hook(event, provider: provider, #"{\#(base)\#(owner)\#(extra),"tool_name":"Agent","tool_use_id":"\#(id)","tool_input":{"description":"\#(description)","subagent_type":"\#(type)","run_in_background":\#(background)}}"#)
    }
    func start(_ agent: String, type: String = "general-purpose") -> HookMessage {
        hook("SubagentStart", #"{\#(base),"agent_id":"\#(agent)","agent_type":"\#(type)"}"#)
    }
    func stop(_ agent: String) -> HookMessage {
        hook("SubagentStop", #"{\#(base),"agent_id":"\#(agent)","agent_type":"general-purpose"}"#)
    }

    /// The real Claude Code run from I1, replayed one second apart.
    @Test func realNestedRun() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-nested-helpers/hooks.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var board = AgentBoard()
        for (n, line) in lines.enumerated() {
            let payload = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let message = HookMessage(event: payload["hook_event_name"] as? String ?? "", pid: 4242, payload: payload)
            board.apply(message, now: t0.addingTimeInterval(Double(n)))
        }
        let helpers = board.sessions[0].helpers
        #expect(helpers.map(\.task) == ["Nested echo helper", "Read nonexistent file helper", "Run echo hi check"])
        #expect(helpers.map(\.agentID) == ["aa4eb4f3833ee7f21", "ad387ef141e3adaed", "a0df93125a344e958"])
        #expect(helpers.map(\.parent) == [nil, nil, "aa4eb4f3833ee7f21"])
        #expect(helpers.allSatisfy { $0.done && !$0.failed })
        for h in helpers {
            let s = try #require(h.start), e = try #require(h.end)
            #expect(s <= e)
        }
        let outer = helpers[0], inner = helpers[2]
        #expect(inner.start! > outer.start! && inner.end! < outer.end!)
    }

    @Test func innerFailureIsNotHelperFailure() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1"))
        board.apply(start("a1"))
        board.apply(hook("PostToolUseFailure", #"{\#(base),"agent_id":"a1","agent_type":"general-purpose","tool_name":"Read","tool_use_id":"r1","error":"File does not exist."}"#))
        #expect(!board.sessions[0].helpers[0].failed && !board.sessions[0].helpers[0].done)
    }

    @Test func agentCallFailureFails() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1"))
        board.apply(start("a1"))
        board.apply(agentCall(id: "t2", parent: "a1"))
        board.apply(start("a2"))
        board.apply(agentCall("PostToolUseFailure", id: "t2", parent: "a1", extra: #","error":"boom""#), now: t0)
        let helpers = board.sessions[0].helpers
        #expect(helpers.map(\.failed) == [false, true], "only the nested one failed")
        #expect(helpers[1].done && helpers[1].end == t0)
        board.apply(agentCall("PostToolUseFailure", id: "t1", extra: #","error":"boom","is_interrupt":false"#))
        #expect(board.sessions[0].helpers[0].failed)
    }

    @Test func interruptIsNotFailure() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1"))
        board.apply(agentCall("PostToolUseFailure", id: "t1", extra: #","error":"Interrupted","is_interrupt":true"#))
        #expect(board.sessions[0].helpers[0].done && !board.sessions[0].helpers[0].failed)
    }

    @Test func startAndEndTimes() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1"), now: t0)
        board.apply(start("a1"), now: t0.addingTimeInterval(1))
        board.apply(stop("a1"), now: t0.addingTimeInterval(5))
        board.apply(agentCall("PostToolUse", id: "t1"), now: t0.addingTimeInterval(6))
        #expect(board.sessions[0].helpers[0].start == t0)
        #expect(board.sessions[0].helpers[0].end == t0.addingTimeInterval(5), "first end wins")

        board.apply(agentCall(id: "t2", background: true), now: t0.addingTimeInterval(7))
        board.apply(agentCall("PostToolUse", id: "t2", background: true), now: t0.addingTimeInterval(8))
        board.apply(start("a2"), now: t0.addingTimeInterval(8))
        #expect(board.sessions[0].helpers[1].end == nil && !board.sessions[0].helpers[1].done)
        board.apply(stop("a2"), now: t0.addingTimeInterval(20))
        #expect(board.sessions[0].helpers[1].end == t0.addingTimeInterval(20))

        // A helper with no Agent call starts at its SubagentStart.
        board.apply(start("a3"), now: t0.addingTimeInterval(30))
        #expect(board.sessions[0].helpers.last?.start == t0.addingTimeInterval(30))
    }

    @Test func linkFixesAMismatch() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1", "First"))
        board.apply(agentCall(id: "t2", "Second"))
        board.apply(start("a2"))   // really t2's, but order matching gives it to t1
        board.apply(start("a1"))
        #expect(board.sessions[0].helpers.map(\.agentID) == ["a2", "a1"])
        board.link(session: "s1", agentID: "a2", toolUseID: "t2")
        #expect(board.sessions[0].helpers.map(\.agentID) == ["a1", "a2"])
        let before = board
        board.link(session: "s1", agentID: "a2", toolUseID: "t2")
        #expect(board == before)
    }

    /// Gate R1: a stop recorded on the wrong row by order moves with the agent id.
    @Test func linkMovesAnEarlyStop() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1", background: true), now: t0)
        board.apply(agentCall(id: "t2", background: true), now: t0)
        board.apply(start("a2"))
        board.apply(start("a1"))
        board.apply(stop("a2"), now: t0.addingTimeInterval(4))
        board.link(session: "s1", agentID: "a2", toolUseID: "t2")
        var helpers = board.sessions[0].helpers
        #expect(helpers.map(\.done) == [false, true] && helpers[1].end == t0.addingTimeInterval(4) && helpers[0].end == nil)
        board.apply(stop("a1"), now: t0.addingTimeInterval(9))
        helpers = board.sessions[0].helpers
        #expect(helpers.allSatisfy(\.done) && helpers[0].end == t0.addingTimeInterval(9))
        #expect(board.sessions[0].state == .working("Thinking"))
    }

    /// Gate R2: a stop for an agent no row knows never finishes a helper linked to another agent.
    @Test func unknownStopLeavesLinkedHelpers() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1"))
        board.apply(start("a1"))
        board.apply(stop("gone"))
        #expect(!board.sessions[0].helpers[0].done && board.sessions[0].helpers[0].end == nil)
    }

    /// Gate R3: a running nested helper whose finished parent is dropped at the next prompt becomes top-level.
    @Test func orphanBecomesTopLevel() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1"))
        board.apply(start("a1"))
        board.apply(agentCall(id: "t2", parent: "a1", background: true))
        board.apply(start("a2"))
        board.apply(stop("a1"))
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"next"}"#))
        let helpers = board.sessions[0].helpers
        #expect(helpers.map(\.id) == ["t2"] && helpers[0].parent == nil)
        #expect(board.sessions[0].waitingOn == 1)
    }

    /// A background Agent call that fails ends its helper as failed.
    @Test func backgroundCallFailure() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1", background: true))
        board.apply(agentCall("PostToolUseFailure", id: "t1", background: true, extra: #","error":"boom""#), now: t0)
        #expect(board.sessions[0].helpers[0].failed && board.sessions[0].helpers[0].done && board.sessions[0].helpers[0].end == t0)
    }

    /// Security gate: ids and types from hooks are capped in length.
    @Test func longIdsAreCapped() {
        var board = AgentBoard()
        let long = String(repeating: "x", count: 10_000)
        board.apply(agentCall(id: long, parent: long, type: long))
        board.apply(hook("SubagentStart", #"{\#(base),"agent_id":"\#(long)","agent_type":"\#(long)"}"#))
        for h in board.sessions[0].helpers {
            #expect(h.id.count <= 128 && (h.parent?.count ?? 0) <= 128 && h.type.count <= 128 && (h.agentID?.count ?? 0) <= 128)
        }
    }

    @Test func waitLineCountsTopLevel() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1"))
        board.apply(start("a1"))
        board.apply(agentCall(id: "t2", parent: "a1"))
        board.apply(start("a2"))
        #expect(board.sessions[0].helpers.count == 2)
        #expect(board.sessions[0].state == .working("Waiting on 1 helper"))
        #expect(board.sessions[0].helpers[0].activity == "Agent: Job", "the parent's line shows its Agent call")
    }

    @Test func nestedOnlyForClaude() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1", parent: "a1", provider: "copilot"))
        #expect(board.sessions[0].helpers.isEmpty)
    }

    @Test func nestedHelpersAreCapped() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t0"))
        board.apply(start("a0"))
        for i in 1..<30 { board.apply(agentCall(id: "t\(i)", parent: "a0")) }
        #expect(board.sessions[0].helpers.count == AgentSession.maxHelpers)
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"next"}"#))
        #expect(board.sessions[0].helpers.count == AgentSession.maxHelpers, "running ones carry over")
    }

    @Test func secondEndIsNotVisible() {
        var board = AgentBoard()
        board.apply(agentCall(id: "t1"), now: t0)
        board.apply(start("a1"), now: t0)
        board.apply(stop("a1"), now: t0.addingTimeInterval(3))
        let before = board
        board.apply(agentCall("PostToolUse", id: "t1"), now: t0.addingTimeInterval(4))
        #expect(!board.differsVisibly(from: before))
    }

    @Test func oldHelpersLoad() throws {
        let old = #"[{"id":"s1","pid":4242,"cwd":"/Users/me/api","state":{"idle":{}},"since":0,"lastEvent":0,"agent":"Claude Code","askedForReply":false,"helperList":[{"id":"t1","agentID":"a1","type":"Explore","task":"Find","done":true,"background":false}]}]"#
        let board = AgentBoard.restored(from: Data(old.utf8)) { _ in true }
        let helper = try #require(board.sessions.first?.helpers.first)
        #expect(helper.parent == nil && helper.start == nil && helper.end == nil && !helper.failed)
    }

    @Test func hostileHelperEventsAreBounded() {
        var board = AgentBoard()
        board.apply(hook("PreToolUse", #"{\#(base),"agent_id":42,"tool_name":"Agent","tool_use_id":["x"],"tool_input":{"description":7,"subagent_type":null}}"#))
        board.apply(hook("PostToolUseFailure", #"{\#(base),"tool_name":"Agent","tool_use_id":{"a":1},"is_interrupt":"yes"}"#))
        board.apply(hook("SubagentStart", #"{\#(base),"agent_id":[1],"agent_type":3}"#))
        for i in 0..<50 { board.apply(agentCall(id: "n\(i)", parent: "missing-\(i)")) }
        board.link(session: "s1", agentID: "nope", toolUseID: "nope")
        board.link(session: "other", agentID: "a", toolUseID: "n1")
        #expect(board.sessions[0].helpers.count <= AgentSession.maxHelpers)
        #expect(board.sessions[0].helpers.allSatisfy { $0.parent == nil || $0.parent!.hasPrefix("missing-") })
    }
}

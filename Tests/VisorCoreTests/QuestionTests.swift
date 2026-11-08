import Foundation
import Testing
@testable import VisorCore

@Suite("Agent questions")
struct QuestionTests {
    let base = #""session_id":"s1","cwd":"/Users/me/workspace/visor""#
    let ask = #""tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which range should the chart show?","header":"Spend chart","multiSelect":false,"options":[{"label":"14 days","description":"Matches today's chart"},{"label":"30 days","description":"Lines up with the total"}]},{"question":"Which platforms?","header":"Platforms","multiSelect":true,"options":[{"label":"macOS"},{"label":"Windows"}]}]}"#

    /// The header is what the notch and the agent list call the question.
    @Test func readsTheHeaderAsTheLabel() throws {
        let question = try #require(AgentQuestion(hook("PreToolUse", "{\(base),\(ask)}")))
        #expect(question.label == "Spend chart")
    }

    @Test func aQuestionWithoutAHeaderUsesItsText() throws {
        let short = #""tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","options":[{"label":"A"}]}]}"#
        #expect(AgentQuestion(hook("PreToolUse", "{\(base),\(short)}"))?.label == "Which?")

        let long = String(repeating: "word ", count: 12)
        let json = #"{"session_id":"s1","cwd":"/Users/me/workspace/visor","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"\#(long)"}]}}"#
        let label = try #require(AgentQuestion(hook("PreToolUse", json))?.label)
        #expect(label.count == 40, "39 characters plus an ellipsis")
        #expect(label.hasSuffix("…"))
    }

    @Test func otherToolsAreNotQuestions() {
        #expect(AgentQuestion(hook("PreToolUse", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"ls"}}"#)) == nil)
        #expect(AgentQuestion(hook("PreToolUse", #"{\#(base),"tool_name":"AskUserQuestion","tool_input":{}}"#)) == nil)
    }

    @Test func aQuestionIsStillARecognisedPermissionStep() throws {
        let held = try #require(ApprovalRequest(hook("PermissionRequest", "{\(base),\(ask)}")))
        #expect(held.isQuestion)
        #expect(ApprovalRequest(hook("PermissionRequest", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"ls"}}"#))?.isQuestion == false)
    }

    @Test func boardShowsAsking() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"Redesign usage"}"#))
        board.apply(hook("PreToolUse", "{\(base),\(ask)}"))
        #expect(board.sessions[0].state == .asking("Spend chart"))
        board.apply(hook("PermissionRequest", "{\(base),\(ask)}"))
        board.apply(hook("Notification", #"{\#(base),"notification_type":"permission_prompt","message":"Claude needs your permission"}"#))
        #expect(board.sessions[0].state == .asking("Spend chart"), "the permission step of a question is still a question")
        #expect(board.waiting == 1 && board.sessions[0].isActive)
        board.apply(hook("PostToolUse", #"{\#(base),"tool_name":"AskUserQuestion"}"#))
        #expect(board.sessions[0].state == .working("Thinking"))
    }

    @Test func closedNotchTellsApprovalsFromQuestions() {
        var board = AgentBoard()
        board.apply(hook("PreToolUse", "{\(base),\(ask)}"))
        let copilot = #""session_id":"s2","cwd":"/Users/me/workspace/gitlane""#
        board.apply(hook("PermissionRequest", provider: "copilot", #"{\#(copilot),"toolName":"bash","toolArgs":{"command":"rm -rf build"}}"#))
        let marks = NotchMarks.make(board, pendingApproval: false)
        #expect(marks.shown.map(\.attention) == [.approval, .question], "approvals first: they block the agent")
        #expect(marks.shown.map(\.agent) == ["Copilot CLI", "Claude Code"])
    }

    @Test func waitingForAReplyIsAQuestion() {
        var board = AgentBoard()
        board.apply(hook("Notification", #"{\#(base),"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#))
        #expect(NotchMarks.make(board, pendingApproval: false).shown.first?.attention == .question)
    }
}

@Suite("Finished turns")
struct FinishedTurnTests {
    let base = #""session_id":"s1","cwd":"/Users/me/workspace/visor""#

    @Test func stopReportsProjectAndDuration() throws {
        var board = AgentBoard()
        let start = Date(timeIntervalSince1970: 1_000)
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"Fix it"}"#), now: start)
        board.apply(hook("PreToolUse", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"ls"}}"#), now: start + 60)
        let done = try #require(board.finished(hook("Stop", "{\(base)}"), now: start + 252))
        #expect(done.project == "visor" && done.agent == "Claude Code")
        #expect(done.duration == 252 && done.durationText == "4m 12s")
    }

    @Test func otherEventsAreNotFinishes() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"Fix it"}"#))
        #expect(board.finished(hook("PostToolUse", #"{\#(base),"tool_name":"Bash"}"#)) == nil)
    }

    @Test("Durations", arguments: [(8.0, "8s"), (59.4, "59s"), (60.0, "1m"), (252.0, "4m 12s"), (3720.0, "1h 2m")])
    func durations(seconds: Double, text: String) {
        #expect(FinishedTurn.text(for: seconds) == text)
    }
}

@Suite("Open approval cards")
struct OpenApprovalMarkTests {
    /// A Copilot approval card doesn't make Claude's question look like an approval.
    @Test func onlyTheAskingAgentTurnsAmber() {
        var board = AgentBoard()
        board.apply(hook("PreToolUse", #"{"session_id":"s1","cwd":"/x/visor","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","options":[{"label":"A"},{"label":"B"}]}]}}"#))
        board.apply(hook("userPromptSubmitted", provider: "copilot", #"{"sessionId":"c1","cwd":"/x/gitlane"}"#))
        let marks = NotchMarks.make(board, approvalsFrom: ["Copilot CLI"])
        #expect(marks.shown.first { $0.agent == "Claude Code" }?.attention == .question)
        #expect(marks.shown.first { $0.agent == "Copilot CLI" }?.attention == .approval)
    }
}

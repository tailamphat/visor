import Foundation
import Testing
@testable import VisorCore

@Suite("Agent questions")
struct QuestionTests {
    let base = #""session_id":"s1","cwd":"/Users/me/workspace/visor""#
    let ask = #""tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which range should the chart show?","header":"Spend chart","multiSelect":false,"options":[{"label":"14 days","description":"Matches today's chart"},{"label":"30 days","description":"Lines up with the total"}]},{"question":"Which platforms?","header":"Platforms","multiSelect":true,"options":[{"label":"macOS"},{"label":"Windows"}]}]}"#

    @Test func readsTheQuestions() throws {
        let question = try #require(AgentQuestion(hook("PreToolUse", "{\(base),\(ask)}")))
        #expect(question.sessionID == "s1" && question.project == "visor" && question.agent == "Claude Code")
        #expect(question.items.count == 2)
        #expect(question.items[0].header == "Spend chart" && question.items[0].text == "Which range should the chart show?")
        #expect(question.items[0].options.map(\.label) == ["14 days", "30 days"])
        #expect(question.items[0].options[0].detail == "Matches today's chart")
        #expect(!question.items[0].multiSelect && question.items[1].multiSelect)
        #expect(question.items[1].options[1].detail == nil)
    }

    @Test func otherToolsAreNotQuestions() {
        #expect(AgentQuestion(hook("PreToolUse", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"ls"}}"#)) == nil)
        #expect(AgentQuestion(hook("PreToolUse", #"{\#(base),"tool_name":"AskUserQuestion","tool_input":{}}"#)) == nil)
    }

    /// A question's permission step is held like an approval, so the notch can answer it.
    @Test func aQuestionIsHeldForAnswering() throws {
        let held = try #require(ApprovalRequest(hook("PermissionRequest", "{\(base),\(ask)}")))
        #expect(held.isQuestion)
        #expect(ApprovalRequest(hook("PermissionRequest", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"ls"}}"#))?.isQuestion == false)
    }

    /// The answer goes back as "allow" with the tool's input plus `answers`, keyed by question text.
    @Test func answersGoBackInTheToolInput() throws {
        let held = try #require(ApprovalRequest(hook("PermissionRequest", "{\(base),\(ask)}")))
        let question = try #require(AgentQuestion(hook("PermissionRequest", "{\(base),\(ask)}")))
        let answers = question.answers(picks: [0: [1], 1: [0, 1]])
        #expect(answers == ["Which range should the chart show?": "30 days", "Which platforms?": "macOS, Windows"])
        let reply = try #require(JSONSerialization.jsonObject(with: held.reply(.answer(answers))) as? [String: Any])
        let output = try #require(reply["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(output["decision"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest" && decision["behavior"] as? String == "allow")
        let input = try #require(decision["updatedInput"] as? [String: Any])
        #expect((input["questions"] as? [Any])?.count == 2, "the questions stay as they were")
        #expect(input["answers"] as? [String: String] == answers)
    }

    @Test func unansweredQuestionsAreLeftOut() throws {
        let question = try #require(AgentQuestion(hook("PreToolUse", "{\(base),\(ask)}")))
        #expect(question.answers(picks: [0: [0]]) == ["Which range should the chart show?": "14 days"])
        #expect(question.answers(picks: [0: [7]]).isEmpty, "a pick past the options is ignored")
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

    /// A card only belongs on screen while the session still waits on the question:
    /// answered elsewhere, finished or gone means it must not linger.
    @Test func aQuestionOnlyCountsWhileTheSessionIsAsking() throws {
        let question = try #require(AgentQuestion(hook("PreToolUse", "{\(base),\(ask)}")))
        var board = AgentBoard()
        board.apply(hook("PreToolUse", "{\(base),\(ask)}"))
        #expect(board.stillAsking(question))
        board.apply(hook("PostToolUse", #"{\#(base),"tool_name":"AskUserQuestion"}"#))
        #expect(!board.stillAsking(question))
    }

    @Test func aQuestionStopsCountingWhenTheSessionFinishesOrGoesAway() throws {
        let question = try #require(AgentQuestion(hook("PreToolUse", "{\(base),\(ask)}")))
        var board = AgentBoard()
        board.apply(hook("PreToolUse", "{\(base),\(ask)}"))
        board.apply(hook("Stop", "{\(base)}"))
        #expect(!board.stillAsking(question), "a finished turn is not asking")

        board = AgentBoard()
        board.apply(hook("PreToolUse", "{\(base),\(ask)}"))
        board.prune { _ in false }
        #expect(!board.stillAsking(question), "a session that exited is not asking")
    }

    /// Answering from the card moves the session on at once, so the closed notch
    /// stops showing the "?" before the next hook event arrives.
    @Test func answeringMovesTheSessionOn() {
        var board = AgentBoard()
        board.apply(hook("PreToolUse", "{\(base),\(ask)}"))
        board.resolveQuestion(session: "s1")
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

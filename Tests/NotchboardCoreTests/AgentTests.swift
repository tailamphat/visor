import Foundation
import Testing
@testable import NotchboardCore

/// A hook message as agent-hook.sh writes it.
func hook(_ event: String, provider: String = "claude", pid: Int = 4242, _ raw: String) -> HookMessage {
    HookMessage.parse(Data(#"{"event":"\#(event)","provider":"\#(provider)","pid":\#(pid),"raw":\#(raw)}"#.utf8))!
}

@Suite("Agent board")
struct AgentBoardTests {
    let base = #""session_id":"s1","cwd":"/Users/me/workspace/notchboard""#

    @Test func sessionLifecycle() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", "{\(base)}"))
        #expect(board.sessions.count == 1 && board.sessions[0].state == .idle)
        #expect(board.sessions[0].project == "notchboard" && board.sessions[0].pid == 4242)

        board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"Fix the login bug\nand add tests"}"#))
        #expect(board.sessions[0].state == .working("Thinking") && board.working == 1)
        #expect(board.sessions[0].task == "Fix the login bug" && board.sessions[0].agent == "Claude Code")

        board.apply(hook("PreToolUse", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"swift build\nswift run"}}"#))
        #expect(board.sessions[0].state == .working("Bash: swift build"))

        board.apply(hook("PermissionRequest", #"{\#(base),"tool_name":"Edit","tool_input":{"file_path":"/a/b/Main.swift"}}"#))
        #expect(board.sessions[0].state == .needsApproval("Edit: Main.swift") && board.waiting == 1)
        board.apply(hook("Notification", #"{\#(base),"notification_type":"permission_prompt","message":"Claude needs your permission"}"#))
        #expect(board.sessions[0].state == .needsApproval("Edit: Main.swift"), "a permission notification keeps the detail")

        board.resolveApproval(session: "s1")
        #expect(board.sessions[0].state == .working("Thinking"))
        board.apply(hook("Stop", "{\(base)}"))
        #expect(board.sessions[0].state == .done && !board.sessions[0].isActive)
        board.apply(hook("Notification", #"{\#(base),"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#))
        #expect(board.sessions[0].state == .needsInput)
    }

    @Test func hostIsRecorded() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", "{\(base)}"))
        board.setHost("Ghostty", session: "s1")
        #expect(board.sessions[0].host == "Ghostty")
    }

    @Test func pruneDropsExitedProcesses() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", "{\(base)}"))
        board.prune { _ in true }
        #expect(board.sessions.count == 1)
        board.prune { _ in false }
        #expect(board.sessions.isEmpty)
    }

    @Test func sessionEndRemovesIt() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", "{\(base)}"))
        board.apply(hook("SessionEnd", "{\(base)}"))
        #expect(board.sessions.isEmpty)
        board.apply(hook("Stop", "{}"))
        #expect(board.sessions.isEmpty, "events without a session id are ignored")
    }

    @Test func hookPIDIsRead() {
        #expect(HookMessage.parse(Data(#"{"event":"Stop","pid":1,"hpid":77,"raw":{}}"#.utf8))?.hookPID == 77)
    }
}

@Suite("Copilot CLI hooks")
struct CopilotHookTests {
    let base = #""sessionId":"c1","cwd":"/Users/me/shop","timestamp":1793458000000"#

    @Test func copilotEventsBecomeClaudeEvents() {
        let start = hook("sessionStart", provider: "copilot", "{\(base),\"source\":\"new\"}")
        #expect(start.event == "SessionStart" && start.sessionID == "c1" && start.provider == "copilot")
    }

    @Test func copilotSession() {
        var board = AgentBoard()
        board.apply(hook("sessionStart", provider: "copilot", "{\(base)}"))
        #expect(board.sessions.first?.agent == "Copilot CLI" && board.sessions.first?.project == "shop")
        board.apply(hook("userPromptSubmitted", provider: "copilot", "{\(base),\"prompt\":\"Deploy staging\"}"))
        #expect(board.sessions[0].task == "Deploy staging" && board.sessions[0].state == .working("Thinking"))
        board.apply(hook("preToolUse", provider: "copilot", #"{\#(base),"toolName":"bash","toolArgs":{"command":"npm run deploy"}}"#))
        #expect(board.sessions[0].state == .working("Bash: npm run deploy"), "Copilot's bash tool reads like Bash")
        board.apply(hook("preToolUse", provider: "copilot", #"{\#(base),"toolName":"edit","toolArgs":"{\"path\":\"a.ts\"}"}"#))
        #expect(board.sessions[0].state == .working("edit"), "tool arguments sent as a JSON string are decoded")
        board.apply(hook("notification", provider: "copilot", #"{\#(base),"notification_type":"agent_idle","message":"Waiting"}"#))
        #expect(board.sessions[0].state == .needsInput)
        board.apply(hook("agentStop", provider: "copilot", "{\(base),\"stopReason\":\"end_turn\"}"))
        #expect(board.sessions[0].state == .done)
    }

    @Test func waitingAgentComesFirst() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", pid: 8, #"{"session_id":"k1","cwd":"/x/notchboard"}"#))
        board.apply(hook("userPromptSubmitted", provider: "copilot", "{\(base)}"))
        #expect(board.activeAgents.map(\.agent) == ["Claude Code", "Copilot CLI"])
        board.apply(hook("notification", provider: "copilot", #"{\#(base),"notification_type":"agent_idle"}"#))
        #expect(board.activeAgents.first?.agent == "Copilot CLI" && board.activeAgents.first?.waiting == true)
    }
}

@Suite("Closed notch marks")
struct NotchMarksTests {
    func start(_ provider: String, _ id: String, waiting: Bool = false) -> [HookMessage] {
        let raw = #"{"session_id":"\#(id)","sessionId":"\#(id)"}"#
        var out = [hook("UserPromptSubmit", provider: provider, pid: 1, raw)]
        if waiting {
            out.append(hook("Notification", provider: provider, pid: 1, #"{"session_id":"\#(id)","sessionId":"\#(id)","notification_type":"idle_prompt"}"#))
        }
        return out
    }

    @Test func agentNames() {
        #expect(AgentBoard.agentName("codex") == "Codex" && AgentBoard.agentName("claude") == "Claude Code")
    }

    @Test func atMostTwoMarksThenMore() {
        var board = AgentBoard()
        (start("claude", "a") + start("claude", "b")).forEach { board.apply($0) }
        var marks = NotchMarks.make(board, pendingApproval: false)
        #expect(marks.shown == [.init(agent: "Claude Code", count: 2, waiting: false)] && marks.more.isEmpty)

        (start("copilot", "c") + start("codex", "d")).forEach { board.apply($0) }
        marks = NotchMarks.make(board, pendingApproval: false)
        #expect(marks.shown.map(\.agent) == ["Claude Code", "Copilot CLI"] && marks.more == ["Codex"])

        start("codex", "d", waiting: true).forEach { board.apply($0) }
        marks = NotchMarks.make(board, pendingApproval: false)
        #expect(marks.shown.first == .init(agent: "Codex", count: 1, waiting: true) && marks.more == ["Copilot CLI"])
    }

    @Test func openApprovalCountsAsWaiting() {
        var board = AgentBoard()
        start("claude", "a").forEach { board.apply($0) }
        #expect(NotchMarks.make(board, pendingApproval: true).shown.first?.waiting == true)
    }

    @Test("Ears widen for two marks and +N", arguments: [(0, 38.0), (1, 38.0), (2, 62.0), (5, 84.0)])
    func earWidth(agents: Int, width: Double) {
        #expect(NotchMarks.earWidth(agents: agents) == width)
    }
}

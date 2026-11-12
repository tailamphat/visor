import Foundation
import Testing
@testable import VisorCore

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
        // Claude Code says it's waiting about a minute after every turn; a turn
        // that asked nothing is still just done.
        board.apply(hook("Notification", #"{\#(base),"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#))
        #expect(board.sessions[0].state == .done)
    }

    @Test func waitingAfterATurnThatAskedIsAReply() {
        for (reply, asks) in [("Should I commit and release 0.3.2?", true),
                              ("Want me to fix it?**\\n", true),
                              ("要提交吗？", true),
                              ("Good. 0.3.2 is out and the cask is updated. Tell me if anything else comes up with Visor.", false),
                              ("", false)] {
            var board = AgentBoard()
            board.apply(hook("UserPromptSubmit", #"{\#(base),"prompt":"go"}"#))
            board.apply(hook("Stop", #"{\#(base),"last_assistant_message":"\#(reply)"}"#))
            board.apply(hook("Notification", #"{\#(base),"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#))
            #expect(board.sessions[0].state == (asks ? .needsInput : .done), "\(reply)")
        }
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

    @Test func sessionsSurviveARestart() throws {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"Fix the build\"}"))
        board.setHost("Ghostty", session: "s1")
        board.apply(hook("Stop", pid: 5151, #"{"session_id":"s2","cwd":"/Users/me/docs","last_assistant_message":"Should I commit?"}"#))
        board.apply(hook("Notification", pid: 5151, #"{"session_id":"s2","notification_type":"idle_prompt"}"#))

        let restored = try AgentBoard.restored(from: board.saved()) { $0 == 4242 || $0 == 5151 }
        #expect(restored.sessions.map(\.id) == ["s1", "s2"])
        #expect(restored.sessions[0].host == "Ghostty")
        #expect(restored.sessions[0].task == "Fix the build")
        // Whatever it was doing may have ended while Visor was away; its next event says.
        #expect(restored.sessions[0].state == .idle)
        #expect(restored.sessions[1].state == .needsInput, "still waiting for you")

        let oneGone = try AgentBoard.restored(from: board.saved()) { $0 == 5151 }
        #expect(oneGone.sessions.map(\.id) == ["s2"], "exited agents are dropped")
        #expect(AgentBoard.restored(from: Data("junk".utf8)) { _ in true }.sessions.isEmpty)
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
        #expect(board.sessions[0].state == .working("Edit: a.ts"), "Copilot's edit reads like Claude's, arguments decoded from a JSON string")
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
        #expect(board.activeAgents.first?.agent == "Copilot CLI" && board.activeAgents.first?.attention == .question)
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
        #expect(marks.shown == [.init(agent: "Claude Code", count: 2, attention: nil)] && marks.more.isEmpty)

        (start("copilot", "c") + start("codex", "d")).forEach { board.apply($0) }
        marks = NotchMarks.make(board, pendingApproval: false)
        #expect(marks.shown.map(\.agent) == ["Claude Code", "Copilot CLI"] && marks.more == ["Codex"])

        start("codex", "d", waiting: true).forEach { board.apply($0) }
        marks = NotchMarks.make(board, pendingApproval: false)
        #expect(marks.shown.first == .init(agent: "Codex", count: 1, attention: .question) && marks.more == ["Copilot CLI"])
    }

    @Test func openApprovalCountsAsWaiting() {
        var board = AgentBoard()
        start("claude", "a").forEach { board.apply($0) }
        #expect(NotchMarks.make(board, pendingApproval: true).shown.first?.waiting == true)
    }

}

@Suite("Describing what an agent does")
struct DescribeTests {
    @Test("Tool calls in plain words", arguments: [
        ("Read", #"{"file_path":"/a/b/Main.swift"}"#, "Read: Main.swift"),
        ("Write", #"{"file_path":"/a/README.md"}"#, "Write: README.md"),
        ("Grep", #"{"pattern":"TODO"}"#, "Grep: TODO"),
        ("WebFetch", #"{"url":"https://docs.github.com/en/rest"}"#, "WebFetch: docs.github.com"),
        ("WebSearch", #"{"query":"swift testing"}"#, "WebSearch: swift testing"),
        ("Task", #"{"description":"Explore the repo"}"#, "Task: Explore the repo"),
        ("Bash", #"{"description":"Run tests","command":"swift test"}"#, "Bash: Run tests"),
        ("mcp__figma__get_code", "{}", "mcp__figma__get_code"),
    ])
    func describe(tool: String, input: String, expected: String) throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        #expect(AgentBoard.describe(tool: tool, input: object) == expected)
    }

    @Test func noToolIsWorking() {
        #expect(AgentBoard.describe(tool: nil, input: [:]) == "Working")
    }

    @Test func longDetailsAreCut() {
        let command = String(repeating: "x", count: 100)
        let text = AgentBoard.describe(tool: "Bash", input: ["command": command])
        #expect(text.hasPrefix("Bash: ") && text.hasSuffix("…") && text.count == "Bash: ".count + 60)
    }

    @Test func promptsAreSummarised() {
        #expect(AgentBoard.summarize("   \n\n") == nil)
        let long = AgentBoard.summarize(String(repeating: "a", count: 120))
        #expect(long?.count == 80 && long?.hasSuffix("…") == true)
    }
}

@Suite("Agent board, more")
struct AgentBoardMoreTests {
    let base = #""session_id":"s1","cwd":"/x/app""#

    @Test func waitingNotificationWithoutAType() {
        var board = AgentBoard()
        board.apply(hook("Notification", #"{\#(base),"message":"Claude is waiting for your input"}"#))
        #expect(board.sessions.first?.state == .needsInput)
    }

    @Test func otherNotificationsChangeNothing() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base)}"))
        board.apply(hook("Notification", #"{\#(base),"notification_type":"auth_success","message":"Signed in"}"#))
        #expect(board.sessions.first?.state == .working("Thinking"))
    }

    @Test func sessionsWithoutAKnownProcessArentPruned() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", pid: 0, "{\(base)}"))
        board.prune { _ in false }
        #expect(board.sessions.count == 1)
    }

    @Test func resolvingWhenNothingIsAskedDoesNothing() {
        var board = AgentBoard()
        board.apply(hook("Stop", "{\(base)}"))
        board.resolveApproval(session: "s1")
        #expect(board.sessions.first?.state == .done)
    }

    @Test("Lines that aren't hook messages", arguments: ["not json", #"{"pid":1,"raw":{}}"#, ""])
    func badLines(line: String) {
        #expect(HookMessage.parse(Data(line.utf8)) == nil)
    }

    @Test func providerDefaultsToClaude() {
        #expect(HookMessage.parse(Data(#"{"event":"Stop","raw":{}}"#.utf8))?.provider == "claude")
    }
}

@Suite("Only visible changes redraw")
struct VisibleChangeTests {
    let base = #""session_id":"s1","cwd":"/x/app""#

    @Test func anotherEventWithTheSameStateIsNotVisible() {
        var before = AgentBoard()
        before.apply(hook("PreToolUse", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"swift test"}}"#), now: Date(timeIntervalSince1970: 1))
        var after = before
        // The same tool again a second later: only the last-event time moves.
        after.apply(hook("PreToolUse", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"swift test"}}"#), now: Date(timeIntervalSince1970: 2))
        #expect(!after.differsVisibly(from: before))
    }

    @Test func aNewStateIsVisible() {
        var before = AgentBoard()
        before.apply(hook("UserPromptSubmit", "{\(base)}"))
        var after = before
        after.apply(hook("PreToolUse", #"{\#(base),"tool_name":"Bash","tool_input":{"command":"ls"}}"#))
        #expect(after.differsVisibly(from: before))
    }

    @Test func newAndEndedSessionsAreVisible() {
        let empty = AgentBoard()
        var one = empty
        one.apply(hook("SessionStart", "{\(base)}"))
        #expect(one.differsVisibly(from: empty) && empty.differsVisibly(from: one))
    }

    @Test func theHostAppearingIsVisible() {
        var before = AgentBoard()
        before.apply(hook("SessionStart", "{\(base)}"))
        var after = before
        after.setHost("Ghostty", session: "s1")
        #expect(after.differsVisibly(from: before))
    }
}

@Suite("Antigravity hooks")
struct AntigravityHookTests {
    let base = #""conversationId":"a1","workspacePaths":["/Users/me/work"],"lastUserInput":"Fix the build""#

    @Test func eventsAndPayload() {
        let start = hook("SessionStart", provider: "antigravity", "{\(base)}")
        #expect(start.event == "SessionStart" && start.sessionID == "a1" && start.cwd == "/Users/me/work")
        #expect(start.provider == "antigravity")

        let first = hook("PreInvocation", provider: "antigravity", #"{\#(base),"invocationNum":0}"#)
        #expect(first.event == "UserPromptSubmit" && first.payload["prompt"] as? String == "Fix the build")
        let later = hook("PreInvocation", provider: "antigravity", #"{\#(base),"invocationNum":1}"#)
        #expect(later.event == "PreInvocation")
        #expect(hook("PostInvocation", provider: "antigravity", "{\(base)}").event == "PostInvocation")
    }

    @Test func toolsBecomeClaudeTools() {
        let command = hook("PreToolUse", provider: "antigravity",
                           #"{\#(base),"toolCall":{"name":"run_command","args":{"CommandLine":"npm test","toolSummary":"Run tests"}}}"#)
        #expect(command.toolName == "Bash" && command.toolInput["command"] as? String == "npm test")
        #expect(command.toolInput["description"] as? String == "Run tests")

        let read = hook("PreToolUse", provider: "antigravity",
                        #"{\#(base),"toolCall":{"name":"read_file","args":{"Path":"/Users/me/work/Main.swift"}}}"#)
        #expect(read.toolName == "Read" && read.toolInput["file_path"] as? String == "/Users/me/work/Main.swift")

        let write = hook("PreToolUse", provider: "antigravity",
                         #"{\#(base),"toolCall":{"name":"write_file","args":{"Path":"/Users/me/work/README.md"}}}"#)
        #expect(write.toolName == "Write" && write.toolInput["file_path"] as? String == "/Users/me/work/README.md")
    }

    @Test func sessionLifecycle() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", provider: "antigravity", "{\(base)}"))
        #expect(board.sessions.first?.agent == "Antigravity" && board.sessions.first?.project == "work")

        board.apply(hook("PreInvocation", provider: "antigravity", #"{\#(base),"invocationNum":0}"#))
        #expect(board.sessions[0].state == .working("Thinking") && board.sessions[0].task == "Fix the build")

        board.apply(hook("PreToolUse", provider: "antigravity",
                         #"{\#(base),"toolCall":{"name":"run_command","args":{"CommandLine":"npm test","toolSummary":"Run tests"}}}"#))
        #expect(board.sessions[0].state == .working("Bash: Run tests"))

        board.apply(hook("PostToolUse", provider: "antigravity",
                         #"{\#(base),"toolCall":{"name":"run_command","args":{"CommandLine":"npm test","toolSummary":"Run tests"}}}"#))
        #expect(board.sessions[0].state == .working("Thinking"))

        board.apply(hook("Stop", provider: "antigravity", "{\(base)}"))
        #expect(board.sessions[0].state == .done && board.activeAgents.isEmpty)
    }

    @Test func antigravityComesAfterCopilot() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", pid: 8, #"{"session_id":"k1","cwd":"/x/notchboard"}"#))
        board.apply(hook("userPromptSubmitted", provider: "copilot", pid: 8, #"{"sessionId":"c1","cwd":"/x/shop"}"#))
        board.apply(hook("PreInvocation", provider: "antigravity", pid: 8,
                         #"{"conversationId":"a1","workspacePaths":["/x/work"],"lastUserInput":"Go","invocationNum":0}"#))
        #expect(board.activeAgents.map(\.agent) == ["Claude Code", "Copilot CLI", "Antigravity"])
        #expect(AgentBoard.agentName("antigravity") == "Antigravity")
    }
}

@Suite("Antigravity hook settings")
struct AntigravitySettingsTests {
    @Test func fileShape() throws {
        let file = HookSettings.antigravityFile(script: "/Users/me/Library/Application Support/Visor/agent-hook.sh")
        let entry = try #require(file["visor"] as? [String: Any])
        #expect(Set(entry.keys) == Set(HookSettings.antigravityEvents))

        let groups = try #require(entry["PreToolUse"] as? [[String: Any]])
        let group = try #require(groups.first)
        #expect(group["matcher"] as? String == "*")
        let hooks = try #require(group["hooks"] as? [[String: Any]])
        let hook = try #require(hooks.first)
        #expect((hook["command"] as? String)?.hasSuffix("antigravity PreToolUse") == true)
        #expect(hook["timeout"] as? Int == 5)

        let stop = try #require(entry["Stop"] as? [[String: Any]])
        #expect((stop.first?["command"] as? String)?.hasSuffix("antigravity Stop") == true)
        #expect(stop.first?["hooks"] == nil)
    }

    @Test func installKeepsOtherHooks() {
        let existing: [String: Any] = ["mine": ["Stop": [["command": "echo hi"]]]]
        let script = "/Users/me/Library/Application Support/Visor/agent-hook.sh"
        let merged = HookSettings.installAntigravity(into: existing, script: script)
        #expect(merged["mine"] != nil && merged["visor"] != nil)
        #expect(HookSettings.isAntigravityInstalled(merged))

        let removed = HookSettings.uninstallAntigravity(from: merged)
        #expect(removed["mine"] != nil && removed["visor"] == nil)
    }

    @Test func doesNotTouchAUsersVisorKey() {
        let existing: [String: Any] = ["visor": ["Stop": [["command": "echo mine"]]]]
        #expect(!HookSettings.isAntigravityInstalled(existing))
        #expect(HookSettings.uninstallAntigravity(from: existing)["visor"] != nil)
    }
}

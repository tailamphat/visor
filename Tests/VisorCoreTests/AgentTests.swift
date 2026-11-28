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
        #expect(AgentBoard.agentName("aider") == "Aider" && AgentBoard.agentName("claude") == "Claude Code")
    }

    @Test func atMostTwoMarksThenMore() {
        var board = AgentBoard()
        (start("claude", "a") + start("claude", "b")).forEach { board.apply($0) }
        var marks = NotchMarks.make(board, approvalsFrom: [])
        #expect(marks.shown == [.init(agent: "Claude Code", count: 2, attention: nil)] && marks.more.isEmpty)

        (start("copilot", "c") + start("aider", "d")).forEach { board.apply($0) }
        marks = NotchMarks.make(board, approvalsFrom: [])
        #expect(marks.shown.map(\.agent) == ["Claude Code", "Copilot CLI"] && marks.more == ["Aider"])

        start("aider", "d", waiting: true).forEach { board.apply($0) }
        marks = NotchMarks.make(board, approvalsFrom: [])
        #expect(marks.shown.first == .init(agent: "Aider", count: 1, attention: .question) && marks.more == ["Copilot CLI"])
    }

    @Test func openApprovalCountsAsWaiting() {
        var board = AgentBoard()
        start("claude", "a").forEach { board.apply($0) }
        #expect(NotchMarks.make(board, approvalsFrom: ["Claude Code"]).shown.first?.waiting == true)
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
        let file = HookSettings.installAntigravity(into: [:], script: "/Users/me/Library/Application Support/Visor/agent-hook.sh")
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

@Suite("Agent board: session cost")
struct AgentCostTests {
    let base = #""session_id":"s1","cwd":"/Users/me/workspace/notchboard""#

    @Test func costLabelOnlyWithReading() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", "{\(base)}"))
        #expect(board.sessions[0].cost == nil)
        board.setCost(SessionCost(dollars: 0.86, tokens: 3000), session: "s1")
        #expect(board.sessions[0].cost?.label == "$0.86")
        board.setCost(SessionCost(dollars: 9, tokens: 1), session: "nope")
        #expect(board.sessions.count == 1 && board.sessions[0].cost?.label == "$0.86")
    }

    @Test func costChangesVisiblyOnlyWhenLabelChanges() {
        var a = AgentBoard()
        a.apply(hook("SessionStart", "{\(base)}"))
        var b = a
        b.setCost(SessionCost(dollars: 0.861, tokens: 1), session: "s1")
        #expect(b.differsVisibly(from: a), "nil to $0.86")
        var c = b
        c.setCost(SessionCost(dollars: 0.862, tokens: 2), session: "s1")
        #expect(!c.differsVisibly(from: b), "same cent")
        c.setCost(SessionCost(dollars: 0.87, tokens: 3), session: "s1")
        #expect(c.differsVisibly(from: b))
    }

    @Test func restoredSessionDropsCost() throws {
        var board = AgentBoard()
        board.apply(hook("SessionStart", "{\(base)}"))
        board.setCost(SessionCost(dollars: 4, tokens: 1), session: "s1")
        let restored = try AgentBoard.restored(from: board.saved()) { _ in true }
        #expect(restored.sessions.count == 1 && restored.sessions[0].cost == nil)
    }

    @Test func oldSavedSessionsLoadWithoutCost() throws {
        var board = AgentBoard()
        board.apply(hook("SessionStart", "{\(base)}"))
        var object = try #require(JSONSerialization.jsonObject(with: board.saved()) as? [[String: Any]])
        object[0]["cost"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        let restored = AgentBoard.restored(from: data) { _ in true }
        #expect(restored.sessions.count == 1 && restored.sessions[0].cost == nil)
    }

    private func reply(_ at: Date, model: String = "claude-opus-4-5") -> TokenUsage {
        TokenUsage(model: model, timestamp: at, input: 10, cacheWrite5m: 1000, cacheRead: 5000)
    }

    /// What the cost read says of the turn: the newest prompt entry (stamp and count) and whether the reply follows it.
    private func turn(_ at: Date, _ index: Int, after: Bool = true) -> TurnReply {
        TurnReply(promptAt: at, promptIndex: index, replyAfterPrompt: after)
    }

    @Test func quickTurnReplyShowsCacheLine() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: t0.addingTimeInterval(0.4))
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(0.9))
        // Stamped in the same second as the prompt, before Visor got the hook.
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0), turn: turn(t0, 1), session: "s1")
        #expect(board.sessions[0].showsCacheLine, "same second")
        // Stamped 0.9 s before turnStart, but after the prompt in the transcript.
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(-0.5)), turn: turn(t0, 1), session: "s1")
        #expect(board.sessions[0].showsCacheLine, "0.9 s before turnStart")
    }

    // I3 QA case 8: replies 0.5 s and 1 s after the prompt (whole-second stamps or not) show the line.
    @Test func qaCase8RepliesHalfAndOneSecondAfterPrompt() {
        let t0 = Date(timeIntervalSince1970: 1000.7)
        for (delay, whole) in [(0.5, false), (1.0, false), (0.5, true), (1.0, true)] {
            var board = AgentBoard()
            board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: t0.addingTimeInterval(0.05))
            board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(delay + 0.1))
            var at = t0.addingTimeInterval(delay)
            if whole { at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down)) }
            let prompt = whole ? Date(timeIntervalSince1970: 1000) : t0
            board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(at), turn: turn(prompt, 1), session: "s1")
            #expect(board.sessions[0].showsCacheLine, "\(delay) s, whole seconds \(whole)")
        }
    }

    // I3 QA case 13: no readable prompt entry (only an assistant reply in the transcript): no line.
    @Test func qaCase13OnlyAReplyNoLine() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: t0)
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(2))
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(1)), turn: nil, session: "s1")
        #expect(!board.sessions[0].showsCacheLine)
    }

    @Test func lateReadOfPreviousReplyStaysHidden() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: t0)
        #expect(board.sessions[0].promptReply == nil)
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(5))
        // A, from before this prompt, read late: the transcript says it comes before the prompt.
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(-30)), turn: turn(t0, 3, after: false), session: "s1")
        #expect(!board.sessions[0].showsCacheLine)
        let b = reply(t0)
        board.setCost(SessionCost(dollars: 2, tokens: 2), lastReply: b, turn: turn(t0, 3), session: "s1")
        #expect(board.sessions[0].showsCacheLine && board.sessions[0].lastReply == b)
        // Restored or started before launch: an old reply and nothing read of its prompt yet.
        var restored = board.sessions[0]
        restored.replyTurn = nil
        restored.promptReply = nil
        restored.lastReply = reply(t0.addingTimeInterval(-3600))
        #expect(!restored.showsCacheLine)
    }

    @Test func queuedPromptPreviousReplyStaysHidden() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"one\"}"), now: t0.addingTimeInterval(-10))
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(-9)), turn: turn(t0.addingTimeInterval(-10), 1), session: "s1")
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(-1))
        // Reply A stamped t0 - 0.5 s, its read pending; the queued prompt fires at t0 + 0.2 s.
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"two\"}"), now: t0.addingTimeInterval(0.2))
        let a = reply(t0.addingTimeInterval(-0.5))
        board.setCost(SessionCost(dollars: 2, tokens: 2), lastReply: a, turn: turn(t0.addingTimeInterval(-10), 1), session: "s1")
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(1))
        #expect(!board.sessions[0].showsCacheLine, "A's read saw only prompt 1")
        board.setCost(SessionCost(dollars: 2, tokens: 2), lastReply: a, turn: turn(t0, 2, after: false), session: "s1")
        #expect(!board.sessions[0].showsCacheLine, "A comes before prompt 2")
        let b = reply(t0.addingTimeInterval(0.8))
        board.setCost(SessionCost(dollars: 3, tokens: 3), lastReply: b, turn: turn(t0, 2), session: "s1")
        #expect(board.sessions[0].showsCacheLine)
    }

    @Test func queuedPromptInsideTheClockWindowStaysHidden() {
        // Prompt 1 stamped 0.6 s before turnStart: inside the 1 s window, so only the prompt count can tell.
        let t0 = Date(timeIntervalSince1970: 1000)
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"one\"}"), now: t0.addingTimeInterval(-0.7))
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(-3)), turn: turn(t0.addingTimeInterval(-5), 1, after: false), session: "s1")
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(-3)), turn: turn(t0.addingTimeInterval(-0.6), 2, after: false), session: "s1")
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"two\"}"), now: t0)
        // A read that saw only prompt 2 (stamped t0 - 0.6 s) lands after prompt 3 was submitted.
        board.setCost(SessionCost(dollars: 2, tokens: 2), lastReply: reply(t0.addingTimeInterval(-0.3)), turn: turn(t0.addingTimeInterval(-0.6), 2), session: "s1")
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(0.5))
        #expect(!board.sessions[0].showsCacheLine)
    }

    @Test func noPromptEntryHidesCacheLine() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: t0)
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(5))
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(3)), session: "s1")
        #expect(!board.sessions[0].showsCacheLine)
    }

    @Test func turnArrivingLaterDiffersVisibly() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var a = AgentBoard()
        a.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: t0)
        a.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(5))
        a.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(3)), session: "s1")
        var b = a
        b.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(3)), turn: turn(t0, 1), session: "s1")
        #expect(b.differsVisibly(from: a))
    }

    @Test func savedSessionWithoutReplyTurnLoads() throws {
        let t0 = Date(timeIntervalSince1970: 1000)
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: t0)
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0), turn: turn(t0, 4), session: "s1")
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"again\"}"), now: t0.addingTimeInterval(9))
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0), turn: turn(t0.addingTimeInterval(9), 5, after: false), session: "s1")
        let kept = AgentBoard.restored(from: try board.saved()) { _ in true }
        #expect(kept.sessions.first?.replyTurn == board.sessions[0].replyTurn && kept.sessions.first?.promptSeen == 4)
        #expect(kept.sessions.first?.promptReply == reply(t0))
        var object = try #require(JSONSerialization.jsonObject(with: board.saved()) as? [[String: Any]])
        for key in ["replyTurn", "promptSeen", "promptReply"] { object[0][key] = nil }
        let old = AgentBoard.restored(from: try JSONSerialization.data(withJSONObject: object)) { _ in true }
        #expect(old.sessions.count == 1 && old.sessions[0].replyTurn == nil && old.sessions[0].promptSeen == nil && old.sessions[0].promptReply == nil)
    }

    @Test func cacheLineShowsOnlyOnFinishedClaudeWithReply() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: t0)
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(t0.addingTimeInterval(5)), turn: turn(t0, 1), session: "s1")
        #expect(!board.sessions[0].showsCacheLine, "working")
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(10))
        #expect(board.sessions[0].showsCacheLine, "finished with a reply")
        var s = board.sessions[0]
        for state in [AgentState.idle, .working("x"), .needsApproval("x"), .asking("x"), .needsInput] {
            s.state = state
            #expect(!s.showsCacheLine, "\(state)")
        }
        s = board.sessions[0]
        s.agent = "Antigravity"
        #expect(!s.showsCacheLine, "not Claude Code")
        s = board.sessions[0]
        s.lastReply = nil
        #expect(!s.showsCacheLine, "no reply")
        s.lastReply = reply(t0.addingTimeInterval(5), model: "gpt-unknown")
        #expect(!s.showsCacheLine, "unpriced")
        s = board.sessions[0]
        s.replyTurn = turn(t0, 1, after: false)
        #expect(!s.showsCacheLine, "stale: the reply comes before this turn's prompt")
        s.replyTurn = nil
        #expect(!s.showsCacheLine, "no prompt entry read")
    }

    @Test func setCostKeepsLastReply() {
        var board = AgentBoard()
        board.apply(hook("SessionStart", "{\(base)}"))
        let r = reply(Date(timeIntervalSince1970: 50))
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: r, session: "s1")
        #expect(board.sessions[0].lastReply == r && board.sessions[0].cost?.label == "$1.00")
        board.setCost(SessionCost(dollars: 2, tokens: 1), lastReply: reply(.distantPast), session: "nope")
        #expect(board.sessions[0].lastReply == r)
    }

    @Test func lastReplyChangeDiffersVisibly() {
        var a = AgentBoard()
        a.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: Date(timeIntervalSince1970: 10))
        a.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(Date(timeIntervalSince1970: 20)), turn: TurnReply(promptAt: Date(timeIntervalSince1970: 10), promptIndex: 1, replyAfterPrompt: true), session: "s1")
        var working = a
        working.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(Date(timeIntervalSince1970: 40)), turn: TurnReply(promptAt: Date(timeIntervalSince1970: 10), promptIndex: 1, replyAfterPrompt: true), session: "s1")
        #expect(!working.differsVisibly(from: a), "mid-turn reply: no line shows")
        a.apply(hook("Stop", "{\(base)}"), now: Date(timeIntervalSince1970: 60))
        a.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(Date(timeIntervalSince1970: 50)), turn: TurnReply(promptAt: Date(timeIntervalSince1970: 10), promptIndex: 1, replyAfterPrompt: true), session: "s1")
        var b = a
        b.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(Date(timeIntervalSince1970: 50)), turn: TurnReply(promptAt: Date(timeIntervalSince1970: 10), promptIndex: 1, replyAfterPrompt: true), session: "s1")
        #expect(!b.differsVisibly(from: a), "same reply")
        b.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(Date(timeIntervalSince1970: 90)), turn: TurnReply(promptAt: Date(timeIntervalSince1970: 10), promptIndex: 1, replyAfterPrompt: true), session: "s1")
        #expect(b.differsVisibly(from: a), "a new reply")
    }

    @Test func freshReplyAfterStopDiffersVisibly() {
        // Finished, but the stored reply is from the turn before: no line yet.
        var a = AgentBoard()
        a.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"go\"}"), now: Date(timeIntervalSince1970: 100))
        a.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(Date(timeIntervalSince1970: 50)), turn: TurnReply(promptAt: Date(timeIntervalSince1970: 100), promptIndex: 1, replyAfterPrompt: false), session: "s1")
        a.apply(hook("Stop", "{\(base)}"), now: Date(timeIntervalSince1970: 130))
        #expect(!a.sessions[0].showsCacheLine)
        var b = a
        b.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: reply(Date(timeIntervalSince1970: 125)), turn: TurnReply(promptAt: Date(timeIntervalSince1970: 100), promptIndex: 1, replyAfterPrompt: true), session: "s1")
        #expect(b.sessions[0].showsCacheLine && b.differsVisibly(from: a))
    }

    @Test func cacheRowsCountsPairs() {
        let t0 = Date(timeIntervalSince1970: 1000)
        func card(_ id: String, line: Bool) -> AgentSession {
            var s = AgentSession(id: id, agent: "Claude Code", cwd: "/Users/me/\(id)", state: line ? .done : .working("x"), since: t0)
            s.lastReply = reply(t0)
            s.replyTurn = TurnReply(promptAt: t0, promptIndex: 1, replyAfterPrompt: true)
            return s
        }
        let l = card("a", line: true), n = card("b", line: false)
        #expect(AgentBoard.cacheRows([]) == 0)
        #expect(AgentBoard.cacheRows([l, n, n]) == 1)
        #expect(AgentBoard.cacheRows([n, l]) == 1)
        #expect(AgentBoard.cacheRows([l, l, l]) == 2)
        #expect(AgentBoard.cacheRows([n, n, n]) == 0)
        #expect(AgentBoard.cacheRowTall([n, l, n], index: 0) && AgentBoard.cacheRowTall([n, l, n], index: 1))
        #expect(!AgentBoard.cacheRowTall([n, l, n], index: 2))
    }

    @Test func agentsHeightCountsCacheRows() {
        #expect(NotchEars.cacheLine == 14)
        #expect(NotchEars.agentsGrid(groupSizes: [2], cacheRows: 1) == NotchEars.agentsGrid(groupSizes: [2]) + 14)
        #expect(NotchEars.agentsDigest(cards: 2, idleLines: 0, cacheRows: 1) == NotchEars.agentsDigest(cards: 2, idleLines: 0) + 14)
    }

    @Test func digestDropsARowWhenCacheLinesWouldOverflow() {
        // QA 13: nine finished sessions, every card with its cache line.
        let t0 = Date()
        let sessions = (1...9).map { n -> AgentSession in
            var s = AgentSession(id: "s\(n)", agent: "Claude Code", cwd: "/Users/me/p\(n)", state: .done, since: t0.addingTimeInterval(Double(-n)))
            s.lastReply = reply(t0.addingTimeInterval(-100))
            s.replyTurn = TurnReply(promptAt: t0, promptIndex: 1, replyAfterPrompt: true)
            return s
        }
        let digest = AgentsDigest(sessions: sessions)
        #expect(digest.capped && digest.top.count == 6 && digest.more == 3)
        // Never taller than the eight plain cards it replaces.
        #expect(NotchEars.cardRows(cards: digest.top.count, cacheRows: AgentBoard.cacheRows(digest.top))
                <= NotchEars.cardRows(cards: 8, cacheRows: 0))
        let tall = NotchEars.agentsDigest(cards: digest.top.count, idleLines: digest.idle.count, cacheRows: AgentBoard.cacheRows(digest.top))
        #expect(tall <= NotchEars.agentsDigest(cards: 8, idleLines: digest.idle.count))
        // Without cache lines the eight stay.
        let plain = sessions.map { s -> AgentSession in var s = s; s.lastReply = nil; return s }
        #expect(AgentsDigest(sessions: plain).top.count == 8)
    }

    /// Eight finished Claude Code sessions, every card with its cache line (four tall rows).
    private func eightWithLines() -> [AgentSession] {
        let t0 = Date()
        return (1...8).map { n -> AgentSession in
            var s = AgentSession(id: "s\(n)", agent: "Claude Code", cwd: "/Users/me/p\(n)", state: .done, since: t0.addingTimeInterval(Double(-n)))
            s.lastReply = reply(t0.addingTimeInterval(-100))
            s.replyTurn = TurnReply(promptAt: t0, promptIndex: 1, replyAfterPrompt: true)
            return s
        }
    }

    /// The room under a 32 pt notch: 402 - 32 - 8 - 18.
    private let panelRoom = 344.0

    // Epic QA finding 1: the away card (74 + 6) above eight cards with cache lines.
    @Test func digestFoldsWhenRoomIsShort() {
        let sessions = eightWithLines()
        #expect(NotchEars.agentsList(sessions: sessions) > panelRoom - 80, "the full grid would be cut")
        let digest = AgentsDigest(sessions: sessions, room: panelRoom - 80)
        #expect(digest.capped && digest.top.count % 2 == 0 && digest.more >= 2)
        #expect(digest.top.count + digest.more == 8)
        let height = NotchEars.agentsDigest(cards: digest.top.count, idleLines: digest.idle.count,
                                            cacheRows: AgentBoard.cacheRows(digest.top))
        #expect(height <= panelRoom - 80)
    }

    @Test func digestTrimsWholeRowsToRoom() {
        let sessions = eightWithLines()
        let helpers = AgentsDigest(sessions: sessions, room: panelRoom - 150)
        let away = AgentsDigest(sessions: sessions, room: panelRoom - 80)
        #expect(helpers.capped && helpers.top.count < away.top.count && helpers.top.count % 2 == 0)
        #expect(NotchEars.agentsDigest(cards: helpers.top.count, idleLines: helpers.idle.count,
                                       cacheRows: AgentBoard.cacheRows(helpers.top)) <= panelRoom - 150)
        // Never below one row: past that the list scrolls.
        #expect(AgentsDigest(sessions: sessions, room: 10).top.count == 2)
        // Seven sessions: the odd last card goes alone.
        let seven = AgentsDigest(sessions: Array(sessions.prefix(7)), room: panelRoom - 80)
        #expect(seven.capped && seven.top.count + seven.more == 7)
    }

    @Test func digestKeepsGridWhenItFits() {
        let sessions = eightWithLines()
        let open = AgentsDigest(sessions: sessions, room: panelRoom)
        #expect(!open.capped && open.top.count == 8 && open.more == 0, "after Got it")
        #expect(AgentsDigest(sessions: sessions) == AgentsDigest(sessions: sessions, room: .infinity), "no room: today's rule")
        // A fold that would hide nothing is no fold.
        let two = AgentsDigest(sessions: Array(sessions.prefix(2)), room: 10)
        #expect(!two.capped && two.more == 0)
    }

    @Test func agentsListIsTheGroupedGrid() {
        var sessions = eightWithLines()
        sessions[7].agent = "Copilot CLI"
        sessions[7].lastReply = nil
        let groups = AgentBoard.groups(sessions)
        #expect(groups.map(\.agent) == ["Claude Code", "Copilot CLI"])
        let tall = groups.reduce(0) { $0 + AgentBoard.cacheRows($1.sessions) }
        #expect(NotchEars.agentsList(sessions: sessions)
                == NotchEars.agentsGrid(groupSizes: groups.map(\.sessions.count), cacheRows: tall))
    }

    // Epic QA case 14: a quick repeat never shows the old reply, then shows the newest once.
    @Test func newPromptHidesLineUntilNewestReply() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"one\"}"), now: t0)
        let a = reply(t0.addingTimeInterval(3))
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: a, turn: TurnReply(promptAt: t0, promptIndex: 1, replyAfterPrompt: true), session: "s1")
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(5))
        #expect(board.sessions[0].showsCacheLine)
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"two\"}"), now: t0.addingTimeInterval(6))
        #expect(!board.sessions[0].showsCacheLine, "working")
        board.apply(hook("Stop", "{\(base)}"), now: t0.addingTimeInterval(9))
        #expect(!board.sessions[0].showsCacheLine, "the new reply is not read yet")
        let b = reply(t0.addingTimeInterval(8))
        board.setCost(SessionCost(dollars: 2, tokens: 2), lastReply: b, turn: TurnReply(promptAt: t0.addingTimeInterval(6), promptIndex: 2, replyAfterPrompt: true), session: "s1")
        #expect(board.sessions[0].showsCacheLine && board.sessions[0].lastReply == b)
    }

    @Test func savedSessionWithoutLastReplyLoads() throws {
        var board = AgentBoard()
        board.apply(hook("SessionStart", "{\(base)}"))
        let r = reply(Date(timeIntervalSince1970: 50))
        board.setCost(SessionCost(dollars: 1, tokens: 1), lastReply: r, session: "s1")
        let kept = AgentBoard.restored(from: try board.saved()) { _ in true }
        #expect(kept.sessions.first?.lastReply == r, "round-trips")
        var object = try #require(JSONSerialization.jsonObject(with: board.saved()) as? [[String: Any]])
        object[0]["lastReply"] = nil
        let old = AgentBoard.restored(from: try JSONSerialization.data(withJSONObject: object)) { _ in true }
        #expect(old.sessions.count == 1 && old.sessions[0].lastReply == nil)
    }

}

@Suite("Agents panel")
struct AgentsPanelTests {
    /// The room under a 32 pt notch: 402 - 32 - 8 - 18.
    let maxContent = 344.0

    /// Finished Claude Code sessions with a reply each, so every card has its cache line;
    /// `lastEvent` falls with n, so the grid shows them in order s1, s2, ...
    func finished(_ count: Int, lines: Bool = true) -> [AgentSession] {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        return (1...count).map { n -> AgentSession in
            let at = t0.addingTimeInterval(Double(-n))
            var s = AgentSession(id: "s\(n)", agent: "Claude Code", cwd: "/Users/me/p\(n)", state: .done, since: at)
            if lines {
                s.lastReply = TokenUsage(model: "claude-opus-4-5", timestamp: at, input: 10, cacheWrite5m: 1000, cacheRead: 5000)
                s.replyTurn = TurnReply(promptAt: at, promptIndex: 1, replyAfterPrompt: true)
            }
            return s
        }
    }

    @Test func connectButtonIsItsDrawnHeight() {
        #expect(AgentsPanel.connectButton == 6 + 4 + 28, "spacing, top padding, PillButton")
        #expect(AgentsPanel.showFewer == 6 + 26)
    }

    @Test func extrasCountEveryBannerOnce() {
        let sessions = finished(2)
        let extras = AgentsPanelExtras(banners: 80, connect: true, helpers: "s1", helpersHeight: 100)
        let digest = AgentsPanel.digest(sessions: sessions, maxContent: maxContent, extras: extras)
        #expect(!digest.capped)
        #expect(AgentsPanel.contentHeight(digest: digest, extras: extras, showAll: false)
                == NotchEars.agentsList(sessions: sessions) + 80 + 100 + AgentsPanel.connectButton)
    }

    // Reviewer 1: helpers opened on the last card in grid order keep their card.
    @Test func helpersSessionStaysInTop() {
        let sessions = finished(8)
        let extras = AgentsPanelExtras(banners: 0, connect: false, helpers: "s8", helpersHeight: 120)
        let digest = AgentsPanel.digest(sessions: sessions, maxContent: maxContent, extras: extras)
        #expect(digest.capped && digest.top.contains { $0.id == "s8" })
        #expect(AgentsPanel.contentHeight(digest: digest, extras: extras, showAll: false) <= maxContent)
        // Folded by count too: the helpers' card is kept.
        let many = AgentsPanel.digest(sessions: finished(12, lines: false), maxContent: maxContent,
                                      extras: AgentsPanelExtras(helpers: "s12", helpersHeight: 60))
        #expect(many.capped && many.top.contains { $0.id == "s12" })
    }

    // Reviewer 2: Connect only counts where it is drawn, at its drawn height.
    @Test func connectCountsOnlyInTheGrid() {
        let sessions = finished(6)
        let grid = NotchEars.agentsList(sessions: sessions)
        let tight = maxContent - grid - 34  // room for 32 but not 38
        let extras = AgentsPanelExtras(banners: tight, connect: true)
        let digest = AgentsPanel.digest(sessions: sessions, maxContent: maxContent, extras: extras)
        #expect(AgentsPanel.contentHeight(digest: digest, extras: extras, showAll: false) <= maxContent)
        // Folded by count, the Connect button isn't drawn, so it takes no room.
        let nine = finished(9)
        let with = AgentsPanel.digest(sessions: nine, maxContent: maxContent, extras: AgentsPanelExtras(banners: 80, connect: true))
        let without = AgentsPanel.digest(sessions: nine, maxContent: maxContent, extras: AgentsPanelExtras(banners: 80))
        #expect(with == without)
    }

    // Reviewer 3: a fold that isn't shorter than the grid keeps the grid.
    @Test func digestNeverTallerThanGrid() {
        let idle = (1...3).map { n in AgentSession(id: "i\(n)", agent: "Claude Code", cwd: "/Users/me/i\(n)", state: .idle) }
        #expect(NotchEars.agentsList(sessions: idle) == 137)
        let digest = AgentsPanel.digest(sessions: idle, maxContent: 136, extras: AgentsPanelExtras())
        #expect(!digest.capped && digest.top.count == 3)
    }

    // Reviewer 4: folded by room alone, the cards keep the grid's order.
    @Test func roomFoldKeepsGridOrder() {
        var sessions = finished(8)
        sessions[5].since = Date(timeIntervalSince1970: 2_000_000)  // most recent by `since`, sixth in the grid
        let digest = AgentsPanel.digest(sessions: sessions, maxContent: maxContent, extras: AgentsPanelExtras(banners: 80))
        #expect(digest.capped && !digest.top.isEmpty)
        let grid = AgentBoard.groups(sessions).flatMap(\.sessions)
        #expect(digest.top.map(\.id) == Array(grid.prefix(digest.top.count)).map(\.id))
    }

    // I3 QA finding: with two things above the list, the minimum fold (one row) still can't fit.
    // These are capacity limits, not miscounts: every height below is what the views draw
    // (measured on the QA screenshots to within 1 pt), and the list scrolls the rest.
    @Test func qaOverflowsAreCapacityNotMiscounts() {
        let banner = DesignComponents.Banner.height(rows: [16, 15, 18], spacing: 3)  // away card, Stuck: 75
        let handoff = DesignComponents.Banner.height(rows: [16, 14, 14, 18], spacing: 3)  // two targets: 91
        let harnessLine: Double = 32  // gap and line
        let helpers: Double = HelperWaterfall.height(rows: 4) + 6  // three helpers and the main row
        let xrayList: Double = 156  // gap 6, padding 12, header 16, four 22 pt rows, "+6 more" 16, the key 18
        #expect(banner == 75 && handoff == 91)
        let sessions = finished(8)
        let cases: [(String, AgentsPanelExtras, [AgentSession])] = [
            ("away + Stuck", AgentsPanelExtras(banners: 2 * (banner + 6) + harnessLine), sessions),
            ("handoff + Stuck", AgentsPanelExtras(banners: handoff + 6 + banner + 6 + harnessLine), sessions),
            ("away + helpers", AgentsPanelExtras(banners: banner + 6 + harnessLine, helpers: "s1", helpersHeight: helpers), sessions),
            ("X-ray, 12 sessions", AgentsPanelExtras(banners: harnessLine + xrayList), finished(12)),
        ]
        for (name, extras, list) in cases {
            let digest = AgentsPanel.digest(sessions: list, maxContent: maxContent, extras: extras)
            #expect(digest.capped && digest.top.count == 2, "\(name): folded to its one-row minimum")
            #expect(AgentsPanel.contentHeight(digest: digest, extras: extras, showAll: false) > maxContent, "\(name): can't fit, scrolls")
        }
    }

    // I3 QA case 6: the card with the open helpers list stays, first or last, with 8 or 12 sessions.
    @Test func qaCase6HelpersCardKeptFirstAndLast() {
        for count in [8, 12] {
            let sessions = finished(count)
            for id in ["s1", "s\(count)"] {
                let extras = AgentsPanelExtras(banners: 80, helpers: id, helpersHeight: 100)
                let digest = AgentsPanel.digest(sessions: sessions, maxContent: maxContent, extras: extras)
                #expect(digest.top.contains { $0.id == id }, "\(count) sessions, helpers on \(id)")
                #expect(AgentsPanel.contentHeight(digest: digest, extras: extras, showAll: false) <= maxContent)
            }
        }
    }

    // I3 QA case 7: a fold is never taller than the grid, and a room-only fold keeps the grid's order.
    @Test func qaCase7FoldShorterAndInOrder() {
        for banners in stride(from: 0.0, through: 200, by: 10) {
            let sessions = finished(8)
            let extras = AgentsPanelExtras(banners: banners)
            let digest = AgentsPanel.digest(sessions: sessions, maxContent: maxContent, extras: extras)
            guard digest.capped else { continue }
            #expect(NotchEars.agentsDigest(cards: digest.top.count, idleLines: digest.idle.count, cacheRows: AgentBoard.cacheRows(digest.top))
                    < NotchEars.agentsList(sessions: sessions))
            let grid = AgentBoard.groups(sessions).flatMap(\.sessions).map(\.id)
            #expect(digest.top.map(\.id) == Array(grid.prefix(digest.top.count)))
        }
    }

    // Perf: the size and the list share one digest per input.
    @Test func memoBuildsOncePerInput() {
        let memo = AgentsPanel.Memo()
        let sessions = finished(8)
        let a = memo.digest(sessions: sessions, maxContent: maxContent, extras: AgentsPanelExtras(banners: 80))
        let b = memo.digest(sessions: sessions, maxContent: maxContent, extras: AgentsPanelExtras(banners: 80))
        #expect(a == b && memo.builds == 1)
        _ = memo.digest(sessions: sessions, maxContent: maxContent, extras: AgentsPanelExtras())
        #expect(memo.builds == 2)
        #expect(a.groups.map(\.agent) == AgentBoard.groups(sessions).map(\.agent))
    }
}

import Foundation
import Testing
@testable import VisorCore

/// One rollout line: {"timestamp","type","payload"}.
private func line(_ type: String, _ payload: [String: Any], at time: String = "2026-11-22T10:00:00.000Z") -> String {
    let object: [String: Any] = ["timestamp": time, "type": type, "payload": payload]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
}

private func rollout(_ lines: String...) -> Data { Data(lines.joined().utf8) }

private let meta = line("session_meta", ["id": "c0ffee", "cwd": "/Users/me/api"], at: "2026-11-22T09:59:00.000Z")
private let prompt = line("event_msg", ["type": "user_message", "message": "run the tests\nand fix them"], at: "2026-11-22T10:00:00.000Z")
private let shell = line("response_item", ["type": "function_call", "name": "shell",
                                           "arguments": #"{"command":["bash","-lc","go test ./..."]}"#], at: "2026-11-22T10:00:05.000Z")

private func date(_ text: String) -> Date { ISODate.parse(text)! }

@Suite("Codex sessions")
struct CodexSessionTests {
    @Test func readsProjectTaskAndActivity() throws {
        var reader = CodexRollout()
        reader.read(rollout(meta, prompt, shell))
        let session = try #require(reader.session)
        #expect(session.id == "c0ffee")
        #expect(session.agent == "Codex CLI")
        #expect(session.cwd == "/Users/me/api")
        #expect(session.task == "run the tests")
        #expect(session.state == .working("Bash: go test ./..."))
        #expect(session.turnStart == date("2026-11-22T10:00:00.000Z"))
        #expect(session.lastActivity == date("2026-11-22T10:00:05.000Z"))
    }

    @Test func describesShellAndPatchCalls() {
        #expect(CodexRollout.describe(name: "exec_command", arguments: ["cmd": "npm test"]) == "Bash: npm test")
        #expect(CodexRollout.describe(name: "local_shell", arguments: ["command": ["ls", "-la"]]) == "Bash: ls -la")
        let patch = "*** Begin Patch\n*** Update File: src/total.ts\n@@\n-a\n+b\n*** End Patch"
        #expect(CodexRollout.describe(name: "apply_patch", arguments: ["input": patch]) == "Edit: total.ts")
        #expect(CodexRollout.describe(name: "apply_patch", arguments: ["input": "*** Add File: docs/new.md\n+hi"]) == "Write: new.md")
        #expect(CodexRollout.describe(name: "update_plan", arguments: [:]) == "update_plan")
    }

    @Test func customPatchCallIsAnEdit() throws {
        var reader = CodexRollout()
        reader.read(rollout(meta, prompt, line("response_item", ["type": "custom_tool_call", "name": "apply_patch",
                                                                 "input": "*** Begin Patch\n*** Update File: /Users/me/api/main.go\n"])))
        #expect(try #require(reader.session).state == .working("Edit: main.go"))
    }

    @Test func readsOnlyNewLines() {
        var whole = CodexRollout()
        whole.read(rollout(meta, prompt, shell))
        var pieces = CodexRollout()
        pieces.read(rollout(meta))
        #expect(pieces.offset == UInt64(meta.utf8.count))
        pieces.read(rollout(prompt, shell))
        #expect(pieces.session == whole.session)
        #expect(pieces.offset == whole.offset)
    }

    @Test func halfLineWaits() throws {
        var reader = CodexRollout()
        let half = Data(shell.utf8).prefix(20)
        reader.read(rollout(meta, prompt) + half)
        #expect(try #require(reader.session).state == .working("Thinking"))
        #expect(reader.offset == UInt64((meta + prompt).utf8.count))
        reader.read(Data(shell.utf8))
        #expect(try #require(reader.session).state == .working("Bash: go test ./..."))
    }

    @Test func turnStatesFollowEvents() throws {
        var reader = CodexRollout()
        reader.read(rollout(meta, line("event_msg", ["type": "task_started"])))
        #expect(try #require(reader.session).state == .working("Thinking"))
        reader.read(rollout(prompt, shell, line("response_item", ["type": "function_call_output", "output": "ok"])))
        #expect(try #require(reader.session).state == .working("Thinking"))
        reader.read(rollout(line("event_msg", ["type": "task_complete", "last_agent_message": "All green. Commit now?"])))
        let done = try #require(reader.session)
        #expect(done.state == .done)
        #expect(done.askedForReply)
        reader.read(rollout(line("event_msg", ["type": "turn_aborted"])))
        #expect(try #require(reader.session).state == .idle)
    }

    @Test func fallsBackToFileID() throws {
        var reader = CodexRollout(id: "rollout-2026-11-22-abc")
        reader.read(rollout(prompt))
        #expect(try #require(reader.session).id == "rollout-2026-11-22-abc")
    }
}

/// One row as `sqlite3 -json` prints `OpenCodeSessions.query`.
private func openCodeRows(_ rows: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: rows)
}

private let created: Int64 = 1_795_000_000_000

private func row(_ id: String, dir: String = "/Users/me/docs", title: String = "Tidy the install guide",
                 role: String = "assistant", completed: Bool = false, finish: String? = nil, error: Bool = false,
                 part: String? = "reasoning", tool: String? = nil, status: String? = nil, input: [String: Any] = [:],
                 text: String? = nil, parent: String? = nil, archived: Int64? = nil) -> [String: Any] {
    var out: [String: Any] = ["id": id, "directory": dir, "title": title, "updated": created + 60_000,
                              "prompted": created, "role": role]
    if completed { out["completed"] = created + 50_000 }
    if let finish { out["finish"] = finish }
    if error { out["error"] = "ProviderAuthError" }
    if let part { out["ptype"] = part }
    if let tool { out["tool"] = tool }
    if let status { out["status"] = status }
    if !input.isEmpty { out["input"] = String(decoding: try! JSONSerialization.data(withJSONObject: input), as: UTF8.self) }
    if let text { out["text"] = text }
    if let parent { out["parent"] = parent }
    if let archived { out["archived"] = archived }
    return out
}

@Suite("OpenCode sessions")
struct OpenCodeSessionTests {
    @Test func parsesWorkingDoneAndAsking() throws {
        let data = openCodeRows([
            row("ses_read", part: "tool", tool: "read", status: "running", input: ["filePath": "/Users/me/docs/README.md"]),
            row("ses_done", dir: "/Users/me/infra", title: "Plan the move", completed: true, finish: "stop", part: "text", text: "Done. Ship it?"),
            row("ses_next", completed: true, finish: "tool-calls", part: "step-finish"),
            row("ses_ask", part: "tool", tool: "question", status: "running"),
            row("ses_user", role: "user", part: "text"),
            row("ses_fail", completed: true, error: true, part: "text"),
        ])
        let sessions = try #require(OpenCodeSessions.parse(data))
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        #expect(byID["ses_read"]?.state == .working("Read: README.md"))
        #expect(byID["ses_read"]?.agent == "OpenCode")
        #expect(byID["ses_read"]?.cwd == "/Users/me/docs")
        #expect(byID["ses_read"]?.task == "Tidy the install guide")
        #expect(byID["ses_read"]?.turnStart == Date(timeIntervalSince1970: TimeInterval(created) / 1000))
        #expect(byID["ses_read"]?.lastActivity == Date(timeIntervalSince1970: TimeInterval(created + 60_000) / 1000))
        #expect(byID["ses_done"]?.state == .done)
        #expect(byID["ses_done"]?.askedForReply == true)
        #expect(byID["ses_next"]?.state == .working("Thinking"))
        #expect(byID["ses_ask"]?.state == .asking("Question"))
        #expect(byID["ses_user"]?.state == .working("Thinking"))
        #expect(byID["ses_fail"]?.state == .idle)
    }

    @Test func mapsOpenCodeToolNames() {
        #expect(OpenCodeSessions.describe(tool: "bash", input: ["command": "npm test", "description": "Run tests"]) == "Bash: Run tests")
        #expect(OpenCodeSessions.describe(tool: "edit", input: ["filePath": "/Users/me/a/b.swift"]) == "Edit: b.swift")
        #expect(OpenCodeSessions.describe(tool: "grep", input: ["pattern": "TODO"]) == "Grep: TODO")
        #expect(OpenCodeSessions.describe(tool: "todowrite", input: [:]) == "todowrite")
    }

    @Test func skipsChildAndArchived() throws {
        let data = openCodeRows([row("ses_child", parent: "ses_x"), row("ses_old", archived: created)])
        #expect(try #require(OpenCodeSessions.parse(data)).isEmpty)
    }

    @Test func emptyOutputIsNoSessions() {
        #expect(OpenCodeSessions.parse(Data()) == [])
        #expect(OpenCodeSessions.parse(Data("not json".utf8)) == nil)
    }

    @Test func queryReadsNewestSessionInLiveFolders() {
        let query = OpenCodeSessions.query(since: Date(timeIntervalSince1970: 1_795_000_000), directories: ["/Users/me/it's"])
        #expect(query.contains("n.directory = '/Users/me/it''s'"))
        #expect(query.contains("OR s.id = (SELECT n.id FROM session n"))
        #expect(query.contains("LIMIT 21"))
    }

    @Test func queryIsReadOnlySelect() {
        let query = OpenCodeSessions.query(since: Date(timeIntervalSince1970: 1_795_000_000))
        #expect(query.hasPrefix("SELECT"))
        #expect(!query.contains(";"))
        #expect(query.contains("parent_id IS NULL"))
        #expect(query.contains("time_archived IS NULL"))
        #expect(query.contains("time_updated >= 1795000000000"))
        for word in ["INSERT", "UPDATE ", "DELETE", "DROP", "PRAGMA", "ATTACH"] { #expect(!query.uppercased().contains(word)) }
    }
}

private let now = Date(timeIntervalSince1970: 1_795_000_000)

private func scanned(_ id: String, agent: String = "OpenCode", cwd: String = "/Users/me/docs", state: AgentState,
                     ago: TimeInterval = 0, turnStart: TimeInterval? = nil) -> ScannedSession {
    ScannedSession(id: id, agent: agent, cwd: cwd, state: state, task: "Tidy", turnStart: turnStart.map { now.addingTimeInterval(-$0) },
                   lastActivity: now.addingTimeInterval(-ago))
}

@Suite("File agents")
struct FileAgentTests {
    @Test func syncKeepsHookSessions() {
        var board = AgentBoard()
        var start = HookMessage(event: "SessionStart", pid: 7, payload: ["session_id": "claude-1", "cwd": "/Users/me/web-shop"])
        start.provider = "claude"
        board.apply(start, now: now)
        _ = board.sync(agent: "OpenCode", scanned: [scanned("ses_1", state: .working("Thinking"))])
        #expect(board.sessions.map(\.id) == ["claude-1", "ses_1"])
        _ = board.sync(agent: "OpenCode", scanned: [])
        #expect(board.sessions.map(\.id) == ["claude-1"])
    }

    @Test func syncReportsFinishedTurns() throws {
        var board = AgentBoard()
        #expect(board.sync(agent: "OpenCode", scanned: [scanned("ses_1", state: .done)]).isEmpty)
        #expect(board.sync(agent: "OpenCode", scanned: [scanned("ses_2", state: .working("Thinking"), turnStart: 90)]).isEmpty)
        let finished = board.sync(agent: "OpenCode", scanned: [scanned("ses_2", state: .done, turnStart: 90)])
        let turn = try #require(finished.first)
        #expect(finished.count == 1)
        #expect(turn.agent == "OpenCode")
        #expect(turn.project == "docs")
        #expect(turn.duration == 90)
        #expect(turn.sessionID == "ses_2")
        #expect(board.sync(agent: "OpenCode", scanned: [scanned("ses_2", state: .done, turnStart: 90)]).isEmpty)
    }

    @Test func syncKeepsSinceWhenUnchanged() throws {
        var board = AgentBoard()
        _ = board.sync(agent: "Codex CLI", scanned: [scanned("c1", agent: "Codex CLI", state: .working("Bash: ls"), ago: 30)])
        let first = try #require(board.sessions.first).since
        _ = board.sync(agent: "Codex CLI", scanned: [scanned("c1", agent: "Codex CLI", state: .working("Bash: ls"), ago: 10)])
        #expect(try #require(board.sessions.first).since == first)
        _ = board.sync(agent: "Codex CLI", scanned: [scanned("c1", agent: "Codex CLI", state: .working("Edit: a.go"), ago: 0)])
        #expect(try #require(board.sessions.first).since > first)
    }

    @Test func showsActiveAndRecent() {
        let shown = FileAgents.visible([
            scanned("working", state: .working("Thinking"), ago: 20 * 60),
            scanned("stale", state: .working("Thinking"), ago: 45 * 60),
            scanned("recent", state: .done, ago: 5 * 60),
            scanned("old", state: .done, ago: 30 * 60),
        ], live: [:], now: now)
        #expect(shown.map(\.id) == ["working", "recent"])
    }

    @Test func livePidPerCwd() {
        let shown = FileAgents.visible([
            scanned("newest", cwd: "/Users/me/api", state: .done, ago: 40 * 60),
            scanned("older", cwd: "/Users/me/api", state: .done, ago: 50 * 60),
        ], live: ["/Users/me/api": 4242], now: now)
        #expect(shown.map(\.id) == ["newest"])
        #expect(shown.first?.pid == 4242)
    }

    @Test func pinnedSessionKeepsItsPid() {
        let shown = FileAgents.visible([
            scanned("resumed", cwd: "/Users/me/api", state: .idle, ago: 3 * 86_400),
            scanned("newer", cwd: "/Users/me/api", state: .done, ago: 40 * 60),
        ], live: ["/Users/me/api": 4242], pinned: ["resumed": 4242], now: now)
        #expect(shown.map(\.id) == ["resumed"])
        #expect(shown.first?.pid == 4242)
    }

    @Test func endedProcessHidesItsSession() {
        var tracker = FileAgentTracker()
        let working = scanned("c1", cwd: "/Users/me/api", state: .working("Bash: make"), ago: 60)
        #expect(tracker.shown([working], live: ["/Users/me/api": 4242], now: now).first?.pid == 4242)
        // Ctrl-C: the process is gone and the file didn't change.
        #expect(tracker.shown([working], live: [:], now: now.addingTimeInterval(5)).isEmpty)
        #expect(tracker.shown([working], live: [:], now: now.addingTimeInterval(10)).isEmpty)
        // Written again (resumed): back, without a pid.
        var grown = working
        grown.lastActivity = now.addingTimeInterval(20)
        #expect(tracker.shown([grown], live: [:], now: now.addingTimeInterval(20)).map(\.id) == ["c1"])
    }

    @Test func sessionWithoutAProcessStillShowsWhileRecent() {
        var tracker = FileAgentTracker()
        let recent = scanned("o1", state: .done, ago: 60)
        #expect(tracker.shown([recent], live: [:], now: now).map(\.id) == ["o1"])
        #expect(tracker.shown([recent], live: [:], now: now.addingTimeInterval(20 * 60)).isEmpty)
    }

    @Test func orderAfterHookAgents() {
        #expect(AgentBoard.agentName("codex") == "Codex CLI")
        #expect(AgentBoard.agentName("opencode") == "OpenCode")
        #expect(AgentBoard.agentName("gemini") == "Gemini CLI")
        var board = AgentBoard()
        _ = board.sync(agent: "OpenCode", scanned: [scanned("o", state: .working("Thinking"))])
        _ = board.sync(agent: "Codex CLI", scanned: [scanned("c", agent: "Codex CLI", state: .working("Thinking"))])
        _ = board.sync(agent: "Gemini CLI", scanned: [scanned("g", agent: "Gemini CLI", state: .working("Thinking"))])
        var start = HookMessage(event: "UserPromptSubmit", pid: 7, payload: ["session_id": "a", "cwd": "/Users/me/x"])
        start.provider = "antigravity"
        board.apply(start, now: now)
        #expect(board.activeAgents.map(\.agent) == ["Antigravity", "Codex CLI", "OpenCode", "Gemini CLI"])
    }
}

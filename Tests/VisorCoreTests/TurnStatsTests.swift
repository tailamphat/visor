import Foundation
import Testing
@testable import VisorCore

@Suite("Turn summary")
struct TurnStatsTests {
    func tool(_ event: String, _ name: String, _ input: [String: Any], response: [String: Any]? = nil) -> HookMessage {
        var payload: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/web-shop", "tool_name": name, "tool_input": input]
        if let response { payload["tool_response"] = response }
        return HookMessage(event: event, pid: 1, payload: payload)
    }

    /// Files are counted once each; edits count their lines in and out, a new file all its lines.
    @Test func filesAndLines() {
        var turn = TurnStats()
        turn.record(tool("PreToolUse", "Edit", ["file_path": "/Users/me/web-shop/src/total.ts", "old_string": "a\nb", "new_string": "a\nb\nc"]))
        turn.record(tool("PreToolUse", "Edit", ["file_path": "/Users/me/web-shop/src/total.ts", "old_string": "x", "new_string": "y"]))
        turn.record(tool("PreToolUse", "Write", ["file_path": "/Users/me/web-shop/src/total.test.ts", "content": "1\n2\n3\n4\n"]))
        turn.record(tool("PreToolUse", "MultiEdit", ["file_path": "/Users/me/web-shop/src/cart.tsx",
                                                      "edits": [["old_string": "p", "new_string": "q\nr"], ["old_string": "s\nt", "new_string": ""]]]))
        #expect(turn.files == ["/Users/me/web-shop/src/total.ts", "/Users/me/web-shop/src/total.test.ts", "/Users/me/web-shop/src/cart.tsx"])
        #expect(turn.added == 3 + 1 + 4 + 2 && turn.removed == 2 + 1 + 1 + 2)
    }

    /// Commands are counted; a test run is noticed and its outcome read from the output.
    @Test func commandsAndTests() {
        var turn = TurnStats()
        turn.record(tool("PreToolUse", "Bash", ["command": "git status"]))
        turn.record(tool("PreToolUse", "Bash", ["command": "npm test"]))
        #expect(turn.commands == 2 && turn.tests == .ran("npm test"))
        turn.record(tool("PostToolUse", "Bash", ["command": "npm test"], response: ["stdout": "Tests: 42 passed, 42 total", "stderr": ""]))
        #expect(turn.tests == .passed("npm test"))
        turn.record(tool("PreToolUse", "Bash", ["command": "scripts/test.sh"]))
        turn.record(tool("PostToolUse", "Bash", ["command": "scripts/test.sh"], response: ["stdout": "✘ Test run with 300 tests failed after 1s", "stderr": ""]))
        #expect(turn.tests == .failed("scripts/test.sh"), "the latest test run wins")
        turn.record(tool("PostToolUseFailure", "Bash", ["command": "pytest -q"]))
        #expect(turn.tests == .failed("pytest -q"))
    }

    /// Only test commands count as tests.
    @Test func recognisesTestCommands() {
        for command in ["npm test", "npm run test", "pnpm test", "yarn test", "pytest", "python -m pytest -q", "go test ./...", "cargo test",
                        "swift test", "scripts/test.sh", "bundle exec rspec", "npx vitest run", "npx jest", "make test"] {
            #expect(TurnStats.isTest(command), "\(command)")
        }
        for command in ["git status", "ls tests", "cat test.txt", "npm install", "echo testing"] {
            #expect(!TurnStats.isTest(command), "\(command)")
        }
    }

    /// A new prompt starts a fresh tally, and the finished turn carries it.
    @Test func eachTurnStartsFreshAndTheFinishedTurnCarriesIt() {
        var board = AgentBoard()
        let start = Date(timeIntervalSince1970: 1000)
        board.apply(HookMessage(event: "UserPromptSubmit", pid: 1, payload: ["session_id": "s1", "cwd": "/Users/me/web-shop", "prompt": "go"]), now: start)
        board.apply(tool("PreToolUse", "Edit", ["file_path": "/Users/me/web-shop/a.ts", "old_string": "a", "new_string": "b"]), now: start)
        board.apply(tool("PreToolUse", "Bash", ["command": "npm test"]), now: start)
        let stop = HookMessage(event: "Stop", pid: 1, payload: ["session_id": "s1", "cwd": "/Users/me/web-shop"])
        let finished = board.finished(stop, now: start.addingTimeInterval(60))
        #expect(finished?.stats.files == ["/Users/me/web-shop/a.ts"] && finished?.stats.commands == 1)
        #expect(finished?.sessionID == "s1" && finished?.cwd == "/Users/me/web-shop")
        board.apply(HookMessage(event: "UserPromptSubmit", pid: 1, payload: ["session_id": "s1", "prompt": "again"]), now: start)
        #expect(board.sessions[0].turn == TurnStats())
    }

    /// Paths inside the project read short; the summary shows the first few.
    @Test func shortPaths() {
        var turn = TurnStats()
        for name in ["src/a.ts", "src/b.ts", "c.ts", "d.ts", "e.ts"] {
            turn.record(tool("PreToolUse", "Write", ["file_path": "/Users/me/web-shop/\(name)", "content": "x"]))
        }
        #expect(turn.shortFiles(in: "/Users/me/web-shop", limit: 3) == (["src/a.ts", "src/b.ts", "c.ts"], 2))
        #expect(turn.isEmpty == false && TurnStats().isEmpty)
    }

    /// Sessions saved by an older Visor, without the tally, still load.
    @Test func oldSavedSessionsStillLoad() throws {
        var board = AgentBoard()
        board.apply(HookMessage(event: "UserPromptSubmit", pid: 1, payload: ["session_id": "s1", "cwd": "/Users/me/app", "prompt": "go"]))
        var json = try JSONSerialization.jsonObject(with: try board.saved()) as! [[String: Any]]
        json[0]["turnStats"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        let sessions = try JSONDecoder().decode([AgentSession].self, from: old)
        #expect(sessions.count == 1 && sessions[0].turn == TurnStats())
    }
}

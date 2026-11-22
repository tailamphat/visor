import CryptoKit
import Foundation
import Testing
@testable import VisorCore

private func json(_ object: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func message(_ id: String, _ type: String, _ content: Any = "", at time: String = "2026-11-22T10:00:00.000Z",
                     calls: [[String: Any]]? = nil) -> [String: Any] {
    var out: [String: Any] = ["id": id, "type": type, "content": content, "timestamp": time]
    if let calls { out["toolCalls"] = calls }
    return out
}

private func call(_ name: String, _ args: [String: Any], _ status: String = "executing", display: String? = nil) -> [String: Any] {
    var out: [String: Any] = ["id": UUID().uuidString, "name": name, "args": args, "status": status]
    if let display { out["displayName"] = display }
    return out
}

/// A saved chat: `ConversationRecord` with `messages`.
private func chat(_ messages: [[String: Any]], id: String? = "g1", lastUpdated: String? = nil, kind: String? = nil) -> Data {
    var record: [String: Any] = ["projectHash": "abc", "startTime": "2026-11-22T09:59:00.000Z", "messages": messages]
    if let id { record["sessionId"] = id }
    if let lastUpdated { record["lastUpdated"] = lastUpdated }
    if let kind { record["kind"] = kind }
    return Data(json(record).utf8)
}

private func state(_ messages: [[String: Any]]) -> AgentState? {
    var reader = GeminiChat(id: "f")
    reader.read(json: chat(messages))
    return reader.session(cwd: "", fallback: Date())?.state
}

private func date(_ text: String) -> Date { ISODate.parse(text)! }

private let prompt = message("1", "user", "fix the cart total\nplease", at: "2026-11-22T10:00:00.000Z")

@Suite("Gemini sessions")
struct GeminiSessionTests {
    @Test func readsTaskAndTimes() throws {
        var reader = GeminiChat(id: "session-file")
        reader.read(json: chat([prompt, message("2", "gemini", "Done, the total adds tax now.", at: "2026-11-22T10:01:00.000Z")],
                               lastUpdated: "2026-11-22T10:01:30.000Z"))
        let session = try #require(reader.session(cwd: "/Users/me/web-shop", fallback: Date()))
        #expect(session.id == "g1")
        #expect(session.agent == "Gemini CLI")
        #expect(session.cwd == "/Users/me/web-shop")
        #expect(session.task == AgentBoard.summarize("fix the cart total\nplease"))
        #expect(session.turnStart == date("2026-11-22T10:00:00.000Z"))
        #expect(session.lastActivity == date("2026-11-22T10:01:30.000Z"))
        #expect(session.state == .done)

        var parts = GeminiChat(id: "f")
        parts.read(json: chat([message("1", "user", [["text": "fix the cart total\nplease"]])]))
        #expect(parts.session(cwd: "", fallback: Date())?.task == session.task)
    }

    @Test func fallsBackToFileID() {
        var reader = GeminiChat(id: "session-2026-11-22T10-00-ab12")
        reader.read(json: chat([prompt], id: nil))
        #expect(reader.session(cwd: "", fallback: Date())?.id == "session-2026-11-22T10-00-ab12")
    }

    @Test func describesToolCalls() {
        #expect(GeminiChat.describe(name: "run_shell_command", args: ["command": "npm test"], displayName: nil) == "Bash: npm test")
        #expect(GeminiChat.describe(name: "read_file", args: ["absolute_path": "/Users/me/web-shop/README.md"], displayName: nil) == "Read: README.md")
        #expect(GeminiChat.describe(name: "replace", args: ["file_path": "/Users/me/web-shop/src/cart.ts"], displayName: nil) == "Edit: cart.ts")
        #expect(GeminiChat.describe(name: "write_file", args: ["file_path": "/Users/me/web-shop/notes.md"], displayName: nil) == "Write: notes.md")
        #expect(GeminiChat.describe(name: "search_file_content", args: ["pattern": "TODO"], displayName: nil) == "Grep: TODO")
        #expect(GeminiChat.describe(name: "glob", args: ["pattern": "*.ts"], displayName: nil) == "Glob: *.ts")
        #expect(GeminiChat.describe(name: "google_web_search", args: ["query": "swift testing"], displayName: nil) == "WebSearch: swift testing")
        #expect(GeminiChat.describe(name: "web_fetch", args: ["prompt": "Summarise https://example.com/docs please"], displayName: nil)
                == "WebFetch: example.com")
        #expect(GeminiChat.describe(name: "mystery", args: [:], displayName: "Mystery") == "Mystery")
        #expect(GeminiChat.describe(name: "mystery", args: [:], displayName: nil) == "mystery")
    }

    @Test func runningCallIsActivity() {
        let calls = [call("read_file", ["absolute_path": "/Users/me/a.md"], "success"), call("run_shell_command", ["command": "npm test"])]
        #expect(state([prompt, message("2", "gemini", "", calls: calls)]) == .working("Bash: npm test"))
    }

    @Test func turnStatesFollowMessages() {
        #expect(state([prompt]) == .working("Thinking"))
        let finished = [call("read_file", ["absolute_path": "/Users/me/a.md"], "success")]
        #expect(state([prompt, message("2", "gemini", "", calls: finished)]) == .working("Thinking"))
        let waiting = [call("run_shell_command", ["command": "rm -rf build"], "awaiting_approval")]
        #expect(state([prompt, message("2", "gemini", "", calls: waiting)])?.isAsking == true)
        var reader = GeminiChat(id: "f")
        reader.read(json: chat([prompt, message("2", "gemini", "Shall I commit?")]))
        #expect(reader.session(cwd: "", fallback: Date())?.state == .done)
        #expect(reader.session(cwd: "", fallback: Date())?.askedForReply == true)
        #expect(state([prompt, message("2", "error", "Quota exceeded")]) == .idle)
        let cancelled = [call("run_shell_command", ["command": "make"], "cancelled")]
        #expect(state([prompt, message("2", "gemini", "", calls: cancelled)]) == .idle)
        #expect(state([prompt, message("2", "info", "Request cancelled.")]) == .idle)
        #expect(state([prompt, message("2", "gemini", "All set."), message("3", "warning", "Slow response")]) == .done)
    }

    @Test func jsonLinesReadOnlyNewLines() {
        let lines = [json(["sessionId": "g2", "projectHash": "abc", "startTime": "2026-11-22T09:59:00.000Z"]),
                     json(prompt),
                     json(message("2", "gemini", "", calls: [call("run_shell_command", ["command": "npm test"])]))]
            .map { $0 + "\n" }
        var whole = GeminiChat(id: "f")
        whole.read(lines: Data(lines.joined().utf8))
        var pieces = GeminiChat(id: "f")
        pieces.read(lines: Data((lines[0] + lines[1]).utf8))
        #expect(pieces.offset == UInt64((lines[0] + lines[1]).utf8.count))
        pieces.read(lines: Data(lines[2].utf8))
        #expect(pieces.offset == whole.offset)
        #expect(pieces.session(cwd: "", fallback: Date()) == whole.session(cwd: "", fallback: Date()))
        #expect(whole.session(cwd: "", fallback: Date())?.id == "g2")
        #expect(whole.session(cwd: "", fallback: Date())?.state == .working("Bash: npm test"))
    }

    @Test func jsonLinesHalfLineWaits() {
        var reader = GeminiChat(id: "f")
        let first = json(prompt) + "\n"
        let half = String(json(message("2", "gemini", "Done.")).prefix(20))
        reader.read(lines: Data((first + half).utf8))
        #expect(reader.offset == UInt64(first.utf8.count))
        #expect(reader.session(cwd: "", fallback: Date())?.state == .working("Thinking"))
    }

    @Test func jsonLinesRecordReplacesById() {
        var reader = GeminiChat(id: "f")
        let running = message("2", "gemini", "", calls: [call("run_shell_command", ["command": "npm test"])])
        let finished = message("2", "gemini", "Tests pass.", calls: [call("run_shell_command", ["command": "npm test"], "success")])
        reader.read(lines: Data([json(prompt), json(running), json(finished)].map { $0 + "\n" }.joined().utf8))
        #expect(reader.session(cwd: "", fallback: Date())?.state == .working("Thinking"))
    }

    @Test func projectFromProjectRoot() {
        #expect(GeminiChat.project(folder: "web-shop-1a2b", projectRoot: "/Users/me/web-shop\n", liveCwds: []) == "/Users/me/web-shop")
    }

    @Test func projectFromHashOfLiveCwd() {
        let hash = SHA256.hash(data: Data("/Users/me/api".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(GeminiChat.project(folder: hash, projectRoot: nil, liveCwds: ["/Users/me/docs", "/Users/me/api"]) == "/Users/me/api")
    }

    @Test func unknownProjectShowsAgentName() throws {
        let hash = String(repeating: "ab", count: 32)
        let cwd = GeminiChat.project(folder: hash, projectRoot: nil, liveCwds: ["/Users/me/docs"])
        #expect(cwd == "")
        var reader = GeminiChat(id: "f")
        reader.read(json: chat([prompt]))
        var board = AgentBoard()
        _ = board.sync(agent: "Gemini CLI", scanned: [try #require(reader.session(cwd: cwd, fallback: Date()))])
        #expect(board.sessions.first?.project == "Gemini CLI")
    }

    @Test func skipsSubagentChats() {
        var reader = GeminiChat(id: "f")
        reader.read(json: chat([prompt], kind: "subagent"))
        #expect(reader.session(cwd: "", fallback: Date()) == nil)
    }

    @Test func matchesGeminiCommandsOnly() {
        #expect(GeminiChat.isGeminiCommand(name: "gemini", script: nil))
        #expect(GeminiChat.isGeminiCommand(name: "node", script: "/opt/homebrew/bin/gemini"))
        #expect(GeminiChat.isGeminiCommand(name: "node", script: "/usr/local/lib/node_modules/@google/gemini-cli/dist/index.js"))
        #expect(!GeminiChat.isGeminiCommand(name: "agy", script: nil))
        #expect(!GeminiChat.isGeminiCommand(name: "node", script: "/Users/me/.gemini/antigravity-cli/bin/gemini"))
        #expect(!GeminiChat.isGeminiCommand(name: "node", script: "/Users/me/app/server.js"))
        #expect(!GeminiChat.isGeminiCommand(name: "node", script: nil))
    }

    @Test func scriptSkipsNodeOptions() {
        #expect(GeminiChat.script(nodeArguments: ["node", "/opt/homebrew/bin/gemini"]) == "/opt/homebrew/bin/gemini")
        #expect(GeminiChat.script(nodeArguments: ["node", "--no-warnings=DEP0040", "/opt/homebrew/bin/gemini", "-p", "hi"])
                == "/opt/homebrew/bin/gemini")
        #expect(GeminiChat.script(nodeArguments: ["node", "--max-old-space-size=8192", "/usr/local/lib/node_modules/@google/gemini-cli/dist/index.js"])
                == "/usr/local/lib/node_modules/@google/gemini-cli/dist/index.js")
        #expect(GeminiChat.script(nodeArguments: ["node", "-r", "/Users/me/hook.js", "/opt/homebrew/bin/gemini"]) == "/opt/homebrew/bin/gemini")
        #expect(GeminiChat.script(nodeArguments: ["node"]) == nil)
        #expect(GeminiChat.script(nodeArguments: ["node", "--inspect"]) == nil)
    }

    @Test func onlyChatFilesAreRead() {
        #expect(GeminiChat.isChatFile("tmp/9f2c/chats/session-2026-11-22T10-00-ab12.json"))
        #expect(GeminiChat.isChatFile("tmp/web-shop/chats/session-2026-11-22T10-00-ab12.jsonl"))
        #expect(!GeminiChat.isChatFile("antigravity-cli/conversations/abc.db"))
        #expect(!GeminiChat.isChatFile("config/hooks.json"))
        #expect(!GeminiChat.isChatFile("tmp/9f2c/logs.json"))
        #expect(!GeminiChat.isChatFile("settings.json"))
        #expect(!GeminiChat.isChatFile("tmp/9f2c/chats/notes.json"))
    }
}

private extension AgentState {
    var isAsking: Bool { if case .asking = self { return true } else { return false } }
}

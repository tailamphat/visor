import Foundation
import Testing
@testable import VisorCore

@Suite("Key watch")
struct KeyWatchTests {
    typealias F = KeyFixture
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func hook(_ event: String, session: String? = "a", _ fields: [String: Any] = [:]) -> HookMessage {
        var payload = fields
        if let session { payload["session_id"] = session }
        payload["cwd"] = "/Users/me/shop"
        payload["transcript_path"] = "/Users/me/.claude/projects/shop/a.jsonl"
        return HookMessage(event: event, pid: 1, payload: payload)
    }

    func prompt(_ text: String, session: String = "a") -> HookMessage {
        hook("UserPromptSubmit", session: session, ["prompt": text])
    }

    func tool(_ name: String, _ input: [String: Any], event: String = "PreToolUse", session: String = "a") -> HookMessage {
        hook(event, session: session, ["tool_name": name, "tool_input": input])
    }

    /// A message through `HookMessage.parse`, as the hook script sends it.
    func parsed(provider: String, event: String, raw: [String: Any]) throws -> HookMessage {
        let line = try JSONSerialization.data(withJSONObject: ["event": event, "provider": provider, "pid": 1, "raw": raw])
        return try #require(HookMessage.parse(line))
    }

    @Test func scansOnlyPromptCommandAndWrites() {
        let cases: [(HookMessage, KeyAlert.Source)] = [
            (prompt("use \(F.githubClassic(seed: 1))"), .prompt),
            (tool("Bash", ["command": "curl -H 'x: \(F.githubClassic(seed: 2))'"]), .command),
            (tool("Write", ["file_path": "/x/.env", "content": "A=\(F.githubClassic(seed: 3))"]), .file),
            (tool("Edit", ["file_path": "/x", "old_string": "a", "new_string": F.githubClassic(seed: 4)]), .file),
            (tool("MultiEdit", ["file_path": "/x", "edits": [["old_string": "a", "new_string": F.githubClassic(seed: 5)]]]), .file),
            (tool("NotebookEdit", ["notebook_path": "/x.ipynb", "new_source": F.githubClassic(seed: 6)]), .file),
        ]
        for (index, (message, source)) in cases.enumerated() {
            var watch = KeyWatch()
            let alert = watch.record(message, agent: "Claude Code", at: t0)
            expectTrue(alert?.source == source, "case \(index)")
            expectTrue(alert?.kinds == [.github], "case \(index)")
        }
        let key = F.githubClassic(seed: 7)
        let ignored: [HookMessage] = [
            tool("Read", ["file_path": key]),
            tool("Grep", ["pattern": key]),
            tool("Bash", ["command": key], event: "PostToolUse"),
            tool("Bash", ["command": key], event: "PermissionRequest"),
            hook("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"], "tool_response": ["stdout": key]]),
            hook("Stop", ["last_assistant_message": key]),
            hook("Notification", ["message": key]),
            tool("Task", ["command": key, "prompt": "x"]),
            tool("Write", ["file_path": "/x", "old_text": key]),
        ]
        for (index, message) in ignored.enumerated() {
            var watch = KeyWatch()
            expectTrue(watch.record(message, agent: "Claude Code", at: t0) == nil, "ignored \(index)")
        }
    }

    @Test func scansCopilotAndAntigravityWrites() throws {
        let cases: [(HookMessage, KeyAlert.Source)] = [
            (try parsed(provider: "copilot", event: "preToolUse",
                        raw: ["sessionId": "c", "toolName": "create", "toolArgs": ["path": "/x", "file_text": F.githubClassic(seed: 1)]]), .file),
            (try parsed(provider: "copilot", event: "preToolUse",
                        raw: ["sessionId": "c", "toolName": "edit", "toolArgs": ["path": "/x", "old_str": "a", "new_str": F.githubClassic(seed: 2)]]), .file),
            (try parsed(provider: "antigravity", event: "PreToolUse",
                        raw: ["conversationId": "g", "toolCall": ["name": "write_file", "args": ["Path": "/x", "Content": F.githubClassic(seed: 3)]]]), .file),
            (try parsed(provider: "antigravity", event: "PreToolUse",
                        raw: ["conversationId": "g", "toolCall": ["name": "write_file", "args": ["Path": "/x", "Body": F.githubClassic(seed: 4)]]]), .file),
            (try parsed(provider: "antigravity", event: "PreToolUse",
                        raw: ["conversationId": "g", "toolCall": ["name": "replace_file_content",
                              "args": ["TargetFile": "/x", "ReplacementChunks": [["ReplacementContent": F.githubClassic(seed: 5)]]]]]), .file),
            (try parsed(provider: "antigravity", event: "PreToolUse",
                        raw: ["conversationId": "g", "toolCall": ["name": "run_command", "args": ["Cmd": "echo " + F.githubClassic(seed: 6)]]]), .command),
        ]
        for (index, (message, source)) in cases.enumerated() {
            var watch = KeyWatch()
            let alert = watch.record(message, agent: "agent", at: t0)
            expectTrue(alert?.source == source, "case \(index)")
            expectTrue(alert?.kinds == [.github], "case \(index)")
        }
    }

    @Test func antigravityEditSkipsOldText() throws {
        let key = F.githubClassic(seed: 8)
        var watch = KeyWatch()
        let removing = try parsed(provider: "antigravity", event: "PreToolUse",
                                  raw: ["conversationId": "g", "toolCall": ["name": "replace_file_content",
                                        "args": ["TargetFile": "/x", "ReplacementChunks": [["TargetContent": "A=" + key, "ReplacementContent": "A=env()"]]]]])
        expectTrue(watch.record(removing, agent: "agent", at: t0) == nil)
        let multi = try parsed(provider: "antigravity", event: "PreToolUse",
                               raw: ["conversationId": "g", "toolCall": ["name": "multi_replace_file_content",
                                     "args": ["TargetFile": "/x", "ReplacementChunks": [["old_string": key, "new_string": "x"]]]]])
        expectTrue(watch.record(multi, agent: "agent", at: t0) == nil)
        let adding = try parsed(provider: "antigravity", event: "PreToolUse",
                                raw: ["conversationId": "g", "toolCall": ["name": "replace_file_content",
                                      "args": ["TargetFile": "/x", "ReplacementChunks": [["TargetContent": "A=env()", "ReplacementContent": "A=" + key]]]]])
        expectTrue(watch.record(adding, agent: "agent", at: t0)?.kinds == [.github])
    }

    @Test func antigravityContainersAreAlwaysWalked() throws {
        var watch = KeyWatch()
        let nested = try parsed(provider: "antigravity", event: "PreToolUse",
                                raw: ["conversationId": "g", "toolCall": ["name": "write_file",
                                      "args": ["Path": "/x", "SearchResults": ["Body": F.githubClassic(seed: 11)],
                                               "TargetChunks": [["NewText": F.githubClassic(seed: 12)]]]]])
        let alert = watch.record(nested, agent: "agent", at: t0)
        expectTrue(alert?.kinds == [.github])
        // Both keys were seen: neither alerts again.
        let again = watch.record(prompt(F.githubClassic(seed: 11) + " " + F.githubClassic(seed: 12), session: "g"), agent: "agent", at: t0)
        expectTrue(again == nil)
    }

    @Test func antigravityUnmappedWriteToolsAreScanned() throws {
        for name in ["write_to_file", "create_or_replace", "edit_notebook"] {
            var watch = KeyWatch()
            let message = try parsed(provider: "antigravity", event: "PreToolUse",
                                     raw: ["conversationId": "g", "toolCall": ["name": name, "args": ["TargetFile": "/x", "CodeContent": F.githubClassic(seed: 13)]]])
            let alert = watch.record(message, agent: "agent", at: t0)
            expectTrue(alert?.source == .file, "\(name)")
        }
        var watch = KeyWatch()
        let read = try parsed(provider: "antigravity", event: "PreToolUse",
                              raw: ["conversationId": "g", "toolCall": ["name": "view_code_item", "args": ["Item": F.githubClassic(seed: 14)]]])
        expectTrue(watch.record(read, agent: "agent", at: t0) == nil)
    }

    @Test func eventScanIsCapped() throws {
        let filler = String(repeating: "lorem ipsum ", count: 1_500)  // 18 KB each
        var watch = KeyWatch()
        let late = try parsed(provider: "antigravity", event: "PreToolUse",
                              raw: ["conversationId": "g", "toolCall": ["name": "write_file",
                                    "args": ["Parts": (0..<8).map { _ in filler } + [F.githubClassic(seed: 9)]]]])
        expectTrue(watch.record(late, agent: "agent", at: t0) == nil)
        let early = try parsed(provider: "antigravity", event: "PreToolUse",
                               raw: ["conversationId": "g", "toolCall": ["name": "write_file",
                                     "args": ["Parts": [F.githubClassic(seed: 10)] + (0..<8).map { _ in filler }]]])
        expectTrue(watch.record(early, agent: "agent", at: t0) != nil)
    }

    @Test func trailingTextIsTheSameKey() {
        var watch = KeyWatch()
        let key = F.openAILegacy(seed: 60)
        expectTrue(watch.record(prompt(key), agent: "Claude Code", at: t0) != nil)
        expectTrue(watch.record(prompt(key + "-suffix_text"), agent: "Claude Code", at: t0) == nil)
    }

    @Test func twoPrivateKeysOfOneTypeBothAlert() {
        var watch = KeyWatch()
        expectTrue(watch.record(tool("Write", ["file_path": "/a", "content": F.privateKey("OPENSSH ", shared: 70, seed: 70)]), agent: "Claude Code", at: t0) != nil)
        expectTrue(watch.record(tool("Write", ["file_path": "/b", "content": F.privateKey("OPENSSH ", shared: 70, seed: 71)]), agent: "Claude Code", at: t0) != nil)
    }

    @Test func twoKindsInOneMessage() {
        var watch = KeyWatch()
        let text = "\(F.slackBot()) and \(F.githubClassic())"
        let alert = watch.record(prompt(text), agent: "Claude Code", at: t0)
        expectTrue(alert?.kinds == [.slack, .github])
        expectTrue(watch.record(prompt(text), agent: "Claude Code", at: t0) == nil)
        let more = watch.record(prompt(text + " " + F.aws()), agent: "Claude Code", at: t0)
        expectTrue(more?.kinds == [.aws])
    }

    @Test func oncePerKeyPerSession() throws {
        var watch = KeyWatch()
        let key = F.githubClassic(seed: 1)
        let recorded = watch.record(prompt(key), agent: "Claude Code", at: t0)
        let first = try #require(recorded)
        expectTrue(first.session == "a")
        expectTrue(first.agent == "Claude Code")
        expectTrue(first.at == t0)
        expectTrue(first.cwd == "/Users/me/shop")
        expectTrue(first.transcript == "/Users/me/.claude/projects/shop/a.jsonl")
        expectTrue(watch.record(tool("Bash", ["command": "echo " + key]), agent: "Claude Code", at: t0) == nil)
        expectTrue(watch.record(prompt(F.githubClassic(seed: 2)), agent: "Claude Code", at: t0) != nil)
        expectTrue(watch.record(prompt(key, session: "b"), agent: "Claude Code", at: t0) != nil)
    }

    @Test func sessionEndForgets() {
        var watch = KeyWatch()
        let key = F.openAILegacy()
        expectTrue(watch.record(prompt(key), agent: "Claude Code", at: t0) != nil)
        expectTrue(watch.record(hook("SessionEnd"), agent: "Claude Code", at: t0) == nil)
        expectTrue(watch.alerts.count == 1)
        expectTrue(watch.record(prompt(key), agent: "Claude Code", at: t0) != nil)
        watch.forget(keeping: ["other"])
        expectTrue(watch.record(prompt(key), agent: "Claude Code", at: t0) != nil)
        watch.forget(keeping: ["a"])
        expectTrue(watch.record(prompt(key), agent: "Claude Code", at: t0) == nil)
    }

    @Test func alertCarriesNoKeyText() throws {
        var watch = KeyWatch()
        let keys = [F.githubClassic(), F.anthropic(), F.slackRotating(), F.aws()]
        let recorded = watch.record(prompt(keys.joined(separator: "\n")), agent: "Claude Code", at: t0)
        let alert = try #require(recorded)
        let dumps = [String(reflecting: alert), String(reflecting: watch)]
        for key in keys {
            let chars = Array(key)
            for start in stride(from: 0, through: chars.count - 8, by: 1) {
                let run = String(chars[start..<start + 8])
                for dump in dumps { expectTrue(!dump.contains(run)) }
            }
        }
    }

    @Test func dismissRemovesAlert() throws {
        var watch = KeyWatch()
        for seed in 1...25 { _ = watch.record(prompt(F.githubClassic(seed: UInt64(seed))), agent: "Claude Code", at: t0.addingTimeInterval(Double(seed))) }
        expectTrue(watch.alerts.count == 20)
        expectTrue(watch.alerts.map(\.at) == watch.alerts.map(\.at).sorted(by: >))
        let first = try #require(watch.alerts.first)
        let generation = watch.generation
        watch.dismiss(first.id)
        expectTrue(watch.alerts.count == 19)
        expectTrue(!watch.alerts.contains(first))
        expectTrue(watch.generation == generation + 1)
        watch.dismiss(first.id)
        expectTrue(watch.generation == generation + 1)
    }

    @Test func memoryIsBounded() {
        var watch = KeyWatch()
        for seed in 1...300 { _ = watch.record(prompt(F.githubClassic(seed: UInt64(seed))), agent: "Claude Code", at: t0) }
        expectTrue(watch.hashCount(session: "a") <= KeyWatch.maxHashes)
        expectTrue(KeyWatch.maxHashes == 256)
        for session in 1...70 { _ = watch.record(prompt(F.githubClassic(seed: 1), session: "s\(session)"), agent: "Claude Code", at: t0) }
        expectTrue(watch.sessionCount <= KeyWatch.maxSessions)
        expectTrue(KeyWatch.maxSessions == 64)
        expectTrue(watch.alerts.count <= 20)
    }

    @Test func noAlertWithoutSession() {
        var watch = KeyWatch()
        expectTrue(watch.record(hook("UserPromptSubmit", session: nil, ["prompt": F.githubClassic()]), agent: "Claude Code", at: t0) == nil)
    }

    @Test(arguments: ["Sources/VisorCore/KeyWatch.swift", "Tests/VisorCoreTests/KeyWatchTests.swift"])
    func newFilesHoldNoKeyShapedLiteral(_ path: String) throws {
        let clean = try KeyShapesTests.holdsNoKeyShapedLiteral(path)
        expectTrue(clean)
    }

    @Test func watchKeepsNothing() throws {
        let source = try KeyShapesTests.repoFile("Sources/VisorCore/KeyWatch.swift")
        for api in KeyShapesTests.keepingAPIs { expectTrue(!source.contains(api), "\(api)") }
    }
}

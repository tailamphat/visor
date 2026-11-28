import Foundation
import Testing
@testable import VisorCore

@Suite("Key notice")
struct KeyNoticeTests {
    typealias F = KeyFixture
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func alert(_ kinds: [KeyKind], source: KeyAlert.Source = .prompt, id: Int = 1,
               transcript: String? = nil) -> KeyAlert {
        KeyAlert(id: id, kinds: kinds, session: "s1", agent: "Claude Code", source: source, at: t0,
                 cwd: "/Users/me/api", transcript: transcript)
    }

    @Test func peekWordsBySource() {
        expectTrue(KeyNotice.peekWords(.prompt) == "key in a prompt")
        expectTrue(KeyNotice.peekWords(.command) == "key in a command")
        expectTrue(KeyNotice.peekWords(.file) == "key in a file")
    }

    @Test func kindsPhraseGrammar() {
        expectTrue(KeyNotice.kindsPhrase([.github]) == "A GitHub token")
        expectTrue(KeyNotice.kindsPhrase([.aws]) == "An AWS access key")
        expectTrue(KeyNotice.kindsPhrase([.openai]) == "An OpenAI key")
        expectTrue(KeyNotice.kindsPhrase([.privateKey]) == "A private key")
        expectTrue(KeyNotice.kindsPhrase([.slack, .aws]) == "A Slack token and an AWS access key")
        expectTrue(KeyNotice.kindsPhrase([.github, .anthropic, .privateKey]) == "A GitHub token, an Anthropic key and a private key")
    }

    /// Every word shown for an alert comes from kind labels, project, agent
    /// and source: none holds any part of the key that raised it.
    @Test func bodyNamesKindsOnly() {
        let one = KeyNotice.body([.github])
        expectTrue(one.sentence == "A GitHub token is now in this session's transcript and was sent to the model.")
        expectTrue(one.advice == "Rotating it is the safe move.")
        let two = KeyNotice.body([.slack, .aws])
        expectTrue(two.sentence == "A Slack token and an AWS access key are now in this session's transcript and were sent to the model.")
        expectTrue(two.advice == "Rotating them is the safe move.")
        for (key, kind) in KeyShapesTests.samples {
            let made = alert([kind], source: .file)
            let body = KeyNotice.body(made.kinds)
            let shown = [KeyNotice.peekWords(made.source), body.sentence, body.advice, KeyNotice.hover(made),
                         KeyNotice.project(made) ?? "", String(reflecting: made)].joined(separator: " ")
            expectTrue(!AgentBoardTests.leaks(shown, key), "\(kind)")
        }
        expectTrue(KeyNotice.project(alert([.github])) == "api")
        expectTrue(KeyNotice.hover(alert([.github], source: .command)) == "Claude Code: A GitHub token in a command")
    }

    /// Show transcript only for a `.jsonl` file one project folder deep in a
    /// transcript root; anything else, symlinks out included, is refused.
    @Test func revealOnlyOwnTranscripts() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("keynotice-\(UUID().uuidString)")
        let root = base.appendingPathComponent("projects")
        let project = root.appendingPathComponent("-Users-me-api")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("deep"), withIntermediateDirectories: true)
        let other = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = project.appendingPathComponent("s1.jsonl")
        try Data().write(to: file)
        let outside = other.appendingPathComponent("s1.jsonl")
        try Data().write(to: outside)
        let link = project.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let roots = [root.path]

        expectTrue(KeyNotice.revealable(file.path, roots: roots))
        expectTrue(!KeyNotice.revealable(outside.path, roots: roots))
        expectTrue(!KeyNotice.revealable(project.path + "/../../elsewhere/s1.jsonl", roots: roots))
        expectTrue(!KeyNotice.revealable(link.path, roots: roots))
        expectTrue(!KeyNotice.revealable(project.appendingPathComponent("deep/s1.jsonl").path, roots: roots))
        expectTrue(!KeyNotice.revealable(project.appendingPathComponent("s1.txt").path, roots: roots))
        expectTrue(!KeyNotice.revealable(root.appendingPathComponent("s1.jsonl").path, roots: roots))
        expectTrue(!KeyNotice.revealable("", roots: roots))
        expectTrue(!KeyNotice.revealable(nil, roots: roots))
        expectTrue(!KeyNotice.revealable(file.path, roots: []))
    }

    @Test func keyPeekOutranksOthers() {
        expectTrue(KeyNotice.replaces(showingKey: false, incomingIsKey: false))
        expectTrue(KeyNotice.replaces(showingKey: false, incomingIsKey: true))
        expectTrue(KeyNotice.replaces(showingKey: true, incomingIsKey: true))
        expectTrue(!KeyNotice.replaces(showingKey: true, incomingIsKey: false))
    }

    @Test func heldUntilUnlock() {
        let older = alert([.github], id: 1), newer = alert([.aws], id: 2), other = alert([.slack], id: 3)
        expectTrue(KeyNotice.heldAtUnlock(held: [1, 2], standing: [other, newer, older])?.id == 2)
        expectTrue(KeyNotice.heldAtUnlock(held: [1, 2], standing: [other, older])?.id == 1, "the newer one was dismissed")
        expectTrue(KeyNotice.heldAtUnlock(held: [], standing: [other]) == nil)
    }

    /// The app maps a key peek to one-time news, which the "asks nothing" peek waits behind.
    @Test func keyPeekIsOneTime() {
        expectTrue(!ModePeekGate.shows(over: .oneTime, locked: false, expanded: false))
    }

    /// The approval card's preview shows the kind; the request itself, which
    /// the hook reply and an always-allow rule read, keeps the original.
    @Test func approvalPreviewHidesKeys() throws {
        let key = F.githubClassic()
        let command = "git push https://x:" + key + "@acme.ghe.com/octocat/app"
        let payload: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/api", "tool_name": "Bash",
                                      "tool_input": ["command": command],
                                      "permission_suggestions": [["type": "addRules",
                                                                  "rules": [["toolName": "Bash", "ruleContent": "export T=" + key + ":*"]]]]]
        let request = try #require(ApprovalRequest(HookMessage(event: "PermissionRequest", pid: 1, payload: payload)))
        expectTrue(request.shownPreview.contains("[GitHub token]") && !AgentBoardTests.leaks(request.shownPreview, key))
        expectTrue(request.preview == command, "the request is unchanged")
        let label = try #require(request.shownAlwaysAllowLabel)
        expectTrue(!AgentBoardTests.leaks(label, key) && !label.contains("gh" + "p_"))
        // No key: both read as before.
        let plain: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/api", "tool_name": "Bash",
                                    "tool_input": ["command": "npm run task-runner"]]
        let calm = try #require(ApprovalRequest(HookMessage(event: "PermissionRequest", pid: 1, payload: plain)))
        expectTrue(calm.shownPreview == calm.preview && calm.shownAlwaysAllowLabel == calm.alwaysAllowLabel)
    }

    /// Codex, Gemini and OpenCode share AgentBoard's describe: their activity reads the kind too.
    @Test func fileAgentsShowKindNotKey() {
        let key = F.openAIProject()
        let codex = CodexRollout.describe(name: "exec_command", arguments: ["cmd": "export K=" + key])
        let gemini = GeminiChat.describe(name: "run_shell_command", args: ["command": "export K=" + key], displayName: nil)
        expectTrue(codex.contains("[OpenAI key]") && !AgentBoardTests.leaks(codex, key))
        expectTrue(gemini.contains("[OpenAI key]") && !AgentBoardTests.leaks(gemini, key))
        expectTrue(CodexRollout.describe(name: "exec_command", arguments: ["cmd": "npm test"]) == "Bash: npm test")
    }

    /// The Stuck? card's command and error line, and the hover that repeats
    /// them, read the kind, also when the key sits across their cut.
    @Test func stuckHidesKeys() {
        let key = F.githubClassic()
        let label = StuckWatch.label(tool: "Bash", input: ["command": String(repeating: "x", count: 50) + " " + key])
        expectTrue(!AgentBoardTests.leaks(label, key) && !label.contains("gh" + "p_"))
        let short = StuckWatch.label(tool: "Bash", input: ["command": "git push " + key])
        expectTrue(short.contains("[GitHub token]") && !AgentBoardTests.leaks(short, key))
        let error = StuckWatch.errorLine("fatal: bad token " + key + String(repeating: " y", count: 60))
        expectTrue(error?.contains("[GitHub token]") == true && !AgentBoardTests.leaks(error ?? "", key))
        let across = StuckWatch.errorLine(String(repeating: "e", count: 110) + " " + key)
        expectTrue(!AgentBoardTests.leaks(across ?? "", key))
    }

    /// A question's label (header, or its text cut at 40) reads the kind.
    @Test func questionLabelHidesKeys() {
        let key = F.slackBot()
        let cut = AgentQuestion.label(header: "", text: "Should I use " + key + " here?")
        expectTrue(!AgentBoardTests.leaks(cut, key))
        let header = AgentQuestion.label(header: "Use " + key, text: "")
        expectTrue(header.contains("[Slack token]") && !AgentBoardTests.leaks(header, key))
        expectTrue(AgentQuestion.label(header: "", text: "Which branch?") == "Which branch?")
    }

    /// A clash's file path reads the kind; the memo for redrawing views keeps
    /// only shown text and stays bounded.
    @Test func pathsHideKeysAndMemoKeepsNoKey() {
        let key = F.aws()
        let raw = "/Users/me/api/" + key + ".env"
        let path = KeyShapes.redactedOnce(raw)
        expectTrue(path.contains("[AWS access key]") && !AgentBoardTests.leaks(path, key))
        expectTrue(KeyShapes.redactedOnce(raw) == path && KeyShapes.redactedOnce("/Users/me/api/cart.ts") == "/Users/me/api/cart.ts")
        expectTrue(!RedactionMemo.shared.snapshot.contains { AgentBoardTests.leaks($0, key) })
        for index in 0..<100 { _ = KeyShapes.redactedOnce("/Users/me/file\(index).ts") }
        expectTrue(RedactionMemo.shared.count <= RedactionMemo.limit)
    }

    /// A full-length private key (an RSA 2048 PEM runs past 1600 base64
    /// characters), built at run time, with its END line.
    static func longPEM(newline: String = "\n", indent: String = "") -> (text: String, body: String) {
        let body = F.from(F.base64Chars, 1700, seed: 77)
        var lines: [String] = []
        var rest = Substring(body)
        while !rest.isEmpty { lines.append(indent + String(rest.prefix(64))); rest = rest.dropFirst(64) }
        let end = F.join(F.dashes, "END RSA ", "PRIVATE", " KEY", F.dashes)
        return (indent + F.privateKeyHeader() + newline + lines.joined(separator: newline) + newline + indent + end, body)
    }

    /// No base64 character of a full key shows after its label, in a heredoc,
    /// in a one-line command with escaped newlines, or in a Stuck label.
    @Test func fullPrivateKeyIsHidden() {
        let heredoc = Self.longPEM(indent: "  ")
        let shown = KeyShapes.redacted("cat <<EOF > id_rsa\n" + heredoc.text + "\nEOF\necho done", cap: 8192)
        expectTrue(shown.contains("[private key]") && !AgentBoardTests.leaks(shown, heredoc.body) && shown.contains("echo done"))
        let escaped = Self.longPEM(newline: "\\n")
        let line = AgentBoard.describe(tool: "Bash", input: ["command": "printf '" + escaped.text + "' > k"])
        expectTrue(line.contains("[private key]") && !AgentBoardTests.leaks(line, escaped.body))
        let stuck = StuckWatch.label(tool: "Bash", input: ["command": "printf '" + escaped.text + "' > k"])
        expectTrue(!AgentBoardTests.leaks(stuck, escaped.body))
    }

    /// A token longer than its rule's ceiling leaves no tail after the label.
    @Test func longTokenTailIsHidden() {
        let github = F.githubClassic(body: 300, seed: 31)
        let openai = F.openAILegacy(body: 300, seed: 32)
        let slack = F.join("xo", "xb-", "1234-", F.mixed(260, seed: 33))
        for (index, key) in [github, openai, slack].enumerated() {
            let shown = KeyShapes.redacted("use " + key + " now")
            expectTrue(shown.hasSuffix(" now") && !AgentBoardTests.leaks(shown, key), "token \(index)")
        }
    }

    /// An approval for a tool with no known field previews its input as JSON,
    /// which escapes slashes; the preview still shows no key characters.
    @Test func escapedSlashPreviewIsHidden() throws {
        let pem = Self.longPEM()
        let payload: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/api", "tool_name": "mcp__vault__save",
                                      "tool_input": ["content": pem.text, "name": "deploy"]]
        let request = try #require(ApprovalRequest(HookMessage(event: "PermissionRequest", pid: 1, payload: payload)))
        expectTrue(request.preview.contains("\\/"), "the raw JSON escapes slashes")
        expectTrue(!AgentBoardTests.leaks(request.shownPreview, pem.body))
    }

    /// A finished turn's summary waits behind its peek only when that peek showed.
    @Test func summaryOnlyWithItsPeek() {
        expectTrue(KeyNotice.takesSummary(peekShown: true, expanded: false, hasStats: true))
        expectTrue(!KeyNotice.takesSummary(peekShown: false, expanded: false, hasStats: true), "a key peek kept the notch")
        expectTrue(!KeyNotice.takesSummary(peekShown: true, expanded: true, hasStats: true))
        expectTrue(!KeyNotice.takesSummary(peekShown: true, expanded: false, hasStats: false))
    }

    /// QA case 13 / D14: an edited file's path holding a key is never saved
    /// (sessions.json), yet stays whole in memory for View diff.
    @Test func filePathKeyIsNeverSaved() throws {
        let key = F.githubClassic(seed: 51)
        let path = "/Users/me/api/" + key + ".env"
        var board = AgentBoard()
        let base: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/api"]
        board.apply(HookMessage(event: "UserPromptSubmit", pid: 4242, payload: base.merging(["prompt": "go"]) { $1 }))
        board.apply(HookMessage(event: "PreToolUse", pid: 4242, payload: base.merging(
            ["tool_name": "Edit", "tool_input": ["file_path": path, "old_string": "a", "new_string": "b"]]) { $1 }))
        let stats = try #require(board.sessions.first?.turn)
        expectTrue(stats.files == [path], "kept whole in memory for View diff")
        let saved = String(decoding: try board.saved(), as: UTF8.self)
        expectTrue(!AgentBoardTests.leaks(saved, key) && saved.contains("[GitHub token]"))
        let restored = AgentBoard.restored(from: try board.saved()) { _ in true }
        expectTrue(!AgentBoardTests.leaks(String(reflecting: restored.sessions), key))
        let encoded = String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)
        expectTrue(!AgentBoardTests.leaks(encoded, key))
    }

    /// QA round 2 cases 15 and 17: the turn summary's file line, in memory
    /// (before any save), shows a key in a file name or a folder name as its kind.
    @Test func turnSummaryFilesHideKeys() throws {
        let github = F.githubClassic(seed: 71), aws = F.aws(seed: 72)
        var board = AgentBoard()
        let base: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/api"]
        board.apply(HookMessage(event: "UserPromptSubmit", pid: 4242, payload: base.merging(["prompt": "go"]) { $1 }))
        for path in ["/Users/me/api/" + github + ".env", "/Users/me/api/" + aws + "/config.yml", "/Users/me/other/" + github + ".txt"] {
            board.apply(HookMessage(event: "PreToolUse", pid: 4242, payload: base.merging(
                ["tool_name": "Write", "tool_input": ["file_path": path, "content": "x"]]) { $1 }))
        }
        let stats = try #require(board.sessions.first?.turn)
        let (files, more) = stats.shownFiles(in: "/Users/me/api", limit: 3)
        let line = files.joined(separator: " · ")
        expectTrue(more == 0 && files.count == 3)
        expectTrue(files[0] == "[GitHub token].env" && files[1] == "[AWS access key]/config.yml" && files[2] == "[GitHub token].txt")
        expectTrue(!AgentBoardTests.leaks(line, github) && !AgentBoardTests.leaks(line, aws))
        expectTrue(stats.files.count == 3 && stats.files[0].hasSuffix(".env"), "the paths stay whole for View diff")
    }

    /// QA round 2 finding 2: a key peek the "limit is back" card covered comes
    /// back when the card goes, while its alert still stands.
    @Test func keyPeekComesBackAfterCard() {
        let covered = alert([.github], id: 7), other = alert([.aws], id: 8)
        expectTrue(KeyNotice.comesBack(7, standing: [other, covered])?.id == 7)
        expectTrue(KeyNotice.comesBack(7, standing: [other]) == nil, "Got it pressed meanwhile")
        expectTrue(KeyNotice.comesBack(nil, standing: [covered]) == nil)
    }

    /// The handoff note (copied to the clipboard) lists a path holding a key with its kind.
    @Test func handoffNoteHidesKeyInPath() throws {
        let key = F.githubClassic(seed: 61)
        var board = AgentBoard()
        let base: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/api"]
        board.apply(HookMessage(event: "UserPromptSubmit", pid: 4242, payload: base.merging(["prompt": "go"]) { $1 }))
        for name in ["cart.ts", "config/" + key + ".env"] {
            board.apply(HookMessage(event: "PreToolUse", pid: 4242, payload: base.merging(
                ["tool_name": "Edit", "tool_input": ["file_path": "/Users/me/api/" + name, "old_string": "a", "new_string": "b"]]) { $1 }))
        }
        let session = try #require(board.sessions.first)
        let note = HandoffPlanner.note(for: session, limitTitle: "Session (5h)")
        expectTrue(note.contains("- config/[GitHub token].env") && note.contains("- cart.ts"))
        expectTrue(!AgentBoardTests.leaks(note, key))
    }

    /// QA case 13: every other field shown from hook text, through the board:
    /// a helper's task and activity, the card and Office line, an away row.
    @Test func everyShownFieldHidesKeys() throws {
        let key = F.openAIProject(seed: 52)
        var board = AgentBoard()
        let base: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/api"]
        board.apply(HookMessage(event: "UserPromptSubmit", pid: 4242, payload: base.merging(["prompt": "use " + key]) { $1 }))
        board.apply(HookMessage(event: "PreToolUse", pid: 4242, payload: base.merging(
            ["tool_name": "Agent", "tool_use_id": "t1", "tool_input": ["description": "check " + key, "prompt": "x"]]) { $1 }))
        board.apply(HookMessage(event: "PreToolUse", pid: 4242, payload: base.merging(
            ["tool_name": "Bash", "tool_input": ["command": "curl -H " + key]]) { $1 }))
        let session = try #require(board.sessions.first)
        let shown = [SessionText.detail(session), AwayDigest.waitingDetail(session), session.task ?? "",
                     session.helpers.map { $0.task + " " + ($0.activity ?? "") }.joined(separator: " ")]
        for (index, text) in shown.enumerated() { expectTrue(!AgentBoardTests.leaks(text, key), "field \(index)") }
        expectTrue(!AgentBoardTests.leaks(String(reflecting: board.sessions), key))
    }

    /// QA case 11: the path check never opens or touches the transcript (its
    /// modification time and size stay the same).
    @Test func revealCheckLeavesFileAlone() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("keyreveal-\(UUID().uuidString)")
        let project = base.appendingPathComponent("projects/-Users-me-api")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = project.appendingPathComponent("s1.jsonl")
        try Data("{}".utf8).write(to: file)
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        expectTrue(KeyNotice.revealable(file.path, roots: [base.appendingPathComponent("projects").path]))
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        expectTrue(after[.modificationDate] as? Date == past && (after[.size] as? NSNumber)?.intValue == 2)
    }

    @Test(arguments: ["Sources/VisorCore/KeyNotice.swift", "Tests/VisorCoreTests/KeyNoticeTests.swift",
                      "Sources/VisorCore/AgentBoard.swift", "Tests/VisorCoreTests/AgentTests.swift",
                      "Sources/Visor/App/AppDelegate.swift", "Sources/Visor/App/AppModel.swift",
                      "Sources/Visor/Agents/AgentsView.swift", "Sources/Visor/Notch/NotchView.swift",
                      "Sources/Visor/Agents/ApprovalView.swift", "Sources/VisorCore/StuckWatch.swift",
                      "Sources/VisorCore/Questions.swift", "Sources/Visor/Shared/TurnSummaryView.swift",
                      "Sources/VisorCore/KeyShapes.swift", "Sources/VisorCore/Turns.swift"])
    func filesHoldNoKeyShapedLiteral(_ path: String) throws {
        let clean = try KeyShapesTests.holdsNoKeyShapedLiteral(path)
        expectTrue(clean)
    }

    @Test func noticeKeepsNothing() throws {
        let source = try KeyShapesTests.repoFile("Sources/VisorCore/KeyNotice.swift")
        for api in KeyShapesTests.keepingAPIs { expectTrue(!source.contains(api), "\(api)") }
    }
}

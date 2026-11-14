import Foundation
import Testing
@testable import VisorCore

@Suite("Approvals")
struct ApprovalTests {
    static let request = ApprovalRequest(hook("PermissionRequest", pid: 1, #"{"session_id":"s1","cwd":"/x/app","tool_name":"Bash","tool_input":{"command":"rm -rf build"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm:*"}],"behavior":"allow","destination":"localSettings"}]}"#))!

    func label(_ suggestions: String) -> String? {
        ApprovalRequest(hook("PermissionRequest", #"{"session_id":"s","tool_name":"Edit","tool_input":{},"permission_suggestions":\#(suggestions)}"#))?.alwaysAllowLabel
    }

    func decision(_ d: ApprovalRequest.Decision) throws -> [String: Any] {
        let object = try #require(try JSONSerialization.jsonObject(with: Self.request.reply(d)) as? [String: Any])
        let output = try #require(object["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        return try #require(output["decision"] as? [String: Any])
    }

    @Test func fields() {
        let r = Self.request
        #expect(r.tool == "Bash" && r.preview == "rm -rf build" && r.project == "app")
        #expect(r.suggestions.count == 1 && r.action == "run a command")
    }

    @Test func alwaysAllowNamesTheRule() {
        #expect(Self.request.alwaysAllowLabel == "rm")
        #expect(label(#"[{"type":"setMode","mode":"acceptEdits","destination":"session"}]"#) == "edits")
        #expect(label(#"[{"type":"addRules","rules":[{"toolName":"Edit"}]}]"#) == "Edit", "a rule without content names the tool")
        #expect(label("[]") == nil)
    }

    @Test func replies() throws {
        #expect(try decision(.allow)["behavior"] as? String == "allow")
        #expect(try decision(.deny)["behavior"] as? String == "deny")
        #expect((try decision(.allowAlways)["updatedPermissions"] as? [Any])?.count == 1, "always allow echoes the suggestion")
        #expect(Self.request.reply(.allow).last == 0x0A, "one line")
    }

    @Test func onlyPermissionRequestsMakeApprovals() {
        #expect(ApprovalRequest(hook("PreToolUse", #"{"session_id":"s"}"#)) == nil)
    }
}

@Suite("Approvals closing by themselves")
struct ApprovalReleaseTests {
    func event(_ name: String, _ extra: String = "") -> HookMessage {
        hook(name, pid: 1, #"{"session_id":"s1"\#(extra)}"#)
    }

    @Test("Moving on drops every question", arguments: ["UserPromptSubmit", "Stop", "SessionEnd"])
    func movingOn(event name: String) {
        #expect(ApprovalRelease.after(event(name)) == .all)
    }

    @Test func toolRanOrFailed() {
        #expect(ApprovalRelease.after(event("PostToolUse", #","tool_name":"Bash""#)) == .tool("Bash"))
        #expect(ApprovalRelease.after(event("PostToolUseFailure", #","tool_name":"Edit""#)) == .tool("Edit"))
    }

    @Test func notifications() {
        #expect(ApprovalRelease.after(event("Notification", #","notification_type":"idle_prompt""#)) == .all)
        #expect(ApprovalRelease.after(event("Notification", #","notification_type":"permission_prompt""#)) == nil)
    }

    @Test func keptOtherwise() {
        #expect(ApprovalRelease.after(event("PreToolUse", #","tool_name":"Bash""#)) == nil)
        #expect(ApprovalRelease.after(HookMessage.parse(Data(#"{"event":"Stop","raw":{}}"#.utf8))!) == nil, "no session")
    }
}

@Suite("Hook settings")
struct HookSettingsTests {
    let script = "/Users/me/Library/Application Support/Visor/agent-hook.sh"
    let notchy: [String: Any] = ["hooks": [["type": "command", "command": "\"/Users/me/Library/Application Support/Notchy/agent-hook.sh\" Stop"]]]
    var before: [String: Any] { ["theme": "dark", "permissions": ["allow": ["Bash(ls:*)"]], "hooks": ["Stop": [notchy]]] }

    func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
        (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    func commands(_ settings: [String: Any], _ event: String) -> [String] {
        groups(settings, event).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test func installAddsEveryEventAndKeepsOthers() {
        let installed = HookSettings.install(into: before, script: script)
        #expect(HookSettings.claudeEvents.allSatisfy { commands(installed, $0).contains(HookSettings.command(script: script, event: $0)) })
        #expect(HookSettings.command(script: script, event: "Stop") == "\"\(script)\" Stop", "the path is quoted")
        #expect(commands(installed, "Stop").first?.contains("Notchy") == true && commands(installed, "Stop").count == 2)
        #expect(installed["theme"] as? String == "dark" && installed["permissions"] != nil)
        #expect(HookSettings.isInstalled(installed) && !HookSettings.isInstalled(before))
    }

    @Test func approvalsTimeOutBeforeClaudeCode() {
        let installed = HookSettings.install(into: before, script: script)
        let permission = groups(installed, "PermissionRequest").last?["hooks"] as? [[String: Any]]
        #expect((permission?.first?["timeout"] as? Int) == 120)
    }

    @Test func installingTwiceDoesNotDuplicate() {
        let twice = HookSettings.install(into: HookSettings.install(into: before, script: script), script: script)
        #expect(commands(twice, "Stop").count == 2 && commands(twice, "PreToolUse").count == 1)
    }

    @Test func uninstallRemovesOnlyOurs() {
        let removed = HookSettings.uninstall(from: HookSettings.install(into: before, script: script))
        #expect(commands(removed, "Stop") == commands(before, "Stop"))
        #expect((removed["hooks"] as? [String: Any])?["PreToolUse"] == nil, "events left empty are removed")
        #expect(!HookSettings.isInstalled(removed))
    }

    @Test func copilotFile() {
        let copilot = HookSettings.copilotFile(script: script)
        let hooks = copilot["hooks"] as? [String: Any] ?? [:]
        #expect(copilot["version"] as? Int == 1 && Set(hooks.keys) == Set(HookSettings.copilotEvents))
        let first = (hooks["preToolUse"] as? [[String: Any]])?.first
        #expect(first?["bash"] as? String == "\"\(script)\" preToolUse copilot" && first?["timeoutSec"] as? Int == 5)
        let approvals = (hooks["permissionRequest"] as? [[String: Any]])?.first
        #expect(approvals?["matcher"] as? String == "bash|powershell|create|edit|web_fetch", "only commands, file changes and web fetches ask")
        #expect(approvals?["timeoutSec"] as? Int == 120, "Copilot waits for the card, then falls back to its own prompt")
    }
}

@Suite("Approvals, more")
struct ApprovalMoreTests {
    func request(tool: String, input: String, suggestions: String = "[]") -> ApprovalRequest? {
        ApprovalRequest(hook("PermissionRequest", #"{"session_id":"s","cwd":"/x/app","tool_name":"\#(tool)","tool_input":\#(input),"permission_suggestions":\#(suggestions)}"#))
    }

    @Test("What the agent wants to do", arguments: [
        ("Edit", "edit a file"), ("Write", "create a file"), ("Read", "read a file"), ("WebFetch", "fetch a web page"),
        ("WebSearch", "search the web"), ("Task", "start a subagent"), ("mcp__linear__create_issue", "use mcp__linear__create_issue"),
    ])
    func action(tool: String, words: String) {
        #expect(request(tool: tool, input: "{}")?.action == words)
    }

    @Test func previewFallsBackToTheArguments() {
        #expect(request(tool: "mcp__x__y", input: #"{"b":2,"a":1}"#)?.preview == #"{"a":1,"b":2}"#)
    }

    @Test func folderRulesReadAsFolders() {
        let r = request(tool: "Edit", input: "{}", suggestions: #"[{"type":"addRules","rules":[{"toolName":"Edit","ruleContent":"src/**"}]}]"#)
        #expect(r?.alwaysAllowLabel == "src/")
    }

    @Test func longRulesAreCut() {
        let rule = String(repeating: "x", count: 40)
        let r = request(tool: "Bash", input: "{}", suggestions: #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"\#(rule)"}]}]"#)
        #expect(r?.alwaysAllowLabel?.count == 28 && r?.alwaysAllowLabel?.hasSuffix("…") == true)
    }

    @Test func denyExplainsItself() throws {
        let data = try #require(request(tool: "Bash", input: #"{"command":"ls"}"#)).reply(.deny)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decision = (object["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(decision?["message"] as? String == "Denied from Visor.")
    }
}

@Suite("Hook settings, more")
struct HookSettingsMoreTests {
    let script = "/x/Visor/agent-hook.sh"

    /// Hooks installed while the app was still called Visor.
    var legacy: [String: Any] {
        ["hooks": ["Stop": [["hooks": [["type": "command", "command": "\"/x/Visor/agent-hook.sh\" Stop"]]]]]]
    }

    @Test func notchboardHooksCountAsOurs() {
        #expect(HookSettings.isInstalled(legacy), "so Visor upgrades them on launch")
    }

    @Test func installingReplacesVisorHooks() {
        let installed = HookSettings.install(into: legacy, script: script)
        let stop = ((installed["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) ?? []
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        #expect(commands == ["\"\(script)\" Stop"], "the old Visor hook is replaced, not kept beside it")
    }

    @Test func uninstallRemovesVisorHooksToo() {
        #expect(!HookSettings.isInstalled(HookSettings.uninstall(from: legacy)))
    }

    @Test func installIntoSettingsWithoutHooks() {
        let installed = HookSettings.install(into: ["theme": "dark"], script: script)
        #expect(HookSettings.isInstalled(installed) && installed["theme"] as? String == "dark")
    }

    @Test func uninstallWithoutHooksChangesNothing() {
        let settings = HookSettings.uninstall(from: ["theme": "dark"])
        #expect(settings.count == 1 && settings["hooks"] == nil)
    }
}


@Suite("Copilot approvals")
struct CopilotApprovalTests {
    func request(_ tool: String, _ input: String, cwd: String = "/x/shop") -> ApprovalRequest? {
        ApprovalRequest(hook("permissionRequest", provider: "copilot", #"{"sessionId":"c1","cwd":"\#(cwd)","toolName":"\#(tool)","toolInput":\#(input)}"#))
    }

    @Test("Same words as Claude", arguments: [
        ("bash", #"{"command":"npm run deploy:staging"}"#, "run a command", "npm"),
        ("powershell", #"{"command":"Get-Process"}"#, "run a command", "Get-Process"),
        ("edit", #"{"path":"src/a.ts"}"#, "edit a file", "edits"),
        ("create", #"{"path":"src/b.ts"}"#, "create a file", "edits"),
        ("web_fetch", #"{"url":"https://docs.github.com/x"}"#, "fetch a web page", "docs.github.com"),
    ])
    func words(tool: String, input: String, action: String, always: String) throws {
        let r = try #require(request(tool, input))
        #expect(r.provider == "copilot" && r.action == action && r.alwaysAllowLabel == always)
    }

    @Test func previewAndProject() throws {
        let r = try #require(request("bash", #"{"command":"npm run deploy:staging"}"#))
        #expect(r.preview == "npm run deploy:staging" && r.project == "shop" && r.sessionID == "c1")
        #expect(try #require(request("edit", #"{"path":"src/a.ts"}"#)).preview == "src/a.ts")
    }

    @Test func repliesInCopilotsFormat() throws {
        let r = try #require(request("bash", #"{"command":"ls"}"#))
        func reply(_ d: ApprovalRequest.Decision) throws -> [String: Any] {
            let data = r.reply(d)
            #expect(data.last == 0x0A)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try reply(.allow)["behavior"] as? String == "allow")
        #expect(try reply(.allowAlways)["behavior"] as? String == "allow", "Visor keeps the rule; Copilot just hears allow")
        let deny = try reply(.deny)
        #expect(deny["behavior"] as? String == "deny" && deny["message"] as? String == "Denied from Visor.")
        #expect(try reply(.allow)["hookSpecificOutput"] == nil)
    }
}

@Suite("Copilot always-allow rules")
struct CopilotRuleTests {
    func request(_ tool: String, _ input: String, cwd: String = "/x/shop") -> ApprovalRequest {
        ApprovalRequest(hook("permissionRequest", provider: "copilot", #"{"sessionId":"c1","cwd":"\#(cwd)","toolName":"\#(tool)","toolInput":\#(input)}"#))!
    }

    @Test func aCommandRuleCoversThatCommandInThatProject() throws {
        var rules = CopilotRules()
        rules.add(for: request("bash", #"{"command":"npm run deploy:staging"}"#))
        #expect(rules.allows(request("bash", #"{"command":"npm test"}"#)))
        #expect(!rules.allows(request("bash", #"{"command":"rm -rf build"}"#)), "another command still asks")
        #expect(!rules.allows(request("bash", #"{"command":"npm test"}"#, cwd: "/x/other")), "another project still asks")
        #expect(!rules.allows(request("edit", #"{"path":"a.ts"}"#)), "another kind of action still asks")
    }

    @Test func anEditRuleCoversCreatingToo() {
        var rules = CopilotRules()
        rules.add(for: request("edit", #"{"path":"a.ts"}"#))
        #expect(rules.allows(request("create", #"{"path":"b.ts"}"#)))
    }

    @Test func aWebRuleCoversThatSite() {
        var rules = CopilotRules()
        rules.add(for: request("web_fetch", #"{"url":"https://docs.github.com/a"}"#))
        #expect(rules.allows(request("web_fetch", #"{"url":"https://docs.github.com/b"}"#)))
        #expect(!rules.allows(request("web_fetch", #"{"url":"https://example.com"}"#)))
    }

    /// A rule names the first word, so a chained command could slip a
    /// different one past it. Anything beyond one plain command asks again.
    @Test func aRuleNeverCoversAChainedCommand() {
        var rules = CopilotRules()
        rules.add(for: request("bash", #"{"command":"ls -la"}"#))
        #expect(rules.allows(request("bash", #"{"command":"ls src"}"#)))
        for chained in ["ls; rm -rf build", "ls && rm -rf build", "ls || rm x", "ls | sh", "ls $(rm x)",
                        "ls `rm x`", "ls > ~/.zshrc", "ls\\nrm x", "ls & rm x", "ls <(rm x)"] {
            #expect(!rules.allows(request("bash", #"{"command":"\#(chained)"}"#)), "\(chained)")
        }
    }

    /// "F=/tmp/out.txt; tail $F" named the rule after the one-time variable.
    @Test func leadingVariablesDontNameTheRule() {
        #expect(CopilotRules.Rule(for: request("bash", #"{"command":"F=/tmp/a.txt LANG=C tail -n 5 out.log"}"#)).match == "tail")
        #expect(CopilotRules.Rule(for: request("bash", #"{"command":"npm test"}"#)).match == "npm")
    }

    @Test func rulesAreSavedAndNotDuplicated() throws {
        var rules = CopilotRules()
        rules.add(for: request("bash", #"{"command":"npm test"}"#))
        rules.add(for: request("bash", #"{"command":"npm run build"}"#))
        #expect(rules.rules.count == 1)
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode(CopilotRules.self, from: data) == rules)
    }
}

@Suite("Approval routing")
struct ApprovalRouteTests {
    let claude = ApprovalRequest(hook("PermissionRequest", #"{"session_id":"s1","cwd":"/x/shop","tool_name":"Bash","tool_input":{"command":"npm test"}}"#))!
    let copilot = ApprovalRequest(hook("permissionRequest", provider: "copilot", #"{"sessionId":"c1","cwd":"/x/shop","toolName":"bash","toolInput":{"command":"npm test"}}"#))!
    let question = ApprovalRequest(hook("PermissionRequest", #"{"session_id":"s1","tool_name":"AskUserQuestion","tool_input":{}}"#))!

    @Test func onShowsEveryAgentsApprovalsInTheNotch() {
        #expect(ApprovalRoute.of(claude, inNotch: true, rules: CopilotRules()) == .notch)
        #expect(ApprovalRoute.of(copilot, inNotch: true, rules: CopilotRules()) == .notch)
    }

    @Test func offLeavesEveryAgentsApprovalsInTheTerminal() {
        #expect(ApprovalRoute.of(claude, inNotch: false, rules: CopilotRules()) == .terminal)
        #expect(ApprovalRoute.of(copilot, inNotch: false, rules: CopilotRules()) == .terminal)
    }

    @Test func questionsAlwaysGoToTheTerminal() {
        #expect(ApprovalRoute.of(question, inNotch: true, rules: CopilotRules()) == .terminal)
    }

    @Test func aSavedCopilotRuleAllowsAtOnce() {
        var rules = CopilotRules()
        rules.add(for: copilot)
        #expect(ApprovalRoute.of(copilot, inNotch: true, rules: rules) == .allow)
        #expect(ApprovalRoute.of(copilot, inNotch: false, rules: rules) == .terminal, "off means hands off")
    }
}

@Suite("Approvals answered in the terminal")
struct TerminalAnswerTests {
    let base = #""session_id":"s1","cwd":"/Users/me/web-shop""#
    // How Claude Code 2.1 runs an allowed Bash command, as `ps` shows it.
    let running = #"/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && eval 'sleep 20 && echo '"'"'it is done'"'"' && curl -sI https://example.com' < /dev/null && pwd"#

    @Test func seesTheAllowedCommandStart() {
        #expect(TerminalAnswer.runs(running, command: "sleep 20 && echo 'it is done' && curl -sI https://example.com"))
        #expect(!TerminalAnswer.runs(running, command: "sleep 20"), "only the whole command")
        #expect(!TerminalAnswer.runs(running, command: "rm -rf build"))
        #expect(!TerminalAnswer.runs(running, command: ""))
    }

    func waiting() -> AgentBoard {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"ship it\"}"))
        board.apply(hook("PermissionRequest", "{\(base),\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}"))
        return board
    }

    @Test func allowedThereMeansItIsRunning() throws {
        var board = waiting()
        guard case .needsApproval(let what) = try #require(board.sessions.first).state else { Issue.record("not waiting"); return }
        board.answeredInTerminal(session: "s1", allowed: true)
        #expect(board.sessions.first?.state == .working(what))
    }

    @Test func deniedThereMeansItStopped() {
        var board = waiting()
        board.answeredInTerminal(session: "s1", allowed: false)
        #expect(board.sessions.first?.state == .idle)
        #expect(board.sessions.first?.state.attention == nil, "no amber ! left behind")
    }

    @Test func onlyTouchesAWaitingSession() {
        var board = AgentBoard()
        board.apply(hook("UserPromptSubmit", "{\(base),\"prompt\":\"ship it\"}"))
        board.answeredInTerminal(session: "s1", allowed: false)
        #expect(board.sessions.first?.state == .working("Thinking"))
    }
}

import Foundation
import Testing
@testable import NotchboardCore

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
    let script = "/Users/me/Library/Application Support/Notchboard/agent-hook.sh"
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
        #expect(!HookSettings.copilotEvents.contains("permissionRequest"), "Copilot approvals stay in its terminal")
    }
}

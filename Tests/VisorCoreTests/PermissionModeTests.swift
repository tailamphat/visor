import Foundation
import Testing
@testable import VisorCore

@Suite struct PermissionModeTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func event(_ name: String, mode: Any? = nil, extra: [String: Any] = [:]) -> HookMessage {
        var payload: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/proj"]
        if let mode { payload["permission_mode"] = mode }
        for (k, v) in extra { payload[k] = v }
        return HookMessage(event: name, pid: 4242, payload: payload)
    }

    @Test func labels() {
        #expect(PermissionMode(field: "bypassPermissions")?.label == "no asks")
        #expect(PermissionMode(field: "acceptEdits")?.label == "auto-edit")
        #expect(PermissionMode(field: "plan")?.label == "plan")
        #expect(PermissionMode(field: "default") == .standard)
        #expect(PermissionMode(field: "default")?.label == nil)
        #expect(PermissionMode(field: "somethingNew")?.label == nil)
        #expect(PermissionMode(field: nil) == nil)
        #expect(PermissionMode(field: 7) == nil)
    }

    @Test func realFixture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-nested-helpers/hooks.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var board = AgentBoard()
        for (n, line) in lines.enumerated() {
            let payload = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            board.apply(HookMessage(event: payload["hook_event_name"] as? String ?? "", pid: 4242, payload: payload),
                        now: t0.addingTimeInterval(Double(n)))
        }
        #expect(board.sessions[0].mode == .bypass)
        #expect(board.sessions[0].mode?.label == "no asks")
    }

    @Test func latestWins() {
        var board = AgentBoard()
        board.apply(event("UserPromptSubmit", mode: "plan"), now: t0)
        #expect(board.sessions[0].mode == .plan)
        board.apply(event("PreToolUse", mode: "acceptEdits"), now: t0)
        #expect(board.sessions[0].mode == .acceptEdits)
        board.apply(event("PostToolUse"), now: t0)
        #expect(board.sessions[0].mode == .acceptEdits, "an event without the field keeps it")
        board.apply(event("PreToolUse", mode: "default"), now: t0)
        #expect(board.sessions[0].mode?.label == nil)
    }

    @Test func helperNeverChanges() {
        var board = AgentBoard()
        board.apply(event("UserPromptSubmit", mode: "bypassPermissions"), now: t0)
        board.apply(event("PreToolUse", mode: "plan", extra: ["agent_id": "a1", "tool_name": "Read"]), now: t0)
        #expect(board.sessions[0].mode == .bypass)
    }

    @Test func otherAgentsIgnored() {
        var board = AgentBoard()
        var m = event("UserPromptSubmit", mode: "plan")
        m.provider = "copilot"
        board.apply(m, now: t0)
        #expect(board.sessions[0].mode == nil)
    }

    @Test func differsVisiblyOnMode() {
        var a = AgentBoard()
        a.apply(event("UserPromptSubmit", mode: "default"), now: t0)
        var b = a
        #expect(!b.differsVisibly(from: a))
        b.apply(event("PreToolUse", mode: "plan", extra: ["tool_name": "Read"]), now: t0)
        var c = a
        c.apply(event("PreToolUse", mode: "default", extra: ["tool_name": "Read"]), now: t0)
        #expect(b.differsVisibly(from: c))
    }

    @Test func peekOnce() {
        #expect(PermissionMode.shouldPeek(mode: .bypass, alreadyPeeked: false))
        #expect(!PermissionMode.shouldPeek(mode: .bypass, alreadyPeeked: true))
        #expect(!PermissionMode.shouldPeek(mode: .plan, alreadyPeeked: false))
        #expect(!PermissionMode.shouldPeek(mode: nil, alreadyPeeked: false))
        var board = AgentBoard()
        board.apply(event("UserPromptSubmit", mode: "default"), now: t0)
        let beforeBypass = board.takeModePeek(id: "s1")
        board.apply(event("PreToolUse", mode: "bypassPermissions"), now: t0)
        let first = board.takeModePeek(id: "s1")
        let second = board.takeModePeek(id: "s1")
        board.apply(event("PreToolUse", mode: "bypassPermissions"), now: t0)
        let third = board.takeModePeek(id: "s1")
        let missing = board.takeModePeek(id: "nope")
        #expect(!beforeBypass && first && !second && !third && !missing)
    }

    @Test func approvalUnchanged() {
        var board = AgentBoard()
        board.apply(event("UserPromptSubmit", mode: "bypassPermissions"), now: t0)
        board.apply(event("PermissionRequest", mode: "bypassPermissions",
                          extra: ["tool_name": "Bash", "tool_input": ["command": "ls"]]), now: t0)
        var plain = AgentBoard()
        plain.apply(event("UserPromptSubmit"), now: t0)
        plain.apply(event("PermissionRequest", extra: ["tool_name": "Bash", "tool_input": ["command": "ls"]]), now: t0)
        #expect(board.sessions[0].state == plain.sessions[0].state)
        if case .needsApproval = board.sessions[0].state {} else { Issue.record("not needsApproval") }
        #expect(board.waiting == 1)
    }

    @Test func oldSessionLoads() throws {
        var board = AgentBoard()
        board.apply(event("UserPromptSubmit", mode: "plan"), now: t0)
        let data = try JSONEncoder().encode(board.sessions[0])
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["mode"] as? String == "plan")
        object["mode"] = nil
        object["modePeeked"] = nil
        let old = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.mode == nil)
        object["mode"] = "fromTheFuture"
        let future = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(future.mode == .unknown)
    }

    // The mode peek is the least urgent news: it waits rather than cut a one-time peek
    // short, and is not used up while it could not be seen.
    @Test func modePeekWaitsForOneTimePeeks() {
        #expect(ModePeekGate.shows(over: .nothing, locked: false, expanded: false))
        #expect(ModePeekGate.shows(over: .routine, locked: false, expanded: false))
        #expect(!ModePeekGate.shows(over: .oneTime, locked: false, expanded: false))
    }

    @Test func modePeekNotTakenWhileUnseen() {
        #expect(!ModePeekGate.shows(over: .nothing, locked: true, expanded: false))
        #expect(!ModePeekGate.shows(over: .nothing, locked: false, expanded: true))
    }

    @Test func blockedPeekStillComesOnALaterEvent() {
        var board = AgentBoard()
        board.apply(event("UserPromptSubmit", mode: "bypassPermissions"))
        // Gate closed: takeModePeek is not called, so the session keeps its peek.
        if ModePeekGate.shows(over: .oneTime, locked: false, expanded: false) { _ = board.takeModePeek(id: "s1") }
        board.apply(event("PreToolUse", mode: "bypassPermissions", extra: ["tool_name": "Bash"]))
        #expect(ModePeekGate.shows(over: .nothing, locked: false, expanded: false) && board.takeModePeek(id: "s1"))
    }

    // QA 6: the one peek is remembered across a restart (sessions.json).
    @Test func peekNotRepeatedAfterRestore() throws {
        var board = AgentBoard()
        board.apply(event("UserPromptSubmit", mode: "bypassPermissions"), now: t0)
        let first = board.takeModePeek(id: "s1")
        #expect(first)
        var restored = AgentBoard.restored(from: try board.saved()) { _ in true }
        #expect(restored.sessions.first?.mode == .bypass)
        restored.apply(event("PreToolUse", mode: "bypassPermissions"), now: t0)
        let again = restored.takeModePeek(id: "s1")
        #expect(!again)
    }

    // QA 11: default -> bypass -> default: the pill comes and goes with the mode.
    @Test func pillFollowsModeBackToDefault() {
        var board = AgentBoard()
        board.apply(event("UserPromptSubmit", mode: "default"), now: t0)
        #expect(board.sessions[0].mode?.label == nil)
        board.apply(event("PreToolUse", mode: "bypassPermissions"), now: t0)
        #expect(board.sessions[0].mode?.label == "no asks")
        board.apply(event("PostToolUse", mode: "default"), now: t0)
        #expect(board.sessions[0].mode?.label == nil)
    }
}

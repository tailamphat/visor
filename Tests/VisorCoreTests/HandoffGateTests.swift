import Foundation
import Testing
@testable import VisorCore

@Suite("HandoffGate")
struct HandoffGateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func handoff(_ id: String = "claude.session@1", resetsIn: TimeInterval = 3600,
                 targets: [HandoffTarget] = [HandoffTarget(agent: "Codex CLI", percentLeft: nil)]) -> Handoff {
        Handoff(id: id, limitTitle: "Session (5h)", runsOutAt: now + 1200, resetsAt: now + resetsIn,
                targets: targets, sessionID: "c1", note: "note")
    }

    // MARK: The card is what decide returns, every time

    @Test func cardIsWhatDecideReturns() {
        var gate = HandoffGate()
        let first = handoff()
        #expect(gate.update(first, now: now).shown == first)
        // Same window, new readings: the new one shows, no stale copy is kept.
        let second = handoff(targets: [HandoffTarget(agent: "Copilot CLI", percentLeft: 45)])
        #expect(gate.update(second, now: now).shown == second)
    }

    @Test func clearsWhenDecideReturnsNil() {
        var gate = HandoffGate()
        _ = gate.update(handoff(), now: now)
        #expect(gate.update(nil, now: now).shown == nil)
    }

    @Test func peeksOncePerWindow() {
        var gate = HandoffGate()
        #expect(gate.update(handoff(), now: now).peek)
        #expect(!gate.update(handoff(), now: now).peek)
        // Gone at the one-hour edge and back: same window, no second peek.
        _ = gate.update(nil, now: now)
        #expect(!gate.update(handoff(), now: now).peek)
        #expect(gate.update(handoff("claude.session@2"), now: now).peek)
    }

    @Test func peekWithdrawnWhenCleared() {
        let shown = handoff()
        #expect(HandoffGate.keepsPeek(peekID: shown.id, shown: shown))
        #expect(!HandoffGate.keepsPeek(peekID: shown.id, shown: nil))
        #expect(!HandoffGate.keepsPeek(peekID: shown.id, shown: handoff("claude.session@2")))
    }

    @Test func laterHidesOnlyThatWindow() {
        var gate = HandoffGate()
        let first = handoff()
        _ = gate.update(first, now: now)
        gate.later(first)
        let hidden = gate.update(first, now: now)
        #expect(hidden.shown == nil)
        #expect(!hidden.peek)
        let next = handoff("claude.session@2")
        #expect(gate.update(next, now: now).shown == next)
    }

    @Test func laterForgottenAfterReset() {
        var gate = HandoffGate()
        let first = handoff(resetsIn: 600)
        _ = gate.update(first, now: now)
        gate.later(first)
        #expect(gate.remembered == 1)
        _ = gate.update(nil, now: now + 601)
        #expect(gate.remembered == 0)
    }

    // MARK: Inputs

    @Test func staleAntigravityIsUnmetered() {
        let quotas = [NotchQuota(agent: "Antigravity", percentLeft: 60, label: "Pro"),
                      NotchQuota(agent: "Copilot CLI", percentLeft: 45, label: "Premium")]
        let stale = HandoffInputs.make(quotas: quotas, antigravityUpdated: now - 20 * 60, installed: [], now: now)
        #expect(stale.others.map(\.agent) == ["Copilot CLI"])
        #expect(stale.unmetered == ["Antigravity"])
        let fresh = HandoffInputs.make(quotas: quotas, antigravityUpdated: now - 5 * 60, installed: [], now: now)
        #expect(fresh.others.map(\.agent) == ["Antigravity", "Copilot CLI"])
        #expect(fresh.unmetered.isEmpty)
    }

    @Test func installedAgentsWithoutReadingAreUnmetered() {
        let quotas = [NotchQuota(agent: "OpenCode", percentLeft: 70, label: "Go")]
        let inputs = HandoffInputs.make(quotas: quotas, antigravityUpdated: nil,
                                        installed: ["Codex CLI", "Gemini CLI", "OpenCode"], now: now)
        #expect(inputs.others.map(\.agent) == ["OpenCode"])
        #expect(inputs.unmetered == ["Codex CLI", "Gemini CLI"])
    }

    @Test func agentsWithoutPercentSayWhy() {
        let codex = HandoffTarget(agent: "Codex CLI", percentLeft: nil)
        let antigravity = HandoffTarget(agent: "Antigravity", percentLeft: nil)
        #expect(HandoffInputs.label(for: codex, antigravityUpdated: now - 40 * 60, now: now) == "limit not tracked")
        #expect(HandoffInputs.label(for: antigravity, antigravityUpdated: now - 40 * 60, now: now) == "checked 40m ago")
        #expect(HandoffInputs.label(for: antigravity, antigravityUpdated: nil, now: now) == "not checked yet")
        #expect(HandoffInputs.label(for: HandoffTarget(agent: "Copilot CLI", percentLeft: 44.6),
                                    antigravityUpdated: nil, now: now) == "45% left")
    }

    @Test func wakesWhenAntigravityReadingGoesStale() {
        let updated = now - 5 * 60
        let antigravity = [NotchQuota(agent: "Antigravity", percentLeft: 60, label: "Pro")]
        #expect(HandoffInputs.staleAt(antigravityUpdated: updated, others: antigravity)
                == updated + HandoffInputs.antigravityMaxAge)
        #expect(HandoffInputs.staleAt(antigravityUpdated: updated,
                                      others: [NotchQuota(agent: "Copilot CLI", percentLeft: 45, label: "")]) == nil)
        #expect(HandoffInputs.staleAt(antigravityUpdated: nil, others: antigravity) == nil)
    }

    // MARK: Clipboard

    @Test func copiedNoteIsBuiltFromTheLiveSession() {
        let shown = handoff()
        var session = AgentSession(id: "c1", agent: "Claude Code", cwd: "/Users/me/api", state: .working("Edit"), since: now)
        session.task = "Add rate limits"
        let note = HandoffPlanner.note(for: shown, sessions: [session])
        #expect(note.contains("Add rate limits"))
        #expect(note == HandoffPlanner.note(for: session, limitTitle: shown.limitTitle))
        // The session is gone: the note decide built.
        #expect(HandoffPlanner.note(for: shown, sessions: []) == shown.note)
    }

    @Test func pasteboardTypesAreSkippedByClipboardHistory() {
        #expect(HandoffPlanner.pasteboardTypes.contains("org.nspasteboard.ConcealedType"))
        #expect(HandoffPlanner.pasteboardTypes.contains("org.nspasteboard.TransientType"))
        #expect(!ClipHistory.shouldRecord(types: ["public.utf8-plain-text"] + HandoffPlanner.pasteboardTypes,
                                          app: nil, excluded: []))
    }
}

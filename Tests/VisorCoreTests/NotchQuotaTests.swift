import Foundation
import Testing
@testable import VisorCore

@Suite("Notch quotas")
struct NotchQuotaTests {
    @Test func emptyWhenNoUsage() {
        let quotas = NotchQuotaSummary.make(plan: nil, antigravity: nil, copilot: [])
        #expect(quotas.isEmpty)
    }

    @Test func singleClaudeQuota() {
        let plan = PlanUsage(limits: [
            PlanLimit(kind: "session", percentUsed: 16, resetsAt: nil)
        ])
        let quotas = NotchQuotaSummary.make(plan: plan, antigravity: nil, copilot: [])
        #expect(quotas.count == 1)
        #expect(quotas[0].agent == "Claude Code")
        #expect(quotas[0].percentLeft == 84)
        #expect(quotas[0].label == "Claude: 84% 5h session")
    }

    @Test func allThreeQuotasInStableOrder() {
        let plan = PlanUsage(limits: [
            PlanLimit(kind: "session", percentUsed: 20, resetsAt: nil)
        ])
        let antigravity = AntigravityUsage(limits: [
            AntigravityLimit(id: "gemini", title: "Gemini weekly", percentUsed: 38, resetsAt: nil)
        ])
        let copilot = [
            CopilotUsage(login: "octocat", plan: "business", host: "github.com",
                         premiumEntitlement: 100, premiumRemaining: 45, premiumUnlimited: false,
                         overagePermitted: false, overageUsed: 0, chatUnlimited: true,
                         completionsUnlimited: true, resetsAt: nil)
        ]

        let quotas = NotchQuotaSummary.make(plan: plan, antigravity: antigravity, copilot: copilot)
        #expect(quotas.map(\.agent) == ["Claude Code", "Antigravity", "Copilot CLI"])
        #expect(quotas[0].percentLeft == 80)
        #expect(quotas[1].percentLeft == 62)
        #expect(quotas[2].percentLeft == 45)
    }

    @Test func antigravityPicksLowestLimit() {
        let antigravity = AntigravityUsage(limits: [
            AntigravityLimit(id: "gemini", title: "Gemini weekly", percentUsed: 20, resetsAt: nil),
            AntigravityLimit(id: "3p", title: "Claude + GPT weekly", percentUsed: 75, resetsAt: nil)
        ])
        let quotas = NotchQuotaSummary.make(plan: nil, antigravity: antigravity, copilot: [])
        #expect(quotas.count == 1)
        #expect(quotas[0].agent == "Antigravity")
        #expect(quotas[0].percentLeft == 25)
        #expect(quotas[0].label.contains("25%"))
    }

    @Test func openCodeUsesItsLowestWindow() {
        let go = OpenCodeGoUsage(limits: [
            OpenCodeGoLimit(id: "rolling", title: "Session (5h)", percentUsed: 12, resetsAt: nil),
            OpenCodeGoLimit(id: "weekly", title: "Weekly", percentUsed: 34, resetsAt: nil),
            OpenCodeGoLimit(id: "monthly", title: "Monthly", percentUsed: 56, resetsAt: nil),
        ])
        let quotas = NotchQuotaSummary.make(plan: nil, antigravity: nil, copilot: [], openCode: go)
        #expect(quotas.map(\.agent) == ["OpenCode"])
        #expect(quotas[0].percentLeft == 44)
        #expect(quotas[0].label == "OpenCode: 44% monthly")
    }

    @Test func untrackedCopilotIsIgnored() {
        let freeCopilot = [
            CopilotUsage(login: "octocat", plan: "free", host: "github.com",
                         premiumEntitlement: 0, premiumRemaining: 0, premiumUnlimited: false,
                         overagePermitted: false, overageUsed: 0, chatUnlimited: false,
                         completionsUnlimited: false, resetsAt: nil)
        ]
        let quotas = NotchQuotaSummary.make(plan: nil, antigravity: nil, copilot: freeCopilot)
        #expect(quotas.isEmpty)
    }
}

@Suite("Notch ears")
struct NotchEarsTests {
    /// Every side: the content with the same gap to the notch and to the outer edge.
    @Test func widthIsContentWithTheSameInsetEachSide() {
        #expect(NotchEars.width(content: 12) == 12 + 2 * NotchEars.inset)
        #expect(NotchEars.width(content: 0) == 0, "nothing to show: no ear")
        #expect(NotchEars.width(content: 60) == 60 + 2 * NotchEars.inset)
        #expect(NotchEars.width(content: 60.2) == 77)
        #expect(NotchEars.width(content: 500) == NotchEars.maxWidth)
    }

    @Test func unevenEarsShiftTheShapeTowardTheWiderSide() {
        #expect(NotchEars.shift(left: 38, right: 100) == 31)
        #expect(NotchEars.shift(left: 100, right: 38) == -31)
        #expect(NotchEars.shift(left: 50, right: 50) == 0)
    }
}

@Suite("Open panel spacing")
struct PanelSpacingTests {
    /// Every open panel keeps the same room from its edges.
    @Test func oneInsetForEveryPanel() {
        #expect(NotchEars.panelInset == 18)
    }

    /// The Agents list grows with its rows: a 15 pt label per agent group,
    /// a 44 pt row per session, 6 pt between them, nothing left over.
    @Test func agentsListIsAsTallAsItsRows() {
        #expect(NotchEars.agentsList(groups: 1, sessions: 1) == 15 + 44 + 6)
        #expect(NotchEars.agentsList(groups: 2, sessions: 2) == 136)
        #expect(NotchEars.agentsList(groups: 2, sessions: 5) == 30 + 220 + 6 * 6)
    }
}

@Suite("Compact music panel")
struct CompactMusicTests {
    @Test func thirtyPercentWiderThanTheClosedNotch() {
        // Closed while playing: 300 + 2 × 38 + 2 × 6 = 388, and 1.3 × 388 = 505.
        #expect(NotchEars.musicWidth(notch: 300) == 505)
    }

    @Test func roomForTwoTabsEachSideBesideTheNotch() {
        // Two tabs (64), the panel inset (18) and a 6 pt gap to the notch,
        // plus the open flare (12), each side.
        #expect(NotchEars.musicWidth(notch: 174) == 174 + 2 * (64 + 18 + 6 + 12))
    }
}

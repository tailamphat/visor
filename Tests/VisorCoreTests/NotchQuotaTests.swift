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
    @Test func widthFitsContentWithinBounds() {
        #expect(NotchEars.width(content: 10) == NotchEars.minWidth)
        #expect(NotchEars.width(content: 60) == 60 + 2 * NotchEars.inset)
        #expect(NotchEars.width(content: 60.2) == 77)
        #expect(NotchEars.width(content: 500) == NotchEars.maxWidth)
    }

    @Test func quotaColumnsAreSpacedApart() {
        #expect(NotchEars.quotas(columns: []) == 0)
        #expect(NotchEars.quotas(columns: [20]) == 20)
        #expect(NotchEars.quotas(columns: [20, 22, 18]) == 72)
    }

    @Test func unevenEarsShiftTheShapeTowardTheWiderSide() {
        #expect(NotchEars.shift(left: 38, right: 100) == 31)
        #expect(NotchEars.shift(left: 100, right: 38) == -31)
        #expect(NotchEars.shift(left: 50, right: 50) == 0)
    }
}

@Suite("Compact music panel")
struct CompactMusicTests {
    @Test func thirtyPercentWiderThanTheClosedNotch() {
        // Closed while playing: 174 + 2 × 38 + 2 × 6 = 262.
        #expect(NotchEars.musicWidth(notch: 174) == 341)
    }

    @Test func neverTooNarrowForTwoTabsEachSide() {
        // 1.3 × 188 = 244, but two tabs (70) and the flare (12) each side need 264.
        #expect(NotchEars.musicWidth(notch: 100) == 264)
    }
}

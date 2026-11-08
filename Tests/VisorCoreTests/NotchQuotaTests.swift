import Foundation
import Testing
@testable import VisorCore

@Suite("Notch quotas")
struct NotchQuotaTests {
    @Test func emptyWhenNoUsage() {
        let quotas = NotchQuotaSummary.make(plan: nil, antigravity: nil, copilot: [])
        #expect(quotas.isEmpty)
        #expect(NotchQuotaSummary.earWidth(count: 0) == 38)
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
        #expect(NotchQuotaSummary.earWidth(count: 1) == 38)
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
        #expect(NotchQuotaSummary.earWidth(count: 2) == 74)
        #expect(NotchQuotaSummary.earWidth(count: 3) == 104)
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

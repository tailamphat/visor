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
    /// The capped list: a header, rows of two cards, the "more" row, and a line per folded tool.
    @Test func agentsDigestIsAsTallAsItsRows() {
        let card = NotchEars.agentCard, gap = 6.0
        #expect(NotchEars.agentsDigest(cards: 8, idleLines: 0) == 17 + gap + 4 * card + 3 * gap + gap + 30)
        #expect(NotchEars.agentsDigest(cards: 8, idleLines: 2) == 17 + gap + 4 * card + 3 * gap + gap + 30 + 2 * (gap + 26))
        #expect(NotchEars.agentsDigest(cards: 7, idleLines: 0) == NotchEars.agentsDigest(cards: 8, idleLines: 0))
    }

    /// Two cards a row per agent group, each with its header; the context ring
    /// sits inside the card, so it adds no height.
    @Test func agentsGridIsAsTallAsItsRows() {
        let card = NotchEars.agentCard, gap = 6.0
        #expect(NotchEars.agentsGrid(groupSizes: [1]) == 17 + gap + card)
        #expect(NotchEars.agentsGrid(groupSizes: [2]) == 17 + gap + card, "two sessions share a row")
        #expect(NotchEars.agentsGrid(groupSizes: [3]) == 17 + gap + 2 * card + gap)
        #expect(NotchEars.agentsGrid(groupSizes: [5, 1, 1]) == 3 * 17 + (3 + 1 + 1) * card + 2 * gap + 5 * gap)
        #expect(NotchEars.agentsGrid(groupSizes: []) == 0)
    }
}

@Suite("Compact music panel")
struct CompactMusicTests {
    @Test func thirtyPercentWiderThanTheClosedNotch() {
        // Closed while playing: 300 + 2 × 38 + 2 × 6 = 388, and 1.3 × 388 = 505.
        #expect(NotchEars.musicWidth(notch: 300) == 505)
    }

    @Test func roomForTwoTabsEachSideBesideTheNotch() {
        // Two tabs (64), the panel inset (18) and a 1 pt gap to the notch,
        // plus the open flare (12), each side.
        #expect(NotchEars.musicWidth(notch: 174) == 174 + 2 * (64 + 18 + 1 + 12))
    }

    /// With Plugins, three tabs right of the camera (Music, Clipboard, Plugins) at 22 pt, 4 apart.
    @Test func roomForThreeTabsWithPlugins() {
        let width = NotchEars.musicWidth(notch: 185, tabsRight: 3)
        let tabs: Double = 3 * 22 + 2 * 4
        let side = tabs + 18 + 4.5 + 12
        #expect(width == 185 + 2 * side)
        #expect(3 * NotchEars.musicTab.width + 2 * NotchEars.musicTab.spacing <= NotchEars.tabRoom(panel: width, notch: 185))
        #expect(NotchEars.musicWidth(notch: 185, tabsRight: 2) == NotchEars.musicWidth(notch: 185))
    }
}

@Suite("Open notch tabs")
struct NotchTabTests {
    /// Tabs sit left of the camera; however many there are, they fit in the room there.
    @Test func tabsFitBesideTheCamera() {
        let four = NotchEars.tabLayout(count: 4, room: 133.5)
        #expect(four.width == 30 && four.spacing == 4, "four tabs keep their full size")
        let five = NotchEars.tabLayout(count: 5, room: 133.5)
        #expect(five.width * 5 + five.spacing * 4 <= 133.5)
        #expect(five.width >= 24, "still a comfortable target")
        #expect(NotchEars.tabRoom(panel: 520, notch: 185) == 133.5)
    }

    /// An open panel slides toward its fuller side by half the difference, so icons
    /// packed from both outer edges end the same distance from the camera.
    @Test func openPanelSlidesTowardItsFullerSide() {
        #expect(NotchEars.shift(left: 48, right: 74) == 13, "music: 2 tabs left, 3 right")
        #expect(NotchEars.shift(left: 102, right: 92) == -5)
        let w = 402.0, camera = 185.0, left = 48.0, right = 74.0
        let shift = NotchEars.shift(left: left, right: right)
        // Sliding right takes room from the left side and gives it to the right; less its icons, the gaps match.
        let leftGap = (w - camera) / 2 - shift - left, rightGap = (w - camera) / 2 + shift - right
        #expect(leftGap == rightGap)
    }

    /// The 460 pt panel: four tabs a little narrower, still beside the camera.
    @Test func fourTabsFitTheNarrowPanel() {
        let room = NotchEars.tabRoom(panel: 460, notch: 185)
        let four = NotchEars.tabLayout(count: 4, room: room)
        #expect(four.width == 24 && four.spacing == 2)
        #expect(four.width * 4 + four.spacing * 3 <= room)
    }
}

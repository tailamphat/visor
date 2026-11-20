import Foundation

/// One agent quota displayed in the closed notch's right ear.
public struct NotchQuota: Equatable, Sendable, Identifiable {
    public var id: String { agent }
    public var agent: String
    public var percentLeft: Double
    public var label: String
    /// Seconds until it runs out at the current pace, when that's before it resets.
    public var runsOutIn: TimeInterval?

    public init(agent: String, percentLeft: Double, label: String, runsOutIn: TimeInterval? = nil) {
        self.agent = agent
        self.percentLeft = percentLeft
        self.label = label
        self.runsOutIn = runsOutIn
    }

    /// Runs out within the hour: worth slowing down, so the notch says when.
    public var runsOutSoon: Bool { runsOutIn.map { $0 < 3600 } ?? false }

    /// Under the mark: "42m" when it runs out soon, else "36%".
    public var text: String {
        if runsOutSoon, let runsOutIn, let time = BurnForecast.duration(runsOutIn) { return time }
        return "\(Int(percentLeft.rounded()))%"
    }

    public enum Level: Sendable { case normal, warning, critical }

    public var level: Level {
        if let runsOutIn, runsOutSoon { return runsOutIn < 15 * 60 ? .critical : .warning }
        return percentLeft <= 10 ? .critical : percentLeft <= 25 ? .warning : .normal
    }
}

/// Computes the list of quotas and ear width for the closed notch.
public enum NotchQuotaSummary {
    /// Creates the quotas to display on the notch right ear in stable order:
    /// Claude Code, Antigravity, Copilot CLI.
    public static func make(plan: PlanUsage?,
                            antigravity: AntigravityUsage?,
                            copilot: [CopilotUsage],
                            openCode: OpenCodeGoUsage? = nil,
                            forecast: (_ key: String, _ used: Double, _ resetsAt: Date?, _ window: TimeInterval?) -> BurnForecast? = { _, _, _, _ in nil },
                            now: Date = Date()) -> [NotchQuota] {
        var result: [NotchQuota] = []
        func runsOutIn(_ key: String, _ used: Double, _ resetsAt: Date?, _ window: TimeInterval?) -> TimeInterval? {
            guard case .runsOut(let at) = forecast(key, used, resetsAt, window) else { return nil }
            return at.timeIntervalSince(now)
        }

        // 1. Claude Code
        if let session = plan?.session {
            let left = session.percentLeft
            result.append(NotchQuota(agent: "Claude Code",
                                     percentLeft: left,
                                     label: "Claude: \(Int(left.rounded()))% 5h session",
                                     runsOutIn: runsOutIn(UsageKey.claude(session.kind), session.percentUsed, session.resetsAt,
                                                          BurnForecast.window(claude: session.kind))))
        } else if let first = plan?.limits.first {
            let left = first.percentLeft
            result.append(NotchQuota(agent: "Claude Code",
                                     percentLeft: left,
                                     label: "Claude: \(Int(left.rounded()))% \(first.title.lowercased())",
                                     runsOutIn: runsOutIn(UsageKey.claude(first.kind), first.percentUsed, first.resetsAt,
                                                          BurnForecast.window(claude: first.kind))))
        }

        // 2. Antigravity
        if let limits = antigravity?.limits, !limits.isEmpty {
            let lowest = limits.min(by: { $0.percentLeft < $1.percentLeft }) ?? limits[0]
            result.append(NotchQuota(agent: "Antigravity",
                                     percentLeft: lowest.percentLeft,
                                     label: "Antigravity: \(Int(lowest.percentLeft.rounded()))% \(lowest.title.lowercased())",
                                     runsOutIn: runsOutIn(UsageKey.antigravity(lowest.id), lowest.percentUsed, lowest.resetsAt, nil)))
        }

        // 3. Copilot CLI
        if let tracked = copilot.first(where: { $0.isTracked }) {
            let left = tracked.percentLeft
            result.append(NotchQuota(agent: "Copilot CLI",
                                     percentLeft: left,
                                     label: "Copilot: \(Int(left.rounded()))% premium requests",
                                     runsOutIn: tracked.premiumUnlimited ? nil
                                        : runsOutIn(UsageKey.copilot(tracked.host), 100 - left, tracked.resetsAt,
                                                    tracked.resetsAt.flatMap { BurnForecast.monthWindow(endingAt: $0) })))
        }

        // 4. OpenCode Go
        if let lowest = openCode?.lowest {
            let left = lowest.percentLeft
            result.append(NotchQuota(agent: "OpenCode",
                                     percentLeft: left,
                                     label: "OpenCode: \(Int(left.rounded()))% \(lowest.title.lowercased())",
                                     runsOutIn: runsOutIn(UsageKey.openCode(lowest.id), lowest.percentUsed, lowest.resetsAt,
                                                          BurnForecast.window(openCode: lowest.id, resetsAt: lowest.resetsAt))))
        }

        return result
    }
}

/// Each side of the closed notch is as wide as what it shows, within bounds,
/// so a single mark doesn't sit in an ear sized for four quotas.
public enum NotchEars {
    /// Room for the open panel's tabs left of the camera: half of what's
    /// beside the notch, less the panel's flare (12), inset and a small gap.
    public static func tabRoom(panel: Double, notch: Double) -> Double {
        (panel - notch) / 2 - 12 - panelInset - 4
    }

    /// Tab width and spacing so `count` tabs fit in `room`: full size (30, 4 apart)
    /// when they fit, else closer together and narrower. Past the room a tab
    /// would sit under the camera, where nobody can see it.
    public static func tabLayout(count: Int, room: Double) -> (width: Double, spacing: Double) {
        guard count > 0 else { return (30, 4) }
        let n = Double(count)
        if n * 30 + (n - 1) * 4 <= room { return (30, 4) }
        return (min(30, ((room - (n - 1) * 2) / n).rounded(.down)), 2)
    }

    public static let minWidth = 38.0
    /// Longer content (a project name) truncates instead of stretching the notch.
    public static let maxWidth = 140.0
    /// Room between the content and the hardware notch, the same on both sides.
    public static let inset = 8.0

    /// The content with `inset` on both sides, so every ear has the same room
    /// to the notch and to its outer edge. Nothing to show: no ear.
    public static func width(content: Double) -> Double {
        content > 0 ? min(maxWidth, (content + 2 * inset).rounded(.up)) : 0
    }

    /// How far right to move the shape so the hardware notch stays covered
    /// when one ear is wider than the other.
    public static func shift(left: Double, right: Double) -> Double {
        (right - left) / 2
    }

    /// Room between an open panel's content and its edges (sides and bottom),
    /// the same for every tab, so no panel looks cramped or loose.
    public static let panelInset = 18.0

    /// The Agents list's height: a 15 pt label per agent group and a 44 pt
    /// row per session, 6 pt apart. A row with a context bar is 15 pt taller.
    /// The Agents list: per group a 17 pt header (15 and 2 above), then rows of two cards; 6 pt
    /// between everything. The context ring is inside the card, so no extra line.
    public static func agentsGrid(groupSizes: [Int]) -> Double {
        guard !groupSizes.isEmpty else { return 0 }
        let gap = 6.0
        let blocks = groupSizes.map { size -> Double in
            let rows = Double((size + 1) / 2)
            return 17 + gap + rows * agentCard + max(rows - 1, 0) * gap
        }
        return blocks.reduce(0, +) + Double(groupSizes.count - 1) * gap
    }

    /// One session's card in the Agents list.
    public static let agentCard = 54.0

    /// Now Playing opened from the notch: 30% wider than the closed notch while
    /// music plays (two minimum ears and a 6 pt flare each side), but never too
    /// narrow for two tab buttons (64), the panel inset, a 6 pt gap to the
    /// notch and the open flare (12) each side.
    public static func musicWidth(notch: Double) -> Double {
        let closed = notch + 2 * minWidth + 2 * 6
        return max((closed * 1.3).rounded(.up), notch + 2 * (64 + panelInset + 1 + 12))
    }

    /// The music panel with `tabsRight` tabs right of the camera: with Plugins,
    /// three at 22 pt, 2 apart, so the panel stays narrow.
    public static func musicWidth(notch: Double, tabsRight: Int) -> Double {
        guard tabsRight > 2 else { return musicWidth(notch: notch) }
        let tabs = Double(tabsRight) * 22 + Double(tabsRight - 1) * 2
        return max(musicWidth(notch: notch), notch + 2 * (tabs + panelInset + 4.5 + 12))
    }
}

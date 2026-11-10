import Foundation

/// One agent quota displayed in the closed notch's right ear.
public struct NotchQuota: Equatable, Sendable, Identifiable {
    public var id: String { agent }
    public var agent: String
    public var percentLeft: Double
    public var label: String

    public init(agent: String, percentLeft: Double, label: String) {
        self.agent = agent
        self.percentLeft = percentLeft
        self.label = label
    }
}

/// Computes the list of quotas and ear width for the closed notch.
public enum NotchQuotaSummary {
    /// Creates the quotas to display on the notch right ear in stable order:
    /// Claude Code, Antigravity, Copilot CLI.
    public static func make(plan: PlanUsage?,
                            antigravity: AntigravityUsage?,
                            copilot: [CopilotUsage],
                            openCode: OpenCodeGoUsage? = nil) -> [NotchQuota] {
        var result: [NotchQuota] = []

        // 1. Claude Code
        if let session = plan?.session {
            let left = session.percentLeft
            result.append(NotchQuota(agent: "Claude Code",
                                     percentLeft: left,
                                     label: "Claude: \(Int(left.rounded()))% 5h session"))
        } else if let first = plan?.limits.first {
            let left = first.percentLeft
            result.append(NotchQuota(agent: "Claude Code",
                                     percentLeft: left,
                                     label: "Claude: \(Int(left.rounded()))% \(first.title.lowercased())"))
        }

        // 2. Antigravity
        if let limits = antigravity?.limits, !limits.isEmpty {
            let lowest = limits.min(by: { $0.percentLeft < $1.percentLeft }) ?? limits[0]
            result.append(NotchQuota(agent: "Antigravity",
                                     percentLeft: lowest.percentLeft,
                                     label: "Antigravity: \(Int(lowest.percentLeft.rounded()))% \(lowest.title.lowercased())"))
        }

        // 3. Copilot CLI
        if let tracked = copilot.first(where: { $0.isTracked }) {
            let left = tracked.percentLeft
            result.append(NotchQuota(agent: "Copilot CLI",
                                     percentLeft: left,
                                     label: "Copilot: \(Int(left.rounded()))% premium requests"))
        }

        // 4. OpenCode Go
        if let lowest = openCode?.lowest {
            let left = lowest.percentLeft
            result.append(NotchQuota(agent: "OpenCode",
                                     percentLeft: left,
                                     label: "OpenCode: \(Int(left.rounded()))% \(lowest.title.lowercased())"))
        }

        return result
    }
}

/// Each side of the closed notch is as wide as what it shows, within bounds,
/// so a single mark doesn't sit in an ear sized for four quotas.
public enum NotchEars {
    public static let minWidth = 38.0
    /// Longer content (a project name) truncates instead of stretching the notch.
    public static let maxWidth = 140.0
    /// Room between the content and the hardware notch, the same on both sides.
    public static let inset = 8.0

    public static func width(content: Double) -> Double {
        min(maxWidth, max(minWidth, (content + 2 * inset).rounded(.up)))
    }

    /// Quota columns side by side, 6 apart.
    public static func quotas(columns: [Double]) -> Double {
        columns.reduce(0, +) + Double(max(columns.count - 1, 0)) * 6
    }

    /// How far right to move the shape so the hardware notch stays covered
    /// when one ear is wider than the other.
    public static func shift(left: Double, right: Double) -> Double {
        (right - left) / 2
    }

    /// Now Playing opened from the notch: 30% wider than the closed notch while
    /// music plays (two minimum ears and a 6 pt flare each side), but never
    /// too narrow for two tab buttons (70) and the open flare (12) each side.
    public static func musicWidth(notch: Double) -> Double {
        let closed = notch + 2 * minWidth + 2 * 6
        return max((closed * 1.3).rounded(.up), notch + 2 * (70 + 12))
    }
}

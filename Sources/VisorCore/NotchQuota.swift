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
                            copilot: [CopilotUsage]) -> [NotchQuota] {
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

        return result
    }

    /// The ear width required to display the quotas comfortably without truncation.
    public static func earWidth(count: Int) -> Double {
        switch count {
        case 0: return 38
        case 1: return 38
        case 2: return 74
        default: return min(118, 74 + Double(count - 2) * 30)
        }
    }
}

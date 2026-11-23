import Foundation

/// Between `HandoffPlanner.decide` and the notch: shows exactly what decide
/// returns, minus a window the user put off with Later, and says when to peek
/// (once per limit window). It never keeps a handoff because it was shown: the
/// only memory is which windows were put off or peeked, each dropped once its
/// limit resets.
public struct HandoffGate: Sendable {
    /// Handoff id to its reset time.
    private var putOff: [String: Date] = [:]
    private var peeked: [String: Date] = [:]

    public init() {}

    /// Windows still remembered (Later or peeked), for tests.
    public var remembered: Int { Set(putOff.keys).union(peeked.keys).count }

    /// What to show for this decision, and whether to peek now.
    public mutating func update(_ decided: Handoff?, now: Date) -> (shown: Handoff?, peek: Bool) {
        putOff = putOff.filter { $0.value > now }
        peeked = peeked.filter { $0.value > now }
        guard let decided, putOff[decided.id] == nil else { return (nil, false) }
        let peek = peeked[decided.id] == nil
        peeked[decided.id] = decided.resetsAt
        return (decided, peek)
    }

    /// Later: hides this limit window only, until it resets.
    public mutating func later(_ handoff: Handoff) {
        putOff[handoff.id] = handoff.resetsAt
    }

    /// A handoff peek stays only while its handoff is still the one shown.
    public static func keepsPeek(peekID: String, shown: Handoff?) -> Bool {
        shown?.id == peekID
    }
}

/// The other agents `HandoffPlanner.decide` weighs, from what Visor reads now.
public enum HandoffInputs {
    /// Antigravity is read only when the Usage tab opens (`agy` is slow), so an
    /// older reading is not offered as room: it goes in without a percent.
    public static let antigravityMaxAge: TimeInterval = 15 * 60

    /// - Parameters:
    ///   - quotas: the notch's quotas (Claude, Antigravity, Copilot CLI, OpenCode).
    ///   - installed: agents on this Mac that may have no reading (Codex CLI, Gemini CLI, OpenCode).
    public static func make(quotas: [NotchQuota], antigravityUpdated: Date?, installed: [String],
                            now: Date) -> (others: [NotchQuota], unmetered: [String]) {
        let antigravityFresh = antigravityUpdated.map { now.timeIntervalSince($0) <= antigravityMaxAge } ?? false
        var others: [NotchQuota] = []
        var unmetered: [String] = []
        for quota in quotas {
            if quota.agent == "Antigravity" && !antigravityFresh {
                if !unmetered.contains(quota.agent) { unmetered.append(quota.agent) }
            } else {
                others.append(quota)
            }
        }
        for agent in installed where !others.contains(where: { $0.agent == agent }) && !unmetered.contains(agent) {
            unmetered.append(agent)
        }
        return (others, unmetered)
    }

    /// When an Antigravity reading offered as room turns stale, so the card is
    /// worked out again then, even if no other reading arrives.
    public static func staleAt(antigravityUpdated: Date?, others: [NotchQuota]) -> Date? {
        guard let antigravityUpdated, others.contains(where: { $0.agent == "Antigravity" }) else { return nil }
        return antigravityUpdated + antigravityMaxAge
    }
}

extension HandoffPlanner {
    /// The note as it stands now: the notch's copy of the sessions is published
    /// only on visible changes, so files and test runs may be newer here. The
    /// note decide built when the session is gone.
    public static func note(for handoff: Handoff, sessions: [AgentSession]) -> String {
        guard let session = sessions.first(where: { $0.id == handoff.sessionID }) else { return handoff.note }
        return note(for: session, limitTitle: handoff.limitTitle)
    }

    /// Written with the note so clipboard managers, Visor's own history
    /// included (`ClipHistory.secretTypes`), don't keep it: the task text is
    /// the user's own prompt.
    public static let pasteboardTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
}

import Foundation

/// A question an agent asked (Claude Code's AskUserQuestion), read from its hook
/// input. The terminal answers it; the notch only shows that it was asked.
public struct AgentQuestion: Equatable, Sendable {
    public static let tool = "AskUserQuestion"

    /// What the notch and the agent list call it: the question's header, else a trimmed question.
    public let label: String

    public init?(_ message: HookMessage) {
        guard message.toolName == Self.tool,
              let questions = message.toolInput["questions"] as? [[String: Any]] else { return nil }
        guard let first = questions.lazy.compactMap({ q -> (header: String, text: String)? in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            return (q["header"] as? String ?? "", text)
        }).first else { return nil }
        label = Self.label(header: first.header, text: first.text)
    }

    public static func label(header: String, text: String) -> String {
        if !header.isEmpty { return header }
        return text.count > 40 ? String(text.prefix(39)) + "…" : text
    }
}

/// An agent's turn that just ended, for the notch's "done" peek.
public struct FinishedTurn: Equatable, Sendable {
    public var agent: String
    public var project: String
    /// Seconds from the prompt to the end; nil when the prompt wasn't seen.
    public var duration: TimeInterval?

    public init(agent: String, project: String, duration: TimeInterval?) {
        self.agent = agent
        self.project = project
        self.duration = duration
    }

    public var durationText: String? { duration.map(Self.text(for:)) }

    /// "8s", "4m 12s", "1h 2m".
    public static func text(for seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}

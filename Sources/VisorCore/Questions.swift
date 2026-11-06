import Foundation

/// A multiple-choice question an agent asked (Claude Code's AskUserQuestion),
/// read from its hook input so the notch can show it.
public struct AgentQuestion: Identifiable, Equatable, Sendable {
    public static let tool = "AskUserQuestion"

    public struct Option: Equatable, Sendable {
        public var label: String
        public var detail: String?
    }

    public struct Item: Equatable, Sendable {
        /// A short tag, at most 12 characters: "Spend chart".
        public var header: String
        public var text: String
        public var options: [Option]
        public var multiSelect: Bool
    }

    public let id = UUID()
    public var sessionID: String
    public var agent: String
    public var project: String
    /// The agent's process, to find the terminal it runs in.
    public var pid: Int32
    public var items: [Item]

    public init?(_ message: HookMessage) {
        guard message.toolName == Self.tool, let session = message.sessionID,
              let questions = message.toolInput["questions"] as? [[String: Any]] else { return nil }
        items = questions.compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Option? in
                guard let label = o["label"] as? String else { return nil }
                let detail = (o["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return Option(label: label, detail: detail)
            }
            return Item(header: q["header"] as? String ?? "", text: text, options: options,
                        multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        guard !items.isEmpty else { return nil }
        sessionID = session
        agent = AgentBoard.agentName(message.provider)
        project = ((message.cwd ?? "") as NSString).lastPathComponent
        pid = message.pid
    }

    /// The answers to send, by question text, from the options picked per question
    /// (indexes into each question's options). Several picks join with ", ".
    public func answers(picks: [Int: Set<Int>]) -> [String: String] {
        var out: [String: String] = [:]
        for (index, item) in items.enumerated() {
            let labels = (picks[index] ?? []).sorted().compactMap { item.options.indices.contains($0) ? item.options[$0].label : nil }
            if !labels.isEmpty { out[item.text] = labels.joined(separator: ", ") }
        }
        return out
    }

    /// What the closed notch and the agent list call it: the first header, else the question.
    public var label: String {
        let first = items[0]
        if !first.header.isEmpty { return first.header }
        return first.text.count > 40 ? String(first.text.prefix(39)) + "…" : first.text
    }

    public static func == (a: AgentQuestion, b: AgentQuestion) -> Bool {
        a.sessionID == b.sessionID && a.items == b.items
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

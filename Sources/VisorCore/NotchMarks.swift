import Foundation

/// What the closed notch shows for agents: at most two marks, then "+N".
public struct NotchMarks: Equatable, Sendable {
    public struct Mark: Equatable, Sendable {
        public var agent: String
        public var count: Int
        public var attention: Attention?
        /// Its helpers (Claude Code only): the running count badge on the mark and the hover text.
        public var helperProgress = HelperProgress()
        public var helpers: Int { helperProgress.running }
        public var waiting: Bool { attention != nil }

        public init(agent: String, count: Int, attention: Attention?, helperProgress: HelperProgress = HelperProgress()) {
            self.agent = agent
            self.count = count
            self.attention = attention
            self.helperProgress = helperProgress
        }
    }
    public var shown: [Mark]
    /// Agents folded into the "+N" chip.
    public var more: [String]

    public init(shown: [Mark], more: [String]) {
        self.shown = shown
        self.more = more
    }

    /// Waiting agents come first in `activeAgents`, so they always get a slot.
    /// `approvalsFrom`: the agents whose approval cards are open; each is waiting for you.
    public static func make(_ board: AgentBoard, approvalsFrom: Set<String>) -> NotchMarks {
        var agents = board.activeAgents.map {
            Mark(agent: $0.agent, count: $0.count, attention: $0.attention, helperProgress: HelperProgress.of(board, agent: $0.agent))
        }
        for agent in approvalsFrom.sorted().reversed() {
            guard let i = agents.firstIndex(where: { $0.agent == agent }), agents[i].attention != .approval else { continue }
            var mark = agents.remove(at: i)
            mark.attention = .approval
            agents.insert(mark, at: 0)
        }
        return NotchMarks(shown: Array(agents.prefix(2)), more: agents.dropFirst(2).map(\.agent))
    }

}

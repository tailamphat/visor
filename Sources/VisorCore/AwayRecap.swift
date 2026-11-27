import Foundation

/// One thing that changed while the screen was locked: an agent waiting on
/// you, a Stuck warning, or a turn that finished.
public struct AwayItem: Equatable, Sendable, Identifiable {
    /// In the order the recap lists them: waiting on you first.
    public enum Kind: Int, Comparable, Sendable {
        case approval, question, stuck, finished

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var name: String {
            switch self {
            case .approval: return "approval"
            case .question: return "question"
            case .stuck: return "stuck"
            case .finished: return "finished"
            }
        }
    }

    public var kind: Kind
    public var session: String
    public var agent: String
    public var project: String
    /// The row's line: what it waits for, what loops, or the turn's facts.
    public var detail: String
    /// When it happened; the card shows it with `SessionText.ago`.
    public var at: Date
    /// For a Stuck item, the warning's id (session plus subagent).
    var key: String

    public var id: String { kind.name + "|" + key }
}

/// The recap shown after unlocking: what changed while away, waiting on you
/// first. In memory only; it shrinks as each item is handled.
public struct AwayDigest: Equatable, Sendable {
    /// Rows the card shows before "+n more".
    public static let maxRows = 4

    /// When the screen locked and unlocked.
    public var since: Date
    public var until: Date
    /// Approvals, questions, Stuck, finished; oldest first within each.
    public private(set) var items: [AwayItem]

    init(since: Date, until: Date, items: [AwayItem]) {
        self.since = since
        self.until = until
        self.items = items.sorted { ($0.kind, $0.at) < ($1.kind, $1.at) }
    }

    public var minutes: Int { max(0, Int(until.timeIntervalSince(since))) / 60 }
    public var title: String { "While you were away · \(minutes) min" }
    public var top: AwayItem? { items.first }
    public var count: Int { items.count }

    /// The first `limit` rows and how many are left over.
    public func rows(limit: Int) -> (rows: [AwayItem], more: Int) {
        (Array(items.prefix(limit)), max(0, items.count - limit))
    }

    /// Without one item (the primary button on the top one); nil once empty.
    public func removing(id: String) -> AwayDigest? {
        var next = self
        next.items.removeAll { $0.id == id }
        return next.items.isEmpty ? nil : next
    }

    /// Without the items that have been handled; nil once none are left.
    /// Approvals and questions go once that wait is over, Stuck once its
    /// warning clears, finished once its session works again or ends.
    public func pruned(board: AgentBoard, stuck: [Stuck]) -> AwayDigest? {
        let sessions = Dictionary(board.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let standing = Set(stuck.map(\.id))
        var next = self
        next.items.removeAll { item in
            switch item.kind {
            case .approval, .question:
                guard let session = sessions[item.session] else { return true }
                return Self.kind(of: session) != item.kind || session.since != item.at
            case .stuck:
                return !standing.contains(item.key)
            case .finished:
                guard let session = sessions[item.session] else { return true }
                return session.isActive
            }
        }
        return next.items.isEmpty ? nil : next
    }

    /// A finished turn's line from its summary facts: "Finished · 6 files · tests passed".
    public static func facts(_ stats: TurnStats) -> String {
        var parts = ["Finished"]
        let files = stats.files.count
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        switch stats.tests {
        case .passed: parts.append("tests passed")
        case .failed: parts.append("tests failed")
        case .ran: parts.append("tests ran")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }

    static func kind(of session: AgentSession) -> AwayItem.Kind? {
        switch session.state.attention {
        case .approval: return .approval
        case .question: return .question
        case nil: return nil
        }
    }
}

/// Keeps track of a screen lock: when it started and the turns that finished
/// during it. Driven only by the lock and unlock notifications and the events
/// Visor already gets; no timers, nothing on disk.
public struct AwayWatch: Sendable {
    /// Away for less than this gives no recap.
    public static let minimumAway: TimeInterval = 600

    public private(set) var lockedAt: Date?
    /// The latest finished turn per session while locked.
    private var finished: [String: (turn: FinishedTurn, at: Date)] = [:]

    public init() {}

    public var isLocked: Bool { lockedAt != nil }

    /// The screen locked. A second lock without an unlock keeps the first time.
    public mutating func lock(at now: Date) {
        if lockedAt == nil { lockedAt = now }
    }

    /// A turn finished; kept only while locked, the latest per session.
    public mutating func noteFinished(_ turn: FinishedTurn, at now: Date) {
        guard isLocked else { return }
        finished[turn.sessionID] = (turn, now)
    }

    /// The screen unlocked: the recap of what changed while it was locked, or
    /// nil when it was locked under ten minutes, wasn't locked, or nothing
    /// that still needs a look changed. Always starts over.
    public mutating func unlock(at now: Date, board: AgentBoard, stuck: [Stuck]) -> AwayDigest? {
        defer { lockedAt = nil; finished = [:] }
        guard let lockedAt, now.timeIntervalSince(lockedAt) >= Self.minimumAway else { return nil }
        var items: [AwayItem] = []
        var waiting: Set<String> = []
        for session in board.sessions where session.since >= lockedAt {
            guard let kind = AwayDigest.kind(of: session) else { continue }
            waiting.insert(session.id)
            items.append(AwayItem(kind: kind, session: session.id, agent: session.agent, project: session.project,
                                  detail: SessionText.detail(session), at: session.since, key: session.id))
        }
        for warning in stuck where warning.last >= lockedAt {
            let project = board.sessions.first { $0.id == warning.session }?.project ?? warning.agent
            items.append(AwayItem(kind: .stuck, session: warning.session, agent: warning.agent, project: project,
                                  detail: warning.label + " · " + warning.long, at: warning.last, key: warning.id))
        }
        for (id, entry) in finished where !waiting.contains(id) {
            items.append(AwayItem(kind: .finished, session: id, agent: entry.turn.agent, project: entry.turn.project,
                                  detail: AwayDigest.facts(entry.turn.stats), at: entry.at, key: id))
        }
        return AwayDigest(since: lockedAt, until: now, items: items).pruned(board: board, stuck: stuck)
    }
}

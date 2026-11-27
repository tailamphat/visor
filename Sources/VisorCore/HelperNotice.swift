import Foundation

/// What the closed notch says about an agent's helpers while they run: the
/// blue count on its mark, and "helpers 4 of 6 done" in the hover text.
/// Claude Code only: the only agent whose helpers Visor follows end to end.
public struct HelperProgress: Equatable, Sendable {
    public static let agent = "Claude Code"

    public var running = 0
    public var total = 0
    public var done: Int { total - running }

    public init(running: Int = 0, total: Int = 0) {
        self.running = running
        self.total = total
    }

    /// The badge on the mark: nothing while no helper runs, "9+" past nine.
    public var badge: String? { running == 0 ? nil : running > 9 ? "9+" : "\(running)" }
    /// Hover text over the current (or last) turn's helpers, nested ones included.
    public var text: String? { total == 0 ? nil : "helpers \(done) of \(total) done" }

    /// The agent's active sessions' helpers.
    /// The agent's sessions that are active or still have a helper running
    /// (a background helper outlives its turn's Stop).
    public static func of(_ board: AgentBoard, agent: String) -> HelperProgress {
        guard agent == Self.agent else { return HelperProgress() }
        var progress = HelperProgress()
        for session in board.sessions where session.agent == agent && (session.isActive || session.runningHelpers > 0) {
            progress.running += session.runningHelpers
            progress.total += session.helpers.count
        }
        return progress
    }

    /// The agents' hover text (closed marks and the open header's slot): each
    /// shown agent's session count, the folded ones, then the helpers' progress.
    public static func slotHelp(marks: NotchMarks, progress: HelperProgress) -> String {
        let agents = (marks.shown.map { "\($0.agent): \($0.count)" } + marks.more).joined(separator: ", ")
        return [agents, progress.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Helpers whose Agent call just failed: the 6 s peek. Finishing never peeks;
/// interrupts and a helper's own tools failing never mark it failed (`AgentBoard`).
public struct HelperFailure: Equatable, Sendable {
    public var session: String
    public var agent: String
    /// The latest few failed helpers' names (at most `keptNames`).
    public var names: [String]
    /// How many failed, all told.
    public var count: Int

    public init(session: String, agent: String, names: [String], count: Int? = nil) {
        self.session = session
        self.agent = agent
        self.names = Array(names.suffix(Self.keptNames))
        self.count = count ?? names.count
    }

    /// Names kept for the hover text once failures add up.
    static let keptNames = 3

    /// The longest name the closed notch shows before cutting it.
    static let nameLength = 16

    /// "perf helper failed", or "3 helpers failed" once several have.
    public var text: String {
        count == 1 ? "\(names.first ?? "Helper") helper failed" : "\(count) helpers failed"
    }

    /// Only this event can fail a helper, so the board is compared only then.
    public static func mayFail(_ message: HookMessage) -> Bool { message.event == "PostToolUseFailure" }

    /// A helper's name: its type, or its task when the type says nothing. Both
    /// come from hook payloads, so control and format characters (bidi
    /// overrides, zero-width marks) go and runs of whitespace become one space.
    static func name(_ helper: AgentHelper) -> String {
        let raw = helper.type == "general-purpose" || helper.type.isEmpty ? helper.task : helper.type
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                if let last = scalars.last, last != " " { scalars.append(" ") }
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse: continue
            default: scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Helper" }
        return name.count > nameLength ? String(name.prefix(nameLength - 1)) + "…" : name
    }

    /// Helpers failed in `after` that weren't in `before`, in the first session that has any.
    public static func new(before: AgentBoard, after: AgentBoard) -> HelperFailure? {
        for session in after.sessions where session.agent == HelperProgress.agent && session.helpers.contains(where: \.failed) {
            let old = before.sessions.first { $0.id == session.id }?.helpers ?? []
            let failedBefore = Set(old.filter(\.failed).map(\.id))
            let names = session.helpers.filter { $0.failed && !failedBefore.contains($0.id) }.map(name)
            if !names.isEmpty { return HelperFailure(session: session.id, agent: session.agent, names: names) }
        }
        return nil
    }

    /// A failure while another's peek shows: the same session's add up, another session's replaces it.
    public static func merge(shown: HelperFailure?, new: HelperFailure) -> HelperFailure {
        guard let shown, shown.session == new.session else { return new }
        return HelperFailure(session: new.session, agent: new.agent, names: shown.names + new.names, count: shown.count + new.count)
    }
}

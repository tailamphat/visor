import Foundation

/// When the "asks nothing" peek may show. It is the least urgent news in the
/// closed notch: it never cuts short a peek that comes only once (the away recap,
/// Stuck, a failed helper, the handoff, a release), and it is not used up while
/// it could not be seen (screen locked, notch open). A blocked peek is simply not
/// taken (`AgentBoard.takeModePeek`), so the session's next event tries again.
public enum ModePeekGate {
    /// What the closed notch shows now.
    public enum Showing: Sendable, Equatable {
        case nothing
        /// News that comes again on its own: a finished turn, "Answered", a plugin.
        case routine
        /// News that peeks once and never again.
        case oneTime
    }

    public static func shows(over showing: Showing, locked: Bool, expanded: Bool) -> Bool {
        !locked && !expanded && showing != .oneTime
    }
}

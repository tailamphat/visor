import Foundation

/// The words and times shown for a session, the same in the list and the office.
public enum SessionText {
    /// From this much context used, the session is about to compact: shown in amber.
    public static let contextWarning = 80.0

    public static func contextHigh(_ percent: Double?) -> Bool { (percent ?? 0) >= contextWarning }

    /// "0:38", "4:12", "1:05:09".
    public static func elapsed(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let h = seconds / 3600, m = seconds / 60 % 60, sec = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Short times for headings: "just now", "12s ago", "4m ago", "2h ago", "3d ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    /// How long it has been like this: a clock while it's busy or waiting, "5m ago" once it's done or idle.
    public static func time(_ session: AgentSession, now: Date = Date()) -> String {
        let clock = elapsed(since: session.since, now: now)
        switch session.state {
        case .needsApproval, .asking, .needsInput: return "Waiting \(clock)"
        case .working: return "Working \(clock)"
        case .done: return "Finished \(ago(session.since, now: now))"
        case .idle: return "Ready since \(ago(session.since, now: now))"
        }
    }

    /// What it's doing, in a line.
    public static func detail(_ session: AgentSession) -> String {
        switch session.state {
        case .idle: return "Ready"
        case .working(let what): return what == "Thinking" ? session.task.map { "Thinking · \($0)" } ?? what : what
        case .needsApproval(let what): return "Needs approval · \(what)"
        case .asking(let header): return "Asks you · \(header)"
        case .needsInput: return "Waiting for your reply"
        case .done: return "Finished"
        }
    }

    /// When a limit resets: "now", "in 2h 10m", "in 5m", or the weekday and time a day or more away.
    public static func reset(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        if seconds < 86_400 {
            let h = Int(seconds) / 3600, m = Int(seconds) % 3600 / 60
            return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

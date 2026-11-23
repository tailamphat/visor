import Foundation

/// An agent that could take over a task, and how much of its limit is left;
/// nil when Visor reads no limit for it (Codex, Gemini CLI).
public struct HandoffTarget: Equatable, Sendable {
    public var agent: String
    public var percentLeft: Double?

    public init(agent: String, percentLeft: Double?) {
        self.agent = agent
        self.percentLeft = percentLeft
    }
}

/// A Claude limit about to run out, the agents with room to carry on, and the
/// note to paste into one of them.
public struct Handoff: Equatable, Sendable {
    /// One per limit window ("claude.session@<reset minute>"), so a "Later"
    /// holds only until the window resets.
    public var id: String
    public var limitTitle: String
    /// When it runs out at the current pace; nil when it already has.
    public var runsOutAt: Date?
    public var resetsAt: Date
    /// Most room first; agents without a limit reading last.
    public var targets: [HandoffTarget]
    /// The Claude session the note is about.
    public var sessionID: String
    public var note: String
}

/// Decides whether a handoff should show, from current readings only. It keeps
/// no state: call it on every limit reading and session change and show exactly
/// what it returns, so a handoff ends by itself when the limit resets, the pace
/// recovers, another agent takes over or the session ends.
public enum HandoffPlanner {
    /// Runs out within this: the same line as the closed notch's `runsOutSoon`.
    public static let soon: TimeInterval = 3600
    /// Percent left an agent needs to be offered.
    public static let minimumRoom = 20.0
    /// The task text is the user's own prompt: one line, this long at most.
    public static let maxTask = 500
    public static let maxFiles = 10
    public static let maxPath = 120

    static let claude = "Claude Code"
    /// Limits that stop Claude Code; the model-only weeklies (Opus, Sonnet) don't.
    static let blocking: Set<String> = ["session", "five_hour", "weekly_all", "seven_day"]
    /// Characters a listed file name may hold; anything else (pipes, quotes,
    /// `$`, `;`) drops the entry, so a planted name can't read like a command.
    static let pathCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-/@+~,()[]#="))
    /// Token-shaped text in the task: GitHub, OpenAI/Anthropic, Slack and AWS
    /// keys, and long runs of letters and digits.
    static let secret = try! NSRegularExpression(pattern: [
        #"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{16,}"#,
        #"\bsk-[A-Za-z0-9_-]{16,}"#,
        #"\bxox[abposr]-[A-Za-z0-9-]{8,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\b(?=[A-Za-z0-9_+=-]*[0-9])(?=[0-9_+=-]*[A-Za-z])[A-Za-z0-9_+=-]{32,}"#,
    ].joined(separator: "|"))

    /// - Parameters:
    ///   - forecast: the pace of a limit, as `NotchQuotaSummary.make` takes it.
    ///   - others: the other agents' quotas; Claude's own is ignored.
    ///   - unmetered: agents available without a limit reading, in order.
    public static func decide(plan: PlanUsage?,
                              forecast: (_ key: String, _ used: Double, _ resetsAt: Date?, _ window: TimeInterval?) -> BurnForecast?,
                              others: [NotchQuota], unmetered: [String],
                              sessions: [AgentSession], now: Date = Date()) -> Handoff? {
        // Paid extra usage with room keeps Claude Code going.
        if let extra = plan?.extra, extra.limit.map({ extra.used < $0 }) ?? true { return nil }

        // 1. The Claude limit that runs out first, soon, before its reset; or one already out.
        var trigger: (limit: PlanLimit, resetsAt: Date, runsOutAt: Date?)?
        for limit in plan?.limits ?? [] where blocking.contains(limit.kind) {
            guard let resetsAt = limit.resetsAt, resetsAt > now else { continue }
            let runsOutAt: Date?
            if limit.percentUsed >= 100 {
                runsOutAt = nil
            } else if case .runsOut(let at) = forecast(UsageKey.claude(limit.kind), limit.percentUsed, resetsAt,
                                                       BurnForecast.window(claude: limit.kind)),
                      at < resetsAt, at.timeIntervalSince(now) < soon {
                runsOutAt = at
            } else {
                continue
            }
            if let current = trigger, (current.runsOutAt ?? now) <= (runsOutAt ?? now) { continue }
            trigger = (limit, resetsAt, runsOutAt)
        }
        guard let trigger else { return nil }

        // 2. Claude sessions another agent hasn't taken over: none works in
        // the same project, or has since Claude's last event. Finishing its
        // turn doesn't hand the task back.
        let open = sessions.filter { session in
            session.agent == claude && !sessions.contains { other in
                other.agent != claude && other.cwd == session.cwd && (other.isActive || other.lastEvent > session.lastEvent)
            }
        }
        // 3. The one to hand off: a working one first, then the latest.
        guard let session = open.max(by: { a, b in
            a.isActive != b.isActive ? !a.isActive : a.lastEvent < b.lastEvent
        }) else { return nil }

        // 4. Agents with room, most left first, then those without a reading.
        let metered = others.enumerated()
            .filter { $0.element.agent != claude && $0.element.percentLeft >= minimumRoom && !$0.element.runsOutSoon }
            .sorted { $0.element.percentLeft != $1.element.percentLeft ? $0.element.percentLeft > $1.element.percentLeft : $0.offset < $1.offset }
            .map { HandoffTarget(agent: $0.element.agent, percentLeft: $0.element.percentLeft) }
        var targets = metered
        for agent in unmetered where agent != claude && !others.contains(where: { $0.agent == agent })
            && !targets.contains(where: { $0.agent == agent }) {
            targets.append(HandoffTarget(agent: agent, percentLeft: nil))
        }
        guard !targets.isEmpty else { return nil }

        let title = trigger.limit.title
        // Rounded to 5 minutes: a reset time jittering by a second keeps the id.
        let window = Int((trigger.resetsAt.timeIntervalSince1970 / 300).rounded())
        return Handoff(id: "claude.\(trigger.limit.kind)@\(window)",
                       limitTitle: title, runsOutAt: trigger.runsOutAt, resetsAt: trigger.resetsAt,
                       targets: targets, sessionID: session.id, note: note(for: session, limitTitle: title))
    }

    /// The note for the clipboard: project, task, files touched and the last
    /// test outcome. Never commands, tool input or file contents.
    public static func note(for session: AgentSession, limitTitle: String) -> String {
        var lines = ["Handoff from Claude Code (\(oneLine(limitTitle)) limit runs out soon)."]
        let project = oneLine(session.project)
        lines.append(session.cwd.isEmpty ? "Project: \(project)" : "Project: \(project) (\(oneLine(session.cwd)))")
        if let task = session.task.map({ redact(oneLine($0)) }), !task.isEmpty {
            lines.append("Task: " + (task.count > maxTask ? String(task.prefix(maxTask - 1)) + "…" : task))
        }
        let turn = session.turn
        let (files, more) = turn.shortFiles(in: session.cwd, limit: maxFiles)
        let listed = files.filter { $0.unicodeScalars.allSatisfy(pathCharacters.contains) }
        if !listed.isEmpty {
            lines.append("Files touched:")
            for path in listed {
                lines.append("- " + (path.count > maxPath ? "…" + String(path.suffix(maxPath - 1)) : path))
            }
        }
        let skipped = more + files.count - listed.count
        if skipped > 0 { lines.append(listed.isEmpty ? "Files touched: \(skipped), not listed" : "- and \(skipped) more") }
        switch turn.tests {
        case .passed: lines.append("Last test run: passed")
        case .failed: lines.append("Last test run: failed")
        case .ran: lines.append("Last test run: started, no result yet")
        case nil: break
        }
        lines.append("Please continue this task: read the files above first.")
        return lines.joined(separator: "\n")
    }

    /// Token-shaped text becomes "[redacted]".
    static func redact(_ text: String) -> String {
        secret.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]")
    }

    /// Control characters and line breaks become spaces, runs of spaces one.
    static func oneLine(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : Character($0) }
        return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

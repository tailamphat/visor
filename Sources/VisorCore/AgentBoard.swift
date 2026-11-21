import Foundation

public enum AgentState: Equatable, Sendable, Codable {
    case idle
    case working(String)
    case needsApproval(String)
    /// Asked you a multiple-choice question (AskUserQuestion); its header.
    case asking(String)
    case needsInput
    case done

    /// What the agent needs from you, if anything.
    public var attention: Attention? {
        switch self {
        case .needsApproval: return .approval
        case .asking, .needsInput: return .question
        case .idle, .working, .done: return nil
        }
    }
}

/// Why an agent is waiting for you: an approval blocks it, a question wants an answer.
public enum Attention: Int, Comparable, Sendable {
    case approval, question

    public static func < (a: Attention, b: Attention) -> Bool { a.rawValue < b.rawValue }
}

public struct AgentSession: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var pid: Int32
    public var cwd: String
    public var state: AgentState
    /// When the current state began.
    public var since: Date
    public var lastEvent: Date
    /// Which agent this is, e.g. "Claude Code".
    public var agent = "Claude Code"
    /// The app it runs in (Ghostty, VS Code, ...), filled in by the app.
    public var host: String?
    /// The last thing the user asked it, to tell sessions in one project apart.
    public var task: String?
    /// When the user last sent it a prompt: the start of the current turn.
    public var turnStart: Date?
    /// The last finished turn ended by asking you something ("Should I commit?").
    public var askedForReply = false
    /// What it did this turn (files, lines, commands, tests). Optional so
    /// sessions saved by older versions still load.
    var turnStats: TurnStats?
    public var turn: TurnStats {
        get { turnStats ?? TurnStats() }
        set { turnStats = newValue }
    }
    /// Subagents it started this turn. Optional so older saved sessions load.
    var helperList: [AgentHelper]?
    public var helpers: [AgentHelper] {
        get { helperList ?? [] }
        set { helperList = newValue.isEmpty ? nil : newValue }
    }
    public var runningHelpers: Int { helpers.filter { !$0.done }.count }
    /// Kept per session; past this, the oldest finished helpers go first.
    public static let maxHelpers = 20

    /// The helpers to list, running first then the latest finished, and how many didn't fit.
    public func helperRows(limit: Int) -> (rows: [AgentHelper], more: Int) {
        let ordered = helpers.filter { !$0.done } + helpers.filter(\.done).reversed()
        return (Array(ordered.prefix(limit)), max(0, ordered.count - limit))
    }
    /// Tokens in its context window after the last reply, and the window's size.
    public var contextTokens: Int?
    public var contextWindow: Int?

    /// How full the context window is, 0-100; nil when unknown.
    public var contextPercent: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(100, Double(contextTokens) / Double(contextWindow) * 100)
    }

    public var project: String {
        let name = (cwd as NSString).lastPathComponent
        if !name.isEmpty { return name }
        return agent == "Claude Code" ? "Claude" : agent
    }

    public var isActive: Bool {
        switch state {
        case .working, .needsApproval, .asking, .needsInput: return true
        case .idle, .done: return false
        }
    }
}

/// Turns hook events into a list of Claude Code sessions and what each is doing.
public struct AgentBoard: Equatable, Sendable {
    public private(set) var sessions: [AgentSession] = []

    public init() {}

    public var working: Int { sessions.filter { if case .working = $0.state { return true } else { return false } }.count }
    public var waiting: Int { sessions.filter { $0.state.attention != nil }.count }

    public mutating func apply(_ message: HookMessage, now: Date = Date()) {
        guard let id = message.sessionID else { return }
        if message.event == "SessionEnd" {
            sessions.removeAll { $0.id == id }
            return
        }
        let index: Int
        if let found = sessions.firstIndex(where: { $0.id == id }) {
            index = found
        } else {
            var session = AgentSession(id: id, pid: message.pid, cwd: message.cwd ?? "", state: .idle,
                                       since: now, lastEvent: now)
            session.agent = Self.agentName(message.provider)
            sessions.append(session)
            index = sessions.count - 1
        }
        if let cwd = message.cwd, !cwd.isEmpty { sessions[index].cwd = cwd }
        if message.pid > 0 { sessions[index].pid = message.pid }
        sessions[index].lastEvent = now
        sessions[index].turn.record(message)
        if applyHelper(message, at: index, now: now) { return }

        let next: AgentState?
        switch message.event {
        case "SessionStart": next = .idle
        case "UserPromptSubmit":
            if let prompt = message.payload["prompt"] as? String { sessions[index].task = Self.summarize(prompt) }
            sessions[index].turnStart = now
            sessions[index].turn = TurnStats()
            sessions[index].helpers.removeAll(where: \.done)
            next = .working("Thinking")
        case "PreInvocation": next = .working("Thinking")
        case "PreToolUse" where message.toolName == AgentQuestion.tool,
             "PermissionRequest" where message.toolName == AgentQuestion.tool:
            next = .asking(AgentQuestion(message)?.label ?? "Question")
        case "PreToolUse": next = .working(Self.describe(tool: message.toolName, input: message.toolInput))
        case "PostToolUse", "PostToolUseFailure": next = .working(Self.waitLine(sessions[index].runningHelpers))
        case "PermissionRequest": next = .needsApproval(Self.describe(tool: message.toolName, input: message.toolInput))
        case "Notification":
            let kind = message.payload["notification_type"] as? String ?? ""
            let text = (message.payload["message"] as? String ?? "").lowercased()
            if kind == "idle_prompt" || text.contains("waiting for your input") {
                // Claude Code says this about a minute after every finished turn;
                // it only waits for a reply when the turn ended by asking one.
                next = sessions[index].state == .done && !sessions[index].askedForReply ? nil : .needsInput
            } else if kind == "permission_prompt" || text.contains("permission") {
                // Visor's own card already shows this when its hook asked; a question's permission step is still the question.
                switch sessions[index].state {
                case .needsApproval, .asking: next = nil
                default: next = .needsApproval("Needs permission")
                }
            } else {
                next = nil
            }
        case "Stop":
            sessions[index].askedForReply = Self.asksForReply(message.payload["last_assistant_message"] as? String ?? "")
            next = .done
        default: next = nil
        }
        if let next, next != sessions[index].state {
            sessions[index].state = next
            sessions[index].since = now
        }
    }

    /// Subagent bookkeeping. Returns true when the event was a helper's own
    /// (its tools, its start and stop), which leaves the parent's line alone
    /// except to count the helpers it waits on.
    private mutating func applyHelper(_ message: HookMessage, at index: Int, now: Date) -> Bool {
        var session = sessions[index]
        defer { sessions[index] = session }
        let agentID = message.payload["agent_id"] as? String
        let isTask = message.toolName == "Task" || message.toolName == "Agent"
        let toolUseID = message.payload["tool_use_id"] as? String
        switch message.event {
        case "PreToolUse" where isTask && agentID == nil:
            let input = message.toolInput
            session.helpers.append(AgentHelper(id: toolUseID ?? UUID().uuidString, type: input["subagent_type"] as? String ?? "general-purpose",
                                               task: (input["description"] as? String).flatMap(Self.summarize) ?? "Helper",
                                               background: input["run_in_background"] as? Bool ?? false))
            Self.trim(&session.helpers)
            setWaiting(&session, now: now)
            return true
        case "PostToolUse" where isTask && agentID == nil, "PostToolUseFailure" where isTask && agentID == nil:
            // A foreground Task returns when its helper is done; a background one returns at once.
            if let i = session.helpers.lastIndex(where: { $0.id == toolUseID }) ?? session.helpers.firstIndex(where: { !$0.done && !$0.background && $0.agentID == nil }),
               !session.helpers[i].background {
                session.helpers[i].done = true
            }
            return false
        case "SubagentStart":
            guard let agentID else { return true }
            let type = message.payload["agent_type"] as? String
            if let i = session.helpers.firstIndex(where: { $0.agentID == nil && !$0.done && $0.type == type })
                ?? session.helpers.firstIndex(where: { $0.agentID == nil && !$0.done }) {
                session.helpers[i].agentID = agentID
            } else {
                session.helpers.append(AgentHelper(id: agentID, type: type ?? "general-purpose", task: type ?? "Helper"))
                session.helpers[session.helpers.count - 1].agentID = agentID
                Self.trim(&session.helpers)
            }
            setWaiting(&session, now: now)
            return true
        case "SubagentStop":
            if let i = session.helpers.firstIndex(where: { $0.agentID == agentID && agentID != nil })
                ?? session.helpers.firstIndex(where: { !$0.done }) {
                session.helpers[i].done = true
                session.helpers[i].activity = nil
            }
            setWaiting(&session, now: now)
            return true
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            guard let agentID, let i = session.helpers.firstIndex(where: { $0.agentID == agentID }) else { return agentID != nil }
            session.helpers[i].activity = message.event == "PreToolUse" ? Self.describe(tool: message.toolName, input: message.toolInput) : nil
            return true
        default:
            return false
        }
    }

    /// While helpers run, the parent's line counts them instead of echoing their tools.
    private func setWaiting(_ session: inout AgentSession, now: Date) {
        let line = AgentState.working(Self.waitLine(session.runningHelpers))
        switch session.state {
        case .working: if session.state != line { session.state = line }
        case .idle where session.runningHelpers > 0, .done where session.runningHelpers > 0: session.state = line; session.since = now
        default: break
        }
    }

    static func waitLine(_ running: Int) -> String {
        running == 0 ? "Thinking" : "Waiting on \(running) helper\(running == 1 ? "" : "s")"
    }

    /// Keeps at most `maxHelpers`, dropping the oldest finished ones first.
    static func trim(_ helpers: inout [AgentHelper]) {
        while helpers.count > AgentSession.maxHelpers, let i = helpers.firstIndex(where: \.done) { helpers.remove(at: i) }
        if helpers.count > AgentSession.maxHelpers { helpers.removeFirst(helpers.count - AgentSession.maxHelpers) }
    }

    /// Whether a reply ends by asking something: its last character, past
    /// closing markdown and quotes, is a question mark.
    static func asksForReply(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_`\"')]")))
        return trimmed.hasSuffix("?") || trimmed.hasSuffix("？")
    }

    /// The user answered an approval; the agent carries on.
    public mutating func resolveApproval(session id: String, now: Date = Date()) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), case .needsApproval = sessions[i].state else { return }
        sessions[i].state = .working("Thinking")
        sessions[i].since = now
    }

    /// An approval Visor held was answered in the terminal instead: allowed,
    /// the agent runs what it asked for; denied, Claude Code stops the turn.
    public mutating func answeredInTerminal(session id: String, allowed: Bool, now: Date = Date()) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), case .needsApproval(let what) = sessions[i].state else { return }
        sessions[i].state = allowed ? .working(what) : .idle
        sessions[i].since = now
    }

    /// The sessions, to restore after Visor restarts: agents only speak when
    /// something happens, so an idle one would stay missing until its next turn.
    public func saved() throws -> Data { try JSONEncoder().encode(sessions) }

    /// Sessions saved before a restart whose agent is still running. Working
    /// and approving may have ended meanwhile, so they start idle until the
    /// next event; a question or a finished turn still waits for you.
    public static func restored(from data: Data, isAlive: (Int32) -> Bool) -> AgentBoard {
        var board = AgentBoard()
        board.sessions = ((try? JSONDecoder().decode([AgentSession].self, from: data)) ?? []).filter { $0.pid > 0 && isAlive($0.pid) }
        for i in board.sessions.indices {
            switch board.sessions[i].state {
            case .working, .needsApproval: board.sessions[i].state = .idle
            case .idle, .asking, .needsInput, .done: break
            }
        }
        return board
    }

    /// Drops sessions whose Claude Code process has exited.
    public mutating func prune(isAlive: (Int32) -> Bool) {
        sessions.removeAll { $0.pid > 0 && !isAlive($0.pid) }
    }

    public static func agentName(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude Code"
        case "copilot": return "Copilot CLI"
        case "antigravity": return "Antigravity"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// Agents with something going on, in the order the closed notch shows them:
    /// anyone waiting for you first, then Claude Code, Copilot CLI, Antigravity.
    /// Approvals before questions: an approval blocks the agent.
    public var activeAgents: [(agent: String, count: Int, attention: Attention?)] {
        var groups: [String: (count: Int, attention: Attention?)] = [:]
        for session in sessions where session.isActive {
            var group = groups[session.agent] ?? (0, nil)
            group.count += 1
            if let attention = session.state.attention { group.attention = min(group.attention ?? attention, attention) }
            groups[session.agent] = group
        }
        let order = ["Claude Code": 0, "Copilot CLI": 1, "Antigravity": 2]
        let rank = { (a: Attention?) in a?.rawValue ?? 9 }
        return groups.map { ($0.key, $0.value.count, $0.value.attention) }
            .sorted { a, b in
                rank(a.attention) != rank(b.attention) ? rank(a.attention) < rank(b.attention)
                    : (order[a.agent] ?? 9, a.agent) < (order[b.agent] ?? 9, b.agent)
            }
    }

    /// The turn a Stop event ends: which agent, which project, and how long it took.
    public func finished(_ message: HookMessage, now: Date = Date()) -> FinishedTurn? {
        guard message.event == "Stop", let id = message.sessionID,
              let session = sessions.first(where: { $0.id == id }) else { return nil }
        return FinishedTurn(agent: session.agent, project: session.project,
                            duration: session.turnStart.map { now.timeIntervalSince($0) },
                            sessionID: session.id, cwd: session.cwd, stats: session.turn)
    }

    /// The first line of a prompt, short enough for one row.
    public static func summarize(_ prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// Records the app a session runs in.
    /// A session's context after a reply. Once a session shows it has the 1M
    /// window it keeps it, even after compacting back under 200k.
    public mutating func setContext(tokens: Int?, model: String?, session id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].contextTokens = tokens
        if let tokens {
            sessions[i].contextWindow = max(sessions[i].contextWindow ?? 0, ContextUsage.window(tokens: tokens, model: model))
        }
    }

    public mutating func setHost(_ host: String?, session id: String) {
        guard let host, let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].host != host else { return }
        sessions[i].host = host
    }

    /// A short, human description of a tool call, e.g. "Bash: npm test".
    public static func describe(tool: String?, input: [String: Any]) -> String {
        guard let tool else { return "Working" }
        func first(_ keys: String...) -> String? {
            for key in keys { if let v = input[key] as? String, !v.isEmpty { return v } }
            return nil
        }
        let detail: String?
        switch tool {
        case "Bash": detail = first("description", "command")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            detail = first("file_path", "notebook_path").map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob": detail = first("pattern")
        case "WebFetch": detail = first("url").flatMap { URL(string: $0)?.host }
        case "WebSearch": detail = first("query")
        case "Task", "Agent": detail = first("description")
        default: detail = nil
        }
        guard let detail else { return tool }
        let line = detail.split(separator: "\n").first.map(String.init) ?? detail
        return "\(tool): \(line.count > 60 ? String(line.prefix(59)) + "…" : line)"
    }
}

extension AgentBoard {
    /// Whether anything shown in the notch differs. The last-event time moves
    /// on every tool call but is never shown, so it alone doesn't count.
    public func differsVisibly(from other: AgentBoard) -> Bool {
        guard sessions.count == other.sessions.count else { return true }
        return zip(sessions, other.sessions).contains { a, b in
            a.id != b.id || a.cwd != b.cwd || a.state != b.state || a.since != b.since
                || a.agent != b.agent || a.host != b.host || a.task != b.task
                || a.contextPercent.map { Int($0) } != b.contextPercent.map { Int($0) }
                || a.helperList != b.helperList
        }
    }
}

extension AgentSession {
    /// A session built by hand: for previews such as the office world thumbnails.
    public init(id: String, agent: String, cwd: String, state: AgentState, since: Date = Date()) {
        self.init(id: id, pid: 0, cwd: cwd, state: state, since: since, lastEvent: since)
        self.agent = agent
    }
}

/// A subagent a session started: its task (from the Task call), its type, and
/// what it's doing now (from its own tool events, which carry `agent_id`).
public struct AgentHelper: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var agentID: String?
    public var type: String
    public var task: String
    public var activity: String?
    public var done = false
    public var background = false

    public init(id: String, type: String, task: String, done: Bool = false, background: Bool = false) {
        self.id = id; self.type = type; self.task = task; self.done = done; self.background = background
    }
}

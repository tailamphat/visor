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
    /// Running helpers the session itself started: what its line says it waits on.
    var waitingOn: Int { helperList?.reduce(0) { $0 + ($1.done || $1.parent != nil ? 0 : 1) } ?? 0 }
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
    /// What it has cost so far, from its transcript (`SessionCostReader`).
    public var cost: SessionCost?
    /// What its harness put in the context before the first prompt (Claude Code), from
    /// its first reply. Optional so older saved sessions load.
    public var xray: HarnessXRay?

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
            // A running helper whose finished parent just went is now one the session waits on.
            let kept = Set(sessions[index].helpers.compactMap(\.agentID))
            for i in sessions[index].helpers.indices where sessions[index].helpers[i].parent.map({ !kept.contains($0) }) ?? false {
                sessions[index].helpers[i].parent = nil
            }
            next = .working("Thinking")
        case "PreInvocation": next = .working("Thinking")
        case "PreToolUse" where message.toolName == AgentQuestion.tool,
             "PermissionRequest" where message.toolName == AgentQuestion.tool:
            next = .asking(AgentQuestion(message)?.label ?? "Question")
        case "PreToolUse": next = .working(Self.describe(tool: message.toolName, input: message.toolInput))
        case "PostToolUse", "PostToolUseFailure": next = .working(Self.waitLine(sessions[index].waitingOn))
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
    /// except to count the helpers it waits on. A helper's own Agent call
    /// (Claude Code puts the helper's `agent_id` on it) starts a nested helper.
    private mutating func applyHelper(_ message: HookMessage, at index: Int, now: Date) -> Bool {
        var session = sessions[index]
        defer { sessions[index] = session }
        let agentID = Self.hookID(message.payload["agent_id"])
        let isTask = message.toolName == "Task" || message.toolName == "Agent"
        let toolUseID = Self.hookID(message.payload["tool_use_id"])
        // Nesting is Claude Code's; other agents' helper events keep the old handling.
        let ownCall = isTask && (agentID == nil || session.agent == "Claude Code")
        switch message.event {
        case "PreToolUse" where ownCall:
            let input = message.toolInput
            if let agentID, let p = session.helpers.firstIndex(where: { $0.agentID == agentID }) {
                session.helpers[p].activity = Self.describe(tool: message.toolName, input: input)
            }
            var helper = AgentHelper(id: toolUseID ?? UUID().uuidString, type: Self.hookID(input["subagent_type"]) ?? "general-purpose",
                                     task: (input["description"] as? String).flatMap(Self.summarize) ?? "Helper",
                                     background: input["run_in_background"] as? Bool ?? false)
            helper.parent = agentID
            helper.start = now
            session.helpers.append(helper)
            Self.trim(&session.helpers)
            setWaiting(&session, now: now)
            return true
        case "PostToolUse" where ownCall, "PostToolUseFailure" where ownCall:
            // A foreground Task returns when its helper is done; a background one returns at once.
            // Only a failure of the Agent call itself fails the helper; an interrupt is you stopping it.
            let failed = message.event == "PostToolUseFailure" && (message.payload["is_interrupt"] as? Bool) != true
            if let i = session.helpers.lastIndex(where: { $0.id == toolUseID })
                ?? session.helpers.firstIndex(where: { !$0.done && !$0.background && $0.agentID == nil && $0.parent == agentID }) {
                if failed { session.helpers[i].failed = true }
                if failed || !session.helpers[i].background { Self.finish(&session.helpers[i], now: now) }
            }
            guard let agentID else { return false }
            if let p = session.helpers.firstIndex(where: { $0.agentID == agentID }) { session.helpers[p].activity = nil }
            setWaiting(&session, now: now)
            return true
        case "SubagentStart":
            guard let agentID else { return true }
            let type = Self.hookID(message.payload["agent_type"])
            if let i = session.helpers.firstIndex(where: { $0.agentID == nil && !$0.done && $0.type == type })
                ?? session.helpers.firstIndex(where: { $0.agentID == nil && !$0.done }) {
                session.helpers[i].agentID = agentID
            } else {
                var helper = AgentHelper(id: agentID, type: type ?? "general-purpose", task: type ?? "Helper")
                helper.agentID = agentID
                helper.start = now
                session.helpers.append(helper)
                Self.trim(&session.helpers)
            }
            setWaiting(&session, now: now)
            return true
        case "SubagentStop":
            // A stop for an agent no row knows only finishes a helper not linked to another agent.
            if let i = session.helpers.firstIndex(where: { $0.agentID == agentID && agentID != nil })
                ?? session.helpers.firstIndex(where: { !$0.done && (agentID == nil || $0.agentID == nil) }) {
                Self.finish(&session.helpers[i], now: now)
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

    /// An id or type from a hook, capped so a hostile payload can't grow saved sessions.
    static func hookID(_ value: Any?) -> String? {
        (value as? String).map { $0.count > 128 ? String($0.prefix(128)) : $0 }
    }

    /// Marks a helper done; the first end it gets is its end time.
    static func finish(_ helper: inout AgentHelper, now: Date) {
        helper.done = true
        if helper.end == nil { helper.end = now }
    }

    /// Moves `agentID` onto the helper started by the Agent call `toolUseID`
    /// (from `agent-<id>.meta.json`), swapping with the row that took it by order.
    /// What arrived under the agent id (its line, its stop) moves with it; a
    /// failure came by tool_use_id, so it is already on the right row.
    public mutating func link(session id: String, agentID: String, toolUseID: String) {
        let agentID = Self.hookID(agentID) ?? agentID
        guard let s = sessions.firstIndex(where: { $0.id == id }),
              let target = sessions[s].helpers.firstIndex(where: { $0.id == toolUseID }),
              sessions[s].helpers[target].agentID != agentID else { return }
        var helpers = sessions[s].helpers
        if let other = helpers.firstIndex(where: { $0.agentID == agentID }) {
            helpers[other].agentID = helpers[target].agentID
            (helpers[other].activity, helpers[target].activity) = (helpers[target].activity, helpers[other].activity)
            (helpers[other].done, helpers[target].done) = (helpers[target].done, helpers[other].done)
            (helpers[other].end, helpers[target].end) = (helpers[target].end, helpers[other].end)
        }
        helpers[target].agentID = agentID
        sessions[s].helpers = helpers
    }

    /// While helpers run, the parent's line counts them instead of echoing their tools.
    private func setWaiting(_ session: inout AgentSession, now: Date) {
        let line = AgentState.working(Self.waitLine(session.waitingOn))
        switch session.state {
        case .working: if session.state != line { session.state = line }
        case .idle where session.waitingOn > 0, .done where session.waitingOn > 0: session.state = line; session.since = now
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
            // A saved count may be from before a compact or /clear; the next read sets it.
            board.sessions[i].contextTokens = nil
            // The cost may have grown meanwhile; the next read counts it again.
            board.sessions[i].cost = nil
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
        case "codex": return "Codex CLI"
        case "opencode": return "OpenCode"
        case "gemini": return "Gemini CLI"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// Agents with something going on, in the order the closed notch shows them:
    /// anyone waiting for you first, then Claude Code, Copilot CLI, Antigravity,
    /// Codex CLI, OpenCode, Gemini CLI.
    /// Approvals before questions: an approval blocks the agent.
    public var activeAgents: [(agent: String, count: Int, attention: Attention?)] {
        var groups: [String: (count: Int, attention: Attention?)] = [:]
        for session in sessions where session.isActive {
            var group = groups[session.agent] ?? (0, nil)
            group.count += 1
            if let attention = session.state.attention { group.attention = min(group.attention ?? attention, attention) }
            groups[session.agent] = group
        }
        let order = ["Claude Code": 0, "Copilot CLI": 1, "Antigravity": 2, "Codex CLI": 3, "OpenCode": 4, "Gemini CLI": 5]
        let rank = { (a: Attention?) in a?.rawValue ?? 9 }
        return groups.map { ($0.key, $0.value.count, $0.value.attention) }
            .sorted { a, b in
                rank(a.attention) != rank(b.attention) ? rank(a.attention) < rank(b.attention)
                    : (order[a.agent] ?? 9, a.agent) < (order[b.agent] ?? 9, b.agent)
            }
    }

    /// One agent's sessions as read from its own files (Codex CLI, OpenCode, Gemini CLI)
    /// and chosen by `FileAgentTracker`, in place of whatever the board had for
    /// that agent; hook agents are left alone. A state that didn't change keeps
    /// its `since`. Returns the turns that finished since the last sync, for the "Finished" peek.
    public mutating func sync(agent: String, scanned: [ScannedSession]) -> [FinishedTurn] {
        let shown = scanned.filter { $0.agent == agent }
        var finished: [FinishedTurn] = []
        var updated: [String: AgentSession] = [:]
        for read in shown {
            let before = sessions.first { $0.id == read.id && $0.agent == agent }
            var session = before ?? AgentSession(id: read.id, pid: read.pid, cwd: read.cwd, state: read.state,
                                                 since: read.lastActivity, lastEvent: read.lastActivity)
            session.agent = agent
            session.cwd = read.cwd
            // Another process (or none): the host app is looked up again.
            if session.pid != read.pid { session.host = nil }
            session.pid = read.pid
            session.task = read.task
            session.turnStart = read.turnStart
            session.askedForReply = read.askedForReply
            session.lastEvent = read.lastActivity
            if let before, before.state != read.state {
                if before.state.isWorking, read.state == .done {
                    finished.append(FinishedTurn(agent: agent, project: session.project,
                                                 duration: read.turnStart.map { read.lastActivity.timeIntervalSince($0) },
                                                 sessionID: read.id, cwd: read.cwd))
                }
                session.state = read.state
                session.since = max(read.lastActivity, before.since)
            }
            updated[read.id] = session
        }
        var kept: [AgentSession] = []
        for session in sessions {
            if session.agent != agent {
                kept.append(session)
            } else if let next = updated.removeValue(forKey: session.id) {
                kept.append(next)
            }
        }
        kept += shown.compactMap { updated[$0.id] }
        sessions = kept
        return finished
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
    public mutating func setContext(tokens: Int?, model: String?, provenWindow: Int? = nil, session id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].contextTokens = tokens
        if let provenWindow { sessions[i].contextWindow = max(sessions[i].contextWindow ?? 0, provenWindow) }
        if let tokens {
            sessions[i].contextWindow = max(sessions[i].contextWindow ?? 0, ContextUsage.window(tokens: tokens, model: model))
        }
    }

    /// A session's cost so far, as read from its transcript.
    public mutating func setCost(_ cost: SessionCost?, session id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].cost = cost
    }

    /// Each helper's stats by agent id; a helper whose meta names its Agent call is linked
    /// to it first. Written only when a value changed.
    public mutating func setHelperStats(_ stats: [String: HelperStats], session id: String) {
        for (agentID, st) in stats.sorted(by: { $0.key < $1.key }) {
            if let toolUse = st.toolUseID { link(session: id, agentID: agentID, toolUseID: toolUse) }
        }
        guard let s = sessions.firstIndex(where: { $0.id == id }) else { return }
        for i in sessions[s].helpers.indices {
            guard let agentID = sessions[s].helpers[i].agentID, let st = stats[agentID],
                  sessions[s].helpers[i].stats != st else { continue }
            sessions[s].helpers[i].stats = st
        }
    }

    /// The session's harness X-ray: the first one stays, later reads can't change it.
    public mutating func setXRay(_ xray: HarnessXRay, session id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].xray == nil else { return }
        sessions[i].xray = xray
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
    /// Helpers differ in what shows; their stats count only in displayed form.
    static func helpersDiffer(_ a: [AgentHelper]?, _ b: [AgentHelper]?) -> Bool {
        guard a?.count == b?.count else { return true }
        return zip(a ?? [], b ?? []).contains { x, y in
            var x = x, y = y
            let shown = x.stats?.shown != y.stats?.shown
            x.stats = nil; y.stats = nil
            return shown || x != y
        }
    }

    public func differsVisibly(from other: AgentBoard) -> Bool {
        guard sessions.count == other.sessions.count else { return true }
        return zip(sessions, other.sessions).contains { a, b in
            a.id != b.id || a.cwd != b.cwd || a.state != b.state || a.since != b.since
                || a.agent != b.agent || a.host != b.host || a.task != b.task
                || a.contextPercent.map { Int($0) } != b.contextPercent.map { Int($0) }
                || Self.helpersDiffer(a.helperList, b.helperList) || a.cost?.label != b.cost?.label || a.xray != b.xray
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

/// A subagent a session started: its task (from the Task call), its type,
/// what it's doing now (from its own tool events, which carry `agent_id`),
/// which helper started it, when it ran and whether its Agent call failed.
/// The newer fields are optional so older saved sessions load.
public struct AgentHelper: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var agentID: String?
    public var type: String
    public var task: String
    public var activity: String?
    public var done = false
    public var background = false
    /// The agent id of the helper that started it; nil for the session's own.
    public var parent: String?
    /// When its Agent call (or, without one, its SubagentStart) arrived, and when it ended.
    public var start: Date?
    public var end: Date?
    /// Cost, model, context and tool counts from its own transcript.
    public var stats: HelperStats?
    /// Its Agent call failed (PostToolUseFailure, not an interrupt); its own tools failing doesn't count.
    var failedFlag: Bool?
    public var failed: Bool {
        get { failedFlag ?? false }
        set { failedFlag = newValue ? true : nil }
    }

    public init(id: String, type: String, task: String, done: Bool = false, background: Bool = false) {
        self.id = id; self.type = type; self.task = task; self.done = done; self.background = background
    }
}

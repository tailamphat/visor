import SwiftUI
import VisorCore

struct AgentsView: View {
    let model: AppModel

    var body: some View {
        // The cards' one clock: ticks only while the list is on screen.
        VStack(spacing: 6) {
            if let clash = model.clashes.first { ClashBanner(clash: clash, sessions: model.board.sessions) { model.dismissClash?(clash) } }
            content
        }
        .onReceive(Timer.publish(every: 1, tolerance: 0.2, on: .main, in: .common).autoconnect()) { model.agentsNow = $0 }
        .onAppear { model.mcpShown?() }
    }

    @ViewBuilder private var content: some View {
        // Worked out once per update; the list below reads them several times.
        let digest = AgentsDigest(sessions: model.board.sessions)
        let groups = Self.groups(model.board.sessions)
        if !model.hooksInstalled && !model.antigravityHooksInstalled && model.board.sessions.isEmpty {
            EmptyState(symbol: "link", title: "Connect your agents",
                       detail: "Adds Visor hooks so the notch can see Claude Code, Copilot CLI and Antigravity sessions, and ask you for approvals.",
                       button: "Connect") { model.installHooks?() }
        } else if model.board.sessions.isEmpty {
            EmptyState(symbol: "sparkles", title: "No agents running",
                       detail: "Start claude, copilot or agy in a terminal and it shows up here.")
        } else if digest.capped && !model.agentsShowAll {
            ScrollView(.vertical, showsIndicators: false) { self.digest(digest) }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    // Grouped by agent, Claude Code first; within a group, who needs you first.
                    ForEach(groups, id: \.agent) { group in
                        HStack(spacing: 6) {
                            AgentMark(agent: group.agent, size: 11)
                            Text("\(group.agent) · \(group.sessions.count)")
                                .font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).tracking(0.6)
                                .foregroundStyle(Theme.textMuted)
                            if group.agent == groups.first?.agent {
                                Spacer(minLength: 8)
                                AwakeCup(model: model).padding(.trailing, 6)
                                AgentsViewSwitch(model: model)
                            }
                        }
                        .frame(height: 15)
                        .padding(.top, 2)
                        // Two cards a row.
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            ForEach(group.sessions) { AgentCard(session: $0, focus: model.focusAgent, model: model, clashWith: Self.clash(for: $0, in: model.clashes)) }
                        }
                        helpers(in: group.sessions)
                    }
                    if digest.capped {
                        foldRow(Text("Show fewer").fontWeight(.semibold).foregroundStyle(Theme.question), dashed: true) {
                            model.agentsShowAll = false
                        }
                    }
                    MCPSection(model: model)
                    if !model.hooksInstalled {
                        Button("Connect Claude Code for approvals") { model.installHooks?() }
                            .buttonStyle(PillButton(fill: Theme.accent)).padding(.top, 4)
                    }
                }
            }
        }
    }

    /// The open helpers list, under the cards of the group its session is in.
    @ViewBuilder private func helpers(in sessions: [AgentSession]) -> some View {
        if let id = model.helpersOpen, let session = sessions.first(where: { $0.id == id }), !session.helpers.isEmpty {
            HelpersList(session: session)
        }
    }

    /// The open helpers list's session, if it's still there and has helpers.
    static func openHelpers(_ model: AppModel) -> AgentSession? {
        guard let id = model.helpersOpen else { return nil }
        return model.board.sessions.first { $0.id == id && !$0.helpers.isEmpty }
    }

    /// Many sessions: whoever needs you, then the busiest, then the most recent, as
    /// cards (at most 8); the rest in one row, and idle ones folded per tool.
    private func digest(_ digest: AgentsDigest) -> some View {
        let waiting = model.board.sessions.filter { $0.state.attention != nil }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(model.board.sessions.count) agents" + (waiting > 0 ? " · \(waiting) need\(waiting == 1 ? "s" : "") you" : ""))
                    .font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Theme.textMuted)
                Spacer(minLength: 8)
                AwakeCup(model: model).padding(.trailing, 6)
                                AgentsViewSwitch(model: model)
            }
            .frame(height: 15)
            .padding(.top, 2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(digest.top) { AgentCard(session: $0, focus: model.focusAgent, model: model, clashWith: Self.clash(for: $0, in: model.clashes)) }
            }
            helpers(in: digest.top)
            foldRow(HStack(spacing: 8) {
                Text("+\(digest.more) more").fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                Text(digest.byTool.map { "\($0.count) \($0.agent)" }.joined(separator: " · "))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 6)
                Text("Show all").fontWeight(.semibold).foregroundStyle(Theme.question)
            }, height: 30) { model.agentsShowAll = true }
            ForEach(digest.idle, id: \.agent) { line in
                foldRow(HStack(spacing: 6) {
                    AgentMark(agent: line.agent, size: 10)
                    Text("\(line.count) idle \(line.agent) session\(line.count == 1 ? "" : "s") folded").foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 6)
                    Text("show").foregroundStyle(Theme.question)
                }, dashed: true) { model.agentsShowAll = true }
            }
            MCPSection(model: model)
        }
    }

    /// A full-width row that does one thing: the "more" row, a folded tool, "Show fewer".
    private func foldRow<Label: View>(_ label: Label, height: CGFloat = 26, dashed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(dashed ? Color.clear : Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(dashed ? Color.white.opacity(0.12) : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The other agent on the same file as `session`, if any.
    static func clash(for session: AgentSession, in clashes: [Clash]) -> String? {
        clashes.lazy.compactMap { $0.other(than: session.id) }.first
    }

    static func groups(_ sessions: [AgentSession]) -> [(agent: String, sessions: [AgentSession])] {
        let rank = ["Claude Code": 0, "Copilot CLI": 1, "Antigravity": 2]
        return Dictionary(grouping: sessions, by: \.agent)
            .map { ($0.key, $0.value.sorted(by: Self.order)) }
            .sorted { (rank[$0.agent] ?? 9, $0.agent) < (rank[$1.agent] ?? 9, $1.agent) }
    }

    /// Sessions that need you first, then busy ones, then the rest by recency.
    static func order(_ a: AgentSession, _ b: AgentSession) -> Bool {
        func rank(_ s: AgentSession) -> Int {
            switch s.state {
            case .needsApproval, .asking, .needsInput: return 0
            case .working: return 1
            case .done: return 2
            case .idle: return 3
            }
        }
        return rank(a) != rank(b) ? rank(a) < rank(b) : a.lastEvent > b.lastEvent
    }
}

/// List or office: two small buttons, on the first group's line in the list
/// and in the room's corner in the office.
struct AgentsViewSwitch: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            option("list.bullet", office: false, help: "Show as a list")
            option("gamecontroller.fill", office: true, help: "Show as an office")
        }
        .padding(1)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func option(_ symbol: String, office: Bool, help: String) -> some View {
        let on = model.agentsOffice == office
        return Button { model.agentsOffice = office } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textMuted)
                .frame(width: 24, height: 15)
                .background(Capsule().fill(on ? Color.white.opacity(0.16) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The orange ⇄ that marks two agents on the same file.
struct ClashBadge: View {
    var body: some View {
        Text("⇄").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(Color(hex: 0x2A1200))
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Theme.clash))
    }
}

/// Over the Agents list while two agents change the same file: which file, and ✕ to dismiss.
struct ClashBanner: View {
    let clash: Clash
    let sessions: [AgentSession]
    let dismiss: () -> Void
    static let height: CGFloat = 32

    var body: some View {
        HStack(spacing: 8) {
            ClashBadge()
            (Text("Both are editing ") + Text(shortPath).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.textPrimary))
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.textMuted)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.clash.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.clash.opacity(0.35), lineWidth: 1))
        .help("\(clash.agents.joined(separator: " and ")) both edited \(clash.path)")
    }

    /// The path inside the project, when the file is in one of the two sessions' folders.
    private var shortPath: String {
        for id in clash.sessions {
            if let cwd = sessions.first(where: { $0.id == id })?.cwd, !cwd.isEmpty, clash.path.hasPrefix(cwd + "/") {
                return String(clash.path.dropFirst(cwd.count + 1))
            }
        }
        return (clash.path as NSString).lastPathComponent
    }
}

/// A card's time from the list's one clock: elapsed while busy, "4m ago" after.
/// Only this small view redraws each second, not the card.
struct AgentClock: View {
    let session: AgentSession
    let model: AppModel

    var body: some View {
        if session.isActive {
            Text(SessionText.elapsed(since: session.since, now: model.agentsNow))
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textMuted)
        } else {
            Text(SessionText.ago(session.since, now: model.agentsNow))
                .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted).lineLimit(1).fixedSize()
        }
    }
}

/// One session in the Agents list: the agent's round tile inside a ring that
/// shows how full its context is (amber from 80%, with the percent under it),
/// then the project and time, the app, and what it's doing. Half the panel wide.
struct AgentCard: View {
    let session: AgentSession
    var focus: ((AgentSession) -> Void)?
    /// For the shared clock (`AppModel.agentsNow`).
    var model: AppModel?
    /// Another agent changing the same file as this session right now.
    var clashWith: String?

    var body: some View {
        HStack(spacing: 9) {
            ringTile
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.project).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    time
                }
                if let clashWith {
                    Text("⇄ \(clashWith) too")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.clash).lineLimit(1)
                } else {
                    HStack(spacing: 4) {
                        Text([session.agent, session.host].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(1)
                        if let model, !session.helpers.isEmpty {
                            Spacer(minLength: 0)
                            HelpersButton(session: session, model: model)
                        }
                    }
                    .frame(height: 13)
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: NotchEars.agentCard)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(needsYou ? Theme.warning.opacity(0.35) : clashWith != nil ? Theme.clash.opacity(0.45) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { focus?(session) }
        .help(help)
    }

    private var needsYou: Bool {
        session.state.attention != nil
    }

    private var help: String {
        var lines: [String] = []
        if let host = session.host { lines.append("Open \(host)") }
        if let percent = session.contextPercent {
            lines.append("\(Int(percent))% context: \((session.contextTokens ?? 0).formatted()) of \((session.contextWindow ?? 0).formatted()) tokens"
                         + (SessionText.contextHigh(percent) ? ", compacts soon" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// The tile in its context ring, the status dot on its corner, and the percent from 80%.
    private var ringTile: some View {
        let percent = session.contextPercent
        let high = SessionText.contextHigh(percent)
        return ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 2.5)
            if let percent {
                Circle().trim(from: 0, to: max(0.02, min(1, percent / 100)))
                    .stroke(high ? Theme.warning : Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            ZStack {
                Circle().fill(AgentStyle.tile)
                AgentMark(agent: session.agent, size: 14)
            }
            .frame(width: 24, height: 24)
        }
        .frame(width: 34, height: 34)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(dotColor).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Theme.raised, lineWidth: 2))
                .offset(x: 1, y: 1)
        }
        .overlay(alignment: .bottom) {
            if high, let percent {
                Text("\(Int(percent))%")
                    .font(.system(size: 8.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.warning)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.raised))
                    .offset(y: 7)
            }
        }
    }

    /// Elapsed or relative time, on the project line.
    @ViewBuilder private var time: some View {
        if let model { AgentClock(session: session, model: model) }
    }

    private var dotColor: Color {
        switch session.state {
        case .working: return ConsentButton.mint
        case .needsApproval: return Theme.warning
        case .asking, .needsInput: return Theme.question
        case .done, .idle: return Theme.textMuted
        }
    }

    private var detail: String {
        switch session.state {
        case .idle: return "Ready"
        case .working(let what): return what == "Thinking" ? session.task.map { "Thinking · \($0)" } ?? what : what
        case .needsApproval(let what): return "Needs approval · \(what)"
        case .asking(let header): return "Asks you · \(header)"
        case .needsInput: return "Waiting for your reply"
        case .done: return "Finished"
        }
    }
}

import SwiftUI
import VisorCore

private typealias Spec = DesignComponents

struct AgentsView: View {
    let model: AppModel
    /// From `NotchLayout.agentsDigest`, so the list folds exactly as the panel's size counts it.
    let digest: AgentsDigest

    var body: some View {
        // The cards' one clock: ticks only while the list is on screen.
        VStack(spacing: 6) {
            if let key = model.keyAlerts.first { KeyBanner(alert: key, model: model) }
            if let away = model.away { AwayRecapBanner(away: away, model: model) }
            if let handoff = model.handoff { HandoffBanner(handoff: handoff, model: model) }
            if let stuck = model.stuck.first {
                StuckBanner(stuck: stuck, session: model.board.sessions.first { $0.id == stuck.session }, model: model)
            }
            if let clash = model.clashes.first { ClashBanner(clash: clash, sessions: model.board.sessions) { model.dismissClash?(clash) } }
            content
        }
        .onReceive(Timer.publish(every: 1, tolerance: 0.2, on: .main, in: .common).autoconnect()) { model.agentsNow = $0 }
        .onAppear { model.mcpShown?() }
    }

    @ViewBuilder private var content: some View {
        // Worked out once per update; the list below reads them several times.
        let groups = digest.groups
        if !model.hooksInstalled && !model.antigravityHooksInstalled && model.board.sessions.isEmpty {
            EmptyState(symbol: "link", title: "Connect your agents",
                       detail: "Adds Visor hooks so the notch can see Claude Code, Copilot CLI and Antigravity sessions, and ask you for approvals.",
                       button: "Connect") { model.installHooks?() }
        } else if model.board.sessions.isEmpty {
            EmptyState(symbol: "sparkles", title: "No agents running",
                       detail: "Start claude, copilot or agy in a terminal and it shows up here.")
        } else if digest.capped && !model.agentsShowAll {
            scrolling { digestList(digest) }
        } else {
            scrolling {
                VStack(alignment: .leading, spacing: 6) {
                    // Grouped by agent, Claude Code first; within a group, who needs you first.
                    ForEach(groups, id: \.agent) { group in
                        HStack(spacing: 6) {
                            AgentMark(agent: group.agent, size: 11)
                            SectionHeader("\(group.agent) · \(group.sessions.count)")
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
                            cards(group.sessions)
                        }
                        helpers(in: group.sessions)
                    }
                    if digest.capped {
                        foldRow(Text("Show fewer").fontWeight(.semibold).foregroundStyle(Theme.question), dashed: true) {
                            model.agentsShowAll = false
                        }
                    }
                    MCPSection(model: model)
                    HarnessSection(model: model)
                    if !model.hooksInstalled {
                        Button("Connect Claude Code for approvals") { model.installHooks?() }
                            .buttonStyle(PillButton(fill: Theme.accent)).padding(.top, 4)
                    }
                }
            }
        }
    }

    /// The list scrolls when even its shortest fold and everything around it pass the tallest
    /// panel; its last line is then reachable with its bottom padding (debug: `"scrollEnd":true`).
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let list = content()
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    list
                    Color.clear.frame(height: 0).id(Self.listEnd)
                }
            }
            .onChange(of: model.agentsScrollEnd) { _, _ in proxy.scrollTo(Self.listEnd, anchor: .bottom) }
        }
    }

    private static let listEnd = "agents-list-end"

    /// Cards in rows of two; both cards of a row with a cache line grow with it.
    private func cards(_ sessions: [AgentSession]) -> some View {
        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
            AgentCard(session: session, focus: model.focusAgent, model: model, clashWith: Self.clash(for: session, in: model.clashes),
                      stuck: Self.stuck(for: session, in: model.stuck), tall: AgentBoard.cacheRowTall(sessions, index: index))
        }
    }

    /// The open helpers list, under the cards of the group its session is in.
    @ViewBuilder private func helpers(in sessions: [AgentSession]) -> some View {
        if let id = model.helpersOpen, let session = sessions.first(where: { $0.id == id }), HelperWaterfall.shows(session) {
            HelpersList(session: session, model: model)
        }
    }

    /// The open helpers list's session, if it's still there and has helpers.
    static func openHelpers(_ model: AppModel) -> AgentSession? {
        guard let id = model.helpersOpen else { return nil }
        return model.board.sessions.first { $0.id == id && HelperWaterfall.shows($0) }
    }

    /// Many sessions: whoever needs you, then the busiest, then the most recent, as
    /// cards (at most 8); the rest in one row, and idle ones folded per tool.
    private func digestList(_ digest: AgentsDigest) -> some View {
        let waiting = model.board.sessions.filter { $0.state.attention != nil }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionHeader("\(model.board.sessions.count) agents" + (waiting > 0 ? " · \(waiting) need\(waiting == 1 ? "s" : "") you" : ""))
                Spacer(minLength: 8)
                AwakeCup(model: model).padding(.trailing, 6)
                                AgentsViewSwitch(model: model)
            }
            .frame(height: 15)
            .padding(.top, 2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                cards(digest.top)
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
            HarnessSection(model: model)
        }
    }

    /// A full-width row that does one thing: the "more" row, a folded tool, "Show fewer".
    private func foldRow<Label: View>(_ label: Label, height: CGFloat = 26, dashed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(DS.font(.base))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(dashed ? Color.clear : DS.Fill.faint))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(dashed ? DS.Fill.medium : .clear, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The other agent on the same file as `session`, if any.
    static func clash(for session: AgentSession, in clashes: [Clash]) -> String? {
        clashes.lazy.compactMap { $0.other(than: session.id) }.first
    }

    /// The warning standing for `session`, if it's going round in circles.
    static func stuck(for session: AgentSession, in stuck: [Stuck]) -> Stuck? {
        stuck.first { $0.session == session.id }
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
        .background(Capsule().fill(DS.Fill.subtle))
    }

    private func option(_ symbol: String, office: Bool, help: String) -> some View {
        let on = model.agentsOffice == office
        return Button { model.agentsOffice = office } label: {
            Image(systemName: symbol)
                .font(DS.font(.xs, .semibold))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textMuted)
                .frame(width: 24, height: 15)
                .background(Capsule().fill(on ? DS.Fill.strong : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The orange ⇄ that marks two agents on the same file.
struct ClashBadge: View {
    var body: some View {
        Text("⇄").font(DS.font(.xs, .heavy)).foregroundStyle(Theme.surface)
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(Theme.clash))
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
            (Text("Both are editing ") + Text(shortPath).font(DS.font(.base, design: .monospaced)).foregroundColor(Theme.textPrimary))
                .font(DS.font(.base)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            DismissButton(action: dismiss)
        }
        .compactBanner(tint: Theme.clash, height: Self.height)
        .help("\(clash.agents.joined(separator: " and ")) both edited \(KeyShapes.redactedOnce(clash.path))")
    }

    /// The path inside the project, when the file is in one of the two sessions' folders.
    private var shortPath: String {
        for id in clash.sessions {
            if let cwd = sessions.first(where: { $0.id == id })?.cwd, !cwd.isEmpty, clash.path.hasPrefix(cwd + "/") {
                return KeyShapes.redactedOnce(String(clash.path.dropFirst(cwd.count + 1)))
            }
        }
        return KeyShapes.redactedOnce((clash.path as NSString).lastPathComponent)
    }
}

/// Over the Agents list while an agent keeps failing or repeating the same call:
/// who, what and the latest error line, with Ignore and Open (its terminal).
struct StuckBanner: View {
    let stuck: Stuck
    let session: AgentSession?
    let model: AppModel
    static let spacing: CGFloat = 3
    /// Three rows (16, 15 and 18 pt) inside the same inset on every side.
    static let height = CGFloat(DesignComponents.Banner.height(rows: [16, 15, 18], spacing: Double(spacing)))

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(spacing: 6) {
                Badge("Stuck?", .solid(Theme.stuck))
                AgentMark(agent: stuck.agent, size: 13)
                (Text(stuck.agent).fontWeight(.semibold).foregroundColor(Theme.textPrimary)
                    + Text(session.map { " · \($0.project)" } ?? "").foregroundColor(Theme.textMuted))
                    .font(DS.font(.base)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(SessionText.elapsed(since: stuck.since, now: model.agentsNow))
                    .font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textMuted)
            }
            .frame(height: 16)
            (Text(stuck.label).font(DS.font(.base, design: .monospaced)).foregroundColor(Theme.textPrimary)
                + Text(" " + stuck.long).foregroundColor(Theme.textSecondary))
                .font(DS.font(.base)).lineLimit(1).truncationMode(.middle)
                .frame(height: 15)
            HStack(spacing: 6) {
                Text(stuck.error ?? "").font(DS.font(.sm, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Button("Ignore") { model.ignoreStuck?(stuck) }.buttonStyle(CardButton(.secondary))
                    .help("Hide until it makes progress")
                if let session {
                    Button("Open") { model.focusAgent?(session) }.buttonStyle(CardButton(.primary))
                        .help(session.host.map { "Open \($0)" } ?? "Open")
                }
            }
            .frame(height: 18)
        }
        .bannerCard(tint: Theme.stuck, height: Self.height)
    }
}

/// Over the Agents list while a key spotted in a session stands: the kind,
/// project and agent, never any of the key, with Got it and Show transcript.
struct KeyBanner: View {
    let alert: KeyAlert
    let model: AppModel
    static let spacing: CGFloat = 3
    /// Three rows (16, 28 and 18 pt) inside the same inset on every side.
    static let height = CGFloat(DesignComponents.Banner.height(rows: [16, 28, 18], spacing: Double(spacing)))

    var body: some View {
        let body = KeyNotice.body(alert.kinds)
        let project = KeyNotice.project(alert)
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(spacing: 6) {
                Badge("Key spotted", .solid(Theme.critical))
                AgentMark(agent: alert.agent, size: 13)
                (Text(project ?? alert.agent).fontWeight(.semibold).foregroundColor(Theme.textPrimary)
                    + Text(project == nil ? "" : " · \(alert.agent)").foregroundColor(Theme.textMuted))
                    .font(DS.font(.base)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                KeyAgo(at: alert.at, model: model)
            }
            .frame(height: 16)
            .help(KeyNotice.hover(alert))
            Text(body.sentence)
                .font(DS.font(.base)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .topLeading)
            HStack(spacing: 6) {
                Text(body.advice).font(DS.font(.base)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 6)
                Button("Got it") { model.dismissKey?(alert) }.buttonStyle(CardButton(.secondary))
                if model.revealableKeys.contains(alert.id) {
                    Button("Show transcript") { model.revealKey?(alert) }.buttonStyle(CardButton(.primary))
                        .help("Select the transcript in Finder")
                }
            }
            .frame(height: 18)
        }
        .bannerCard(tint: Theme.critical, height: Self.height)
    }
}

/// The key card's "2m ago" from the list's one clock: only this small view
/// redraws each second, not the card.
struct KeyAgo: View {
    let at: Date
    let model: AppModel

    var body: some View {
        Text(SessionText.ago(at, now: model.agentsNow))
            .font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textMuted)
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
                .font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textMuted)
        } else {
            Text(SessionText.ago(session.since, now: model.agentsNow))
                .font(DS.font(.sm)).foregroundStyle(Theme.textMuted).lineLimit(1).fixedSize()
        }
    }
}

/// A finished Claude Code card's cache clock, from the list's one clock: warm in mint
/// with a bar that drains on its own (`CacheDrainBar`), then cold in grey with what the
/// next reply re-reads. Only this small view redraws each second; hover reads the full sentence.
struct CacheLine: View {
    let session: AgentSession
    let model: AppModel

    var body: some View {
        if let last = session.lastReply,
           let line = CacheClock.line(last: last, stoppedAt: session.since, now: model.agentsNow) {
            HStack(spacing: DS.Space.sm) {
                // One size for warm and cold; on a narrow card the number gives way first,
                // then the label; the price never does.
                HStack(spacing: DS.Space.none) {
                    Text(line.label).lineLimit(1).layoutPriority(1)
                    if !line.detail.isEmpty { Text(line.detail).lineLimit(1) }
                    if !line.price.isEmpty { Text(line.price).lineLimit(1).fixedSize() }
                }
                .font(DS.font(.sm)).foregroundStyle(line.warm ? DS.Palette.mint : Theme.textMuted)
                .layoutPriority(1)
                if line.warm {
                    CacheDrainBar(stop: session.since, window: CacheClock.window(for: last))
                        .frame(minWidth: DS.Space.xxxl, maxWidth: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 13)
            .help(line.help)
        }
    }
}

/// A card's permission mode pill: violet for "no asks" (the one to watch, a tint that
/// means no status elsewhere), the neutral badge for "auto-edit" and "plan". Nothing for
/// the default or an unknown mode.
struct ModeBadge: View {
    let mode: PermissionMode

    var body: some View {
        if let label = mode.label {
            Badge(label, mode == .bypass ? .solid(DS.Palette.violet) : .neutral)
        }
    }
}

private extension PermissionMode {
    /// The card's hover line.
    var help: String? {
        switch self {
        case .bypass: return "Runs with permissions off: never asks"
        case .acceptEdits: return "Accepts edits without asking"
        case .plan: return "Plan mode: plans before it changes anything"
        case .standard, .unknown: return nil
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
    /// This session keeps failing or repeating the same call.
    var stuck: Stuck?
    /// Its row has a cache line (here or beside it): `NotchEars.cacheLine` taller.
    var tall = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            top
            if let model, session.showsCacheLine { CacheLine(session: session, model: model) }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: NotchEars.agentCard + (tall ? NotchEars.cacheLine : 0))
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(outline.map { $0.opacity(Spec.Banner.strokeOpacity) } ?? .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .onTapGesture { focus?(session) }
        .help(help)
    }

    /// The ring and the three lines: project and time, agent and app, what it's doing.
    private var top: some View {
        HStack(spacing: 9) {
            ringTile
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.project).font(DS.font(.md, .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    time
                }
                // The mode pill sits on this line in every variant (warning or not), so the
                // project name above stays whole; the text before it truncates, never the pill.
                if let clashWith {
                    HStack(spacing: 4) {
                        Text("⇄ \(clashWith) too")
                            .font(DS.font(.sm, .medium)).foregroundStyle(Theme.clash).lineLimit(1)
                        modePill
                        Spacer(minLength: 0)
                    }
                } else if let stuck {
                    HStack(spacing: 4) {
                        Text("↻ \(stuck.short)")
                            .font(DS.font(.sm, .medium)).foregroundStyle(Theme.stuck).lineLimit(1)
                        modePill
                        Spacer(minLength: 0)
                    }
                    .frame(height: 13)
                } else {
                    HStack(spacing: 4) {
                        if session.mode?.label != nil {
                            // The host goes first, then the agent's name truncates;
                            // the pill and the cost never do.
                            ViewThatFits(in: .horizontal) {
                                agentLine(withHost: true).fixedSize()
                                agentLine(withHost: false)
                            }
                            modePill
                        } else {
                            agentLine(withHost: true)
                        }
                        Spacer(minLength: 0)
                        // On this line, not beside the clock: there it squeezed the project name.
                        if let cost = session.cost?.label {
                            Text(cost).font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1).fixedSize()
                        }
                        if let model, HelperWaterfall.shows(session) {
                            HelpersButton(session: session, model: model)
                        }
                    }
                    .frame(height: 13)
                }
                if let model, HelperWaterfall.opensFromDetail(detail, session: session) {
                    // "Waiting on N helpers ›" opens the helpers waterfall, like the ⑂ button.
                    Button { model.helpersOpen = model.helpersOpen == session.id ? nil : session.id } label: {
                        Text(detail + " ›").font(DS.font(.base)).foregroundStyle(Theme.question).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(detail).font(DS.font(.base)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
    }

    /// The permission mode pill, whole; nothing for the default or an unknown mode.
    @ViewBuilder private var modePill: some View {
        if let mode = session.mode, mode.label != nil { ModeBadge(mode: mode).fixedSize() }
    }

    /// "Claude Code · Ghostty", or just the agent.
    private func agentLine(withHost: Bool) -> some View {
        Text([session.agent, withHost ? session.host : nil].compactMap { $0 }.joined(separator: " · "))
            .font(DS.font(.sm)).foregroundStyle(Theme.textMuted).lineLimit(1)
    }

    private var needsYou: Bool {
        session.state.attention != nil
    }

    /// The tint of the card's outline: approval amber, clash orange or stuck coral, at one strength.
    private var outline: Color? {
        needsYou ? Theme.warning : clashWith != nil ? Theme.clash : stuck != nil ? Theme.stuck : nil
    }

    private var help: String {
        var lines: [String] = []
        if let host = session.host { lines.append("Open \(host)") }
        if let mode = session.mode?.help { lines.append(mode) }
        if let percent = session.contextPercent {
            lines.append("\(Int(percent))% context: \((session.contextTokens ?? 0).formatted()) of \((session.contextWindow ?? 0).formatted()) tokens"
                         + (SessionText.contextHigh(percent) ? ", compacts soon" : ""))
        }
        // Only the label: the board republishes when it changes, not on every token.
        if let cost = session.cost, let label = cost.label {
            lines.append("\(label) so far" + (cost.dollars > 0 ? " at API prices" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// The tile in its context ring, the status dot on its corner, and the percent from 80%.
    private var ringTile: some View {
        let percent = session.contextPercent
        let high = SessionText.contextHigh(percent)
        return ZStack {
            Circle().stroke(DS.Fill.subtle, lineWidth: 2.5)
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
                    .font(DS.font(.xs, .semibold).monospacedDigit()).foregroundStyle(Theme.warning)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.xs).fill(Theme.raised))
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
        case .working: return DS.Palette.mint
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

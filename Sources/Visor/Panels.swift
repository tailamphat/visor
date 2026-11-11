import VisorCore
import SwiftUI

// MARK: Agents

struct AgentsView: View {
    let model: AppModel

    var body: some View {
        if !model.hooksInstalled && !model.antigravityHooksInstalled && model.board.sessions.isEmpty {
            EmptyState(symbol: "link", title: "Connect your agents",
                       detail: "Adds Visor hooks so the notch can see Claude Code, Copilot CLI and Antigravity sessions, and ask you for approvals.",
                       button: "Connect") { model.installHooks?() }
        } else if model.board.sessions.isEmpty {
            EmptyState(symbol: "sparkles", title: "No agents running",
                       detail: "Start claude, copilot or agy in a terminal and it shows up here.")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    // Grouped by agent, Claude Code first; within a group, who needs you first.
                    ForEach(Self.groups(model.board.sessions), id: \.agent) { group in
                        HStack(spacing: 6) {
                            AgentMark(agent: group.agent, size: 11)
                            Text("\(group.agent) · \(group.sessions.count)")
                                .font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).tracking(0.6)
                                .foregroundStyle(Theme.textMuted)
                        }
                        .padding(.top, 2)
                        ForEach(group.sessions) { AgentRow(session: $0, focus: model.focusAgent) }
                    }
                    if !model.hooksInstalled {
                        Button("Connect Claude Code for approvals") { model.installHooks?() }
                            .buttonStyle(PillButton(fill: Theme.accent)).padding(.top, 4)
                    }
                }
            }
        }
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

struct AgentRow: View {
    let session: AgentSession
    var focus: ((AgentSession) -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            tile
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(session.project).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text([session.agent, session.host].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer(minLength: 8)
                    time
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(needsYou ? Theme.warning.opacity(0.35) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { focus?(session) }
        .help(session.host.map { "Open \($0)" } ?? "")
    }

    private var needsYou: Bool {
        session.state.attention != nil
    }

    /// Elapsed or relative time, sitting on the project line so it lines up with it.
    @ViewBuilder private var time: some View {
        if session.isActive {
            Text(session.since, style: .timer)
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textMuted)
        } else {
            Text(session.since, style: .relative)
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
    }

    /// The agent's tile with a status dot: mint working, amber waiting, grey done or idle.
    private var tile: some View {
        AgentIcon(agent: session.agent, size: 26)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Theme.raised, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
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

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var button: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Theme.textMuted)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if let button, let action {
                Button(button, action: action).buttonStyle(PillButton(fill: Theme.accent)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Approval buttons: a quiet outlined Deny, a neutral Always allow, and a
/// solid Allow as the main action. All press down slightly.
struct ConsentButton: ButtonStyle {
    enum Kind { case deny, secondary, allow }
    var kind: Kind

    static let mint = Color(hex: 0x7EE0A0)
    static let rose = Color(hex: 0xFF8F86)

    /// Soft mint: a solid mint Allow, a mint-tinted Always, a rose-tinted Deny.
    private var text: Color {
        switch kind {
        case .allow: return Color(hex: 0x06260F)
        case .secondary: return Color(hex: 0xC9F3D6)
        case .deny: return Color(hex: 0xFF9D95)
        }
    }
    private var fill: Color {
        switch kind {
        case .allow: return Self.mint
        case .secondary: return Self.mint.opacity(0.12)
        case .deny: return Self.rose.opacity(0.12)
        }
    }
    private var stroke: Color {
        switch kind {
        case .allow: return .clear
        case .secondary: return Self.mint.opacity(0.25)
        case .deny: return Self.rose.opacity(0.25)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .labelStyle(ConsentLabel())
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .brightness(pressed ? -0.08 : 0)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(Capsule())
    }
}

/// Icon then title, with the icon a touch bolder.
struct ConsentLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .bold))
            configuration.title
        }
    }
}

struct PillButton: ButtonStyle {
    var fill: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule())
    }
}

// MARK: Approval

struct ApprovalView: View {
    let model: AppModel
    let request: ApprovalRequest

    /// "in notchboard · Ghostty"
    static func place(session: AgentSession?, project: String) -> String {
        let parts = [project.isEmpty ? nil : "in \(project)", session?.host].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            let session = model.board.sessions.first { $0.id == request.sessionID }
            // Who is asking: agent, where it runs, which project.
            let agent = session?.agent ?? AgentBoard.agentName(request.provider)
            HStack(spacing: 7) {
                AgentIcon(agent: agent, size: 22)
                Text(agent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(agent == "Copilot CLI" ? Color(hex: 0xC4B0FF) : Color(hex: 0xF0A58A))
                Text(Self.place(session: session, project: request.project))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                if model.approvals.count > 1 {
                    Text("+\(model.approvals.count - 1) more").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            // What it wants, and the task it's working on.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("wants to \(request.action)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let task = session?.task {
                    Text("· \(task)").font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                        .help(task)
                }
            }
            (Text(request.tool == "Bash" ? "$ " : "").foregroundColor(Theme.textMuted) + Text(request.preview))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            // Deny, Always and Allow together in the centre.
            HStack(spacing: 8) {
                Button { model.decide?(request, .deny) } label: {
                    Label("Deny", systemImage: "xmark")
                }
                .buttonStyle(ConsentButton(kind: .deny))
                if let always = request.alwaysAllowLabel {
                    Button { model.decide?(request, .allowAlways) } label: {
                        Label {
                            HStack(spacing: 5) {
                                Text("Always")
                                Text(always).font(.system(size: 11.5, design: .monospaced)).opacity(0.75).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(ConsentButton(kind: .secondary))
                    .help("Allow this now, and don't ask again for \(always)")
                }
                Button { model.decide?(request, .allow) } label: {
                    Label("Allow", systemImage: "checkmark")
                }
                .buttonStyle(ConsentButton(kind: .allow))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }
}

/// The agent's own mark in its brand colour, on a dark tile.
struct AgentIcon: View {
    var agent = "Claude Code"
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(AgentStyle.tile)
            .frame(width: size, height: size)
            .overlay(AgentMark(agent: agent, size: size * 0.62))
    }
}

/// The agent's own mark (Claude's starburst, Copilot's face), drawn from its vector artwork.
struct AgentMark: View {
    var agent: String
    var size: CGFloat
    var color: Color?

    var body: some View {
        LogoShape(agent: agent).fill(color ?? Color(nsColor: AgentStyle.mark(agent)))
            .frame(width: size, height: size)
            .accessibilityLabel(agent)
    }
}

struct LogoShape: Shape {
    let agent: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return Path(AgentLogo.path(for: agent))
            .applying(CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale).scaledBy(x: scale, y: scale))
    }
}

// MARK: Usage

/// One row per tool (Claude, OpenCode, Copilot, Antigravity): its limits on the
/// left and, when it has one, what it used on the right.
struct UsageView: View {
    let model: AppModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                if model.shows(.claude) { claudeRow }
                if model.shows(.openCode) { OpenCodeBlock(model: model) }
                // No usage column, but the meters line up with the rows above.
                VStack(alignment: .leading, spacing: 20) {
                    if model.shows(.copilot) { ForEach(model.copilot, id: \.host) { CopilotBlock(usage: $0) } }
                    if model.shows(.antigravity) { AntigravityBlock(model: model) }
                }
                .padding(.trailing, UsageColumns.usageWidth + UsageColumns.spacing)
                if !ConnectionProvider.allCases.contains(where: model.shows) {
                    Text("Every tool is switched off. Turn one on under Connected accounts (the gear).")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var claudeRow: some View {
        UsageRow {
            VStack(alignment: .leading, spacing: 12) {
                ProviderHeader(agent: "Claude Code", title: model.planName ?? "Claude") {
                    if let updated = model.planUpdated {
                        (Text("Updated ") + Text(updated, style: .relative) + Text(" ago"))
                    }
                }
                if let plan = model.plan {
                    ForEach(plan.limits.prefix(3)) { limit in
                        LimitMeter(title: limit.title, used: limit.percentUsed,
                                   caption: limit.resetsAt.map { "Resets \(LimitMeter.resetText($0))" })
                    }
                    if let extra = plan.extra {
                        Text(String(format: "Extra usage: %@ of %@", money(extra.used), extra.limit.map(money) ?? "no limit"))
                            .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                } else {
                    Text(model.planError ?? "Loading…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                if let error = model.planError, model.plan != nil {
                    Text(error).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                }
            }
        } usage: {
            SpendView(model: model)
        }
    }

    private func money(_ value: Double) -> String { String(format: "$%.2f", value) }
}

/// Connected accounts: whether Visor can read each tool's usage, why not, and
/// one button to fix it. The switch hides a tool from the Usage tab and the notch.
struct AccountsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.showAccounts = false } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("Usage").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Connected accounts").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            VStack(spacing: 4) {
                ForEach(ConnectionProvider.allCases, id: \.self) { AccountRow(model: model, provider: $0) }
            }
        }
    }
}

struct AccountRow: View {
    let model: AppModel
    let provider: ConnectionProvider

    var body: some View {
        let shown = model.shows(provider)
        let state = model.connection(provider)
        HStack(spacing: 10) {
            AgentMark(agent: provider.agent, size: 14)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AgentStyle.tile))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 5) {
                    Circle().fill(shown ? tone(state.tone) : Theme.textMuted).frame(width: 6, height: 6)
                    Text(shown ? state.text : "Hidden")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                }
                .help(shown ? state.text : "Hidden")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if shown, let action = state.action {
                Button { model.connectionAction?(provider, action) } label: {
                    Text(label(action))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(action == .refresh ? Color.white.opacity(0.1) : Theme.accent))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // Drawn here: a system switch in the notch panel, never the key window, looks switched off.
            Button {
                if shown { model.hiddenProviders.insert(provider) } else {
                    model.hiddenProviders.remove(provider)
                    model.connectionAction?(provider, .refresh)
                }
            } label: {
                Capsule().fill(shown ? Theme.good : Theme.deemphasis)
                    .frame(width: 28, height: 16)
                    .overlay(alignment: shown ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 12, height: 12).padding(2)
                    }
                    .animation(.easeOut(duration: 0.15), value: shown)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shown ? "Hide \(provider.title)" : "Show \(provider.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .opacity(shown ? 1 : 0.5)
    }

    private func label(_ action: ConnectionState.Action) -> String {
        switch action {
        case .allowAccess: return "Allow access"
        case .signIn: return "Sign in…"
        case .refresh: return "Refresh"
        }
    }

    private func tone(_ tone: ConnectionState.Tone) -> Color {
        switch tone {
        case .good: return Theme.good
        case .warning: return Theme.warning
        case .bad: return Theme.critical
        case .neutral: return Theme.textMuted
        }
    }
}

enum UsageColumns {
    static let usageWidth: CGFloat = 190
    static let spacing: CGFloat = 24
}

/// A tool's limits on the left and its usage in a fixed column on the right.
struct UsageRow<Limits: View, Usage: View>: View {
    @ViewBuilder let limits: Limits
    @ViewBuilder let usage: Usage

    var body: some View {
        HStack(alignment: .top, spacing: UsageColumns.spacing) {
            limits.frame(maxWidth: .infinity, alignment: .leading)
            usage.frame(width: UsageColumns.usageWidth, alignment: .leading)
        }
    }
}

/// A provider's mark and name, with a muted note on the right.
struct ProviderHeader<Note: View>: View {
    let agent: String
    let title: String
    @ViewBuilder var note: Note

    var body: some View {
        HStack(spacing: 6) {
            AgentMark(agent: agent, size: 15)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            note.font(.system(size: 10)).foregroundStyle(Theme.textMuted)
        }
    }
}

/// Copilot's premium requests for one account.
struct CopilotBlock: View {
    let usage: CopilotUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderHeader(agent: "Copilot CLI", title: usage.title) { Text(usage.host) }
            if usage.premiumUnlimited {
                LimitMeter(title: "Premium requests", used: 0, caption: caption, unlimited: true)
            } else {
                LimitMeter(title: "Premium requests", used: 100 - usage.percentLeft, caption: caption)
            }
            if usage.completionsUnlimited || usage.chatUnlimited || usage.overagePermitted {
                // The overage chip goes first when the row is too narrow for all three,
                // then "unlimited" (the ∞ says it already; hover keeps the full text).
                ViewThatFits(in: .horizontal) {
                    chips(overage: usage.overagePermitted)
                    chips(overage: false)
                    chips(overage: false, short: true)
                }
            }
        }
    }

    private func chips(overage: Bool, short: Bool = false) -> some View {
        HStack(spacing: 6) {
            if usage.completionsUnlimited { chip("infinity", "Completions unlimited", short: "Completions", if: short) }
            if usage.chatUnlimited { chip("infinity", "Chat unlimited", short: "Chat", if: short) }
            if overage { chip("plus.circle", "Overage") }
        }
    }

    /// A small fact about the plan: "∞ Chat unlimited".
    private func chip(_ symbol: String, _ text: String, short: String? = nil, if useShort: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(nsColor: AgentStyle.mark("Copilot CLI")))
            Text(useShort ? short ?? text : text).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).fixedSize()
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .help(symbol == "infinity" ? text : "Overage allowed: requests past the limit are billed instead of refused")
    }

    /// "83 of 15,000 · Resets 1 Dec · ~552 a day to last"
    private var caption: String {
        var parts: [String] = []
        if !usage.premiumUnlimited { parts.append("\(usage.premiumUsed.formatted()) of \(usage.premiumEntitlement.formatted())") }
        if let reset = usage.resetsAt { parts.append("Resets " + reset.formatted(.dateTime.day().month(.abbreviated))) }
        if let perDay = usage.perDayToLast() { parts.append("~\(perDay.formatted()) a day to last") }
        if usage.overageUsed > 0 { parts.append("\(usage.overageUsed) over") }
        return parts.joined(separator: " · ")
    }
}

/// Antigravity's weekly quotas, read from its CLI only while this tab is open.
struct AntigravityBlock: View {
    let model: AppModel

    var body: some View {
        if model.antigravity != nil || model.antigravityError != nil || model.antigravityLoading {
            VStack(alignment: .leading, spacing: 12) {
                ProviderHeader(agent: "Antigravity", title: "Antigravity") {
                    if model.antigravityLoading {
                        Text("Checking…")
                    } else if let updated = model.antigravityUpdated {
                        (Text("Updated ") + Text(updated, style: .relative) + Text(" ago"))
                    }
                }
                if let usage = model.antigravity {
                    ForEach(usage.limits) { limit in
                        LimitMeter(title: limit.title, used: limit.percentUsed,
                                   caption: limit.resetsAt.map { "Resets " + $0.formatted(.dateTime.day().month(.abbreviated)) })
                    }
                    if let error = model.antigravityError {
                        Text(error).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                } else if let error = model.antigravityError {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

/// OpenCode Go limits (when signed in) and today's breakdown on the left; the
/// tokens OpenCode used on this Mac, from its local database, on the right.
struct OpenCodeBlock: View {
    let model: AppModel

    var body: some View {
        if model.openCode != nil || model.openCodeGo != nil || model.openCodeError != nil {
            UsageRow {
                VStack(alignment: .leading, spacing: 12) {
                    ProviderHeader(agent: "OpenCode", title: "OpenCode") {
                        if let updated = model.openCodeUpdated {
                            (Text("Updated ") + Text(updated, style: .relative) + Text(" ago"))
                        }
                    }
                    if let go = model.openCodeGo {
                        ForEach(go.limits) { limit in
                            LimitMeter(title: limit.title, used: limit.percentUsed,
                                       caption: limit.resetsAt.map { "Resets " + LimitMeter.resetText($0) })
                        }
                    }
                    if let usage = model.openCode {
                        Text(Self.caption(usage.today)).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                    if let error = model.openCodeError {
                        Text(error).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                }
            } usage: {
                if let usage = model.openCode {
                    OpenCodeTokensView(model: model, usage: usage)
                }
            }
        }
    }

    /// "Today: 303K in · 26K out · 7.8M cache · $0.00"
    static func caption(_ today: OpenCodeTotals) -> String {
        var parts: [String] = []
        if today.input > 0 { parts.append("\(TokenCount.compact(today.input)) in") }
        // Reasoning is billed as output.
        let output = today.output + today.reasoning
        if output > 0 { parts.append("\(TokenCount.compact(output)) out") }
        if today.cacheRead + today.cacheWrite > 0 {
            parts.append("\(TokenCount.compact(today.cacheRead + today.cacheWrite)) cache")
        }
        parts.append(String(format: "$%.2f", today.cost))
        return "Today: " + parts.joined(separator: " · ")
    }
}

/// Tokens per period and per day, laid out like Claude spend.
struct OpenCodeTokensView: View {
    let model: AppModel
    let usage: OpenCodeUsage

    var body: some View {
        let tokens = { (value: Double) in TokenCount.compact(Int(value)) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("OpenCode tokens").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("this Mac").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
            }
            .help("Tokens OpenCode recorded in its local database")
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Figure(label: "Today", value: Double(usage.today.tokens), large: true, format: tokens)
                Figure(label: "7 days", value: Double(usage.last7.tokens), format: tokens)
                Figure(label: "30 days", value: Double(usage.last30.tokens), format: tokens)
            }
            SpendChart(model: model, values: usage.daily.map(Double.init),
                       hover: \.openCodeHover, format: tokens)
        }
    }
}

/// One limit: what's left as the headline, a bar of what's used, then when it resets.
struct LimitMeter: View {
    let title: String
    let used: Double
    var caption: String?
    var unlimited = false

    var body: some View {
        let fill = used >= 90 ? Theme.critical : used >= 75 ? Theme.warning : Theme.accent
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                if used >= 75 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(fill)
                }
                Spacer()
                if unlimited {
                    Text("Unlimited").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                } else {
                    (Text("\(Int((100 - used).rounded()))%").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textPrimary)
                     + Text(" left").font(.system(size: 11)).foregroundColor(Theme.textSecondary))
                        .monospacedDigit()
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.accentTrack)
                    Capsule().fill(fill).frame(width: max(4, geo.size.width * min(used, 100) / 100))
                }
            }
            .frame(height: 6)
            if let caption, !caption.isEmpty {
                Text(caption).font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        if seconds < 86_400 {
            let h = Int(seconds) / 3600, m = Int(seconds) % 3600 / 60
            return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// API-equivalent value of Claude Code usage, from local transcripts.
struct SpendView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Claude spend").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("API value").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
            }
            .help("What your Claude Code usage would cost at API prices, from local transcripts")
            if let spend = model.spend {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Figure(label: "Today", value: spend.today, large: true)
                    Figure(label: "7 days", value: spend.last7Days)
                    Figure(label: "30 days", value: spend.last30Days)
                }
                SpendChart(model: model, values: spend.daily)
            } else {
                Text("Reading transcripts…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct Figure: View {
    let label: String
    let value: Double
    var large = false
    var format: (Double) -> String = Figure.compact

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(format(value)).font(.system(size: large ? 18 : 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
        }
    }

    static func compact(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "$%.1fK", v / 1000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }
}

/// Spend per day as an area, oldest first, ending today, with dates underneath.
/// Hovering picks a day and names it with its value; otherwise today is marked.
struct SpendChart: View {
    let model: AppModel
    let values: [Double]
    var hover: ReferenceWritableKeyPath<AppModel, Int?> = \.spendHover
    var format: (Double) -> String = Figure.compact

    /// Room at each end so the first and last date labels fit under their points.
    private static let inset: CGFloat = 14

    var body: some View {
        let focus = model[keyPath: hover].flatMap { values.indices.contains($0) ? $0 : nil }
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: size.height - 0.5))
                        p.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                    }
                    .stroke(Theme.deemphasis, lineWidth: 1)
                    area(size).fill(LinearGradient(colors: [Theme.accent.opacity(0.5), Theme.accent.opacity(0.06)],
                                                   startPoint: .top, endPoint: .bottom))
                    line(size).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    if let focus {
                        Path { p in
                            p.move(to: CGPoint(x: point(focus, size).x, y: 0))
                            p.addLine(to: CGPoint(x: point(focus, size).x, y: size.height))
                        }
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    }
                    if !values.isEmpty {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            .position(point(focus ?? values.count - 1, size))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    var index: Int?
                    if case .active(let location) = phase, values.count > 1 {
                        let step = (size.width - 2 * Self.inset) / CGFloat(values.count - 1)
                        index = min(max(Int(((location.x - Self.inset) / step).rounded()), 0), values.count - 1)
                    }
                    if model[keyPath: hover] != index { model[keyPath: hover] = index }
                }
            }
            .frame(height: 26)

            GeometryReader { geo in
                ForEach(DayAxis.labels(days: values.count, every: 3), id: \.index) { label in
                    Text(label.text)
                        .font(.system(size: 9, weight: label.index == values.count - 1 ? .semibold : .regular))
                        .foregroundStyle(label.index == values.count - 1 ? Theme.textSecondary : Theme.textMuted)
                        .fixedSize()
                        .position(x: point(label.index, geo.size).x, y: geo.size.height / 2)
                }
            }
            .frame(height: 11)

            Group {
                if let focus {
                    Text(DayAxis.name(focus, of: values.count)).foregroundStyle(Theme.textSecondary)
                        + Text(" · \(format(values[focus]))").foregroundStyle(Theme.textPrimary)
                } else {
                    Text("Last \(values.count) days").foregroundStyle(Theme.textMuted)
                }
            }
            .font(.system(size: 10).monospacedDigit())
        }
    }

    private func point(_ index: Int, _ size: CGSize) -> CGPoint {
        let peak = max(values.max() ?? 0, 0.01)
        let step = values.count > 1 ? (size.width - 2 * Self.inset) / CGFloat(values.count - 1) : 0
        let value = values.indices.contains(index) ? values[index] : 0
        return CGPoint(x: Self.inset + CGFloat(index) * step, y: size.height - 1 - (size.height - 5) * value / peak)
    }

    private func line(_ size: CGSize) -> Path {
        Path { p in
            for i in values.indices {
                i == 0 ? p.move(to: point(i, size)) : p.addLine(to: point(i, size))
            }
        }
    }

    private func area(_ size: CGSize) -> Path {
        Path { p in
            guard !values.isEmpty else { return }
            p.move(to: CGPoint(x: point(0, size).x, y: size.height))
            for i in values.indices { p.addLine(to: point(i, size)) }
            p.addLine(to: CGPoint(x: point(values.count - 1, size).x, y: size.height))
            p.closeSubpath()
        }
    }
}

// MARK: Music

/// Big artwork on the left over a blurred copy of itself; title, progress and
/// controls on the right, with the play button in the artwork's colour.
struct MusicView: View {
    let model: AppModel

    var body: some View {
        if let now = model.nowPlaying {
            let tint = model.artworkTint ?? NSColor(hex: 0xC3C2B7)
            HStack(alignment: .center, spacing: 18) {
                Artwork(image: model.artwork, size: 96, corner: 12)
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(now.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).help(now.title)
                        EqualizerBars(color: tint, active: now.surelyPlaying)
                        Spacer(minLength: 8)
                        volume(tint: tint)
                    }
                    Text([now.artist, now.sourceName].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if now.duration > 0 {
                        Progress(now: now)
                    } else if now.usesMediaKeys && !model.mediaKeysAllowed {
                        AccessibilityHint()
                            .padding(.bottom, 10)
                    } else if let browser = model.exactControlBrowser {
                        ExactControlHint(model: model, browser: browser)
                            .padding(.bottom, 10)
                    }
                    // Centred in the text column, under the progress bar.
                    HStack(spacing: 18) {
                        control("backward.fill", .previous)
                        Button { model.musicCommand?(.playPause) } label: {
                            Image(systemName: now.playPauseSymbol)
                                .font(.system(size: 17)).foregroundStyle(.black)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color(nsColor: tint)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(now.stateKnown ? "" : "\(now.sourceName.components(separatedBy: " · ")[0]) is using the microphone, so Visor can't tell whether this is playing")
                        control("forward.fill", .next)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 100)
            }
            // Fill the panel below the tabs so the artwork sits in its vertical centre.
            .frame(maxHeight: .infinity)
        } else {
            EmptyState(symbol: "music.note", title: "Nothing playing",
                       detail: "Play something in Spotify, Apple Music, or YouTube in your browser.")
        }
    }

    /// System volume, beside the title so the controls have their row to themselves.
    @ViewBuilder private func volume(tint: NSColor) -> some View {
        if let volume = model.volume {
            HStack(spacing: 5) {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                Slider(value: Binding(get: { model.volume ?? volume }, set: { model.setVolume?($0) }), in: 0...1)
                    .controlSize(.mini)
                    .tint(Color(nsColor: tint))
                    .frame(width: 70)
            }
        }
    }

    private func control(_ symbol: String, _ command: MusicCommand) -> some View {
        Button { model.musicCommand?(command) } label: {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Now Playing in a panel not much wider than the notch: small artwork, title
/// and artist, the controls underneath. No volume or progress.
struct CompactMusicView: View {
    let model: AppModel

    var body: some View {
        if let now = model.nowPlaying {
            let tint = model.artworkTint ?? NSColor(hex: 0xC3C2B7)
            HStack(alignment: .center, spacing: 12) {
                Artwork(image: model.artwork, size: 64, corner: 10)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(now.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).help(now.title)
                        EqualizerBars(color: tint, active: now.surelyPlaying)
                    }
                    Text([now.artist, now.sourceName].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 2)
                    HStack(spacing: 14) {
                        control("backward.fill", .previous)
                        Button { model.musicCommand?(.playPause) } label: {
                            Image(systemName: now.playPauseSymbol)
                                .font(.system(size: 13)).foregroundStyle(.black)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color(nsColor: tint)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(now.stateKnown ? "" : "\(now.sourceName.components(separatedBy: " · ")[0]) is using the microphone, so Visor can't tell whether this is playing")
                        control("forward.fill", .next)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 70)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func control(_ symbol: String, _ command: MusicCommand) -> some View {
        Button { model.musicCommand?(command) } label: {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shown while the media keys can't be pressed: a soft amber box that opens
/// the Accessibility page of System Settings. Gone once permission is given.
struct AccessibilityHint: View {
    var body: some View {
        Button {
            MediaKeys.requestPermission()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                Text("Allow Accessibility to use the controls").lineLimit(1)
                Spacer(minLength: 6)
                Text("Open Settings \u{203A}").fontWeight(.semibold).foregroundStyle(Theme.warning)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(hex: 0xF3D38B))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.warning.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.warning.opacity(0.22), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Visor presses the media keys to control the browser, which needs Accessibility permission.")
    }
}

/// Shown while a browser keeps Visor out of its pages (Dia without its launch
/// flag): play and pause go through the media keys, which can reach the wrong
/// tab. One click reopens the browser with page access; the x hides the offer.
struct ExactControlHint: View {
    let model: AppModel
    let browser: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10, weight: .semibold))
            Text(model.exactControlBusy ? "Reopening \(browser)…" : "Controls may miss the tab").lineLimit(1)
            Spacer(minLength: 6)
            if !model.exactControlBusy {
                Button { model.enableExactControl?() } label: {
                    Text("Reopen \(browser) \u{203A}").fontWeight(.semibold).foregroundStyle(Theme.question)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Quits \(browser) and opens it again with page access, so play, pause and skip reach the right tab. \(browser) restores your tabs.")
                Button { model.exactControlDismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textMuted)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Don't offer this again")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(hex: 0xB9D6F7))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.question.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.question.opacity(0.22), lineWidth: 1))
    }
}

/// Progress runs locally between player updates, ticking once a second.
struct Progress: View {
    let now: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = now.position(at: context.date)
            HStack(spacing: 8) {
                Text(Self.time(position))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Theme.textPrimary)
                            .frame(width: now.duration > 0 ? geo.size.width * min(1, position / now.duration) : 0)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                }
                Text(Self.time(now.duration))
            }
            .frame(height: 14)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Theme.textMuted)
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

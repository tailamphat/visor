import NotchboardCore
import SwiftUI

// MARK: Agents

struct AgentsView: View {
    let model: AppModel

    var body: some View {
        if !model.hooksInstalled && model.board.sessions.isEmpty {
            EmptyState(symbol: "link", title: "Connect Claude Code",
                       detail: "Adds Notchboard hooks to ~/.claude/settings.json so the notch can see your agents and ask you for approvals.",
                       button: "Connect") { model.installHooks?() }
        } else if model.board.sessions.isEmpty {
            EmptyState(symbol: "sparkles", title: "No agents running",
                       detail: "Start claude in a terminal and it shows up here.")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(model.board.sessions.sorted(by: Self.order)) { AgentRow(session: $0) }
                    if !model.hooksInstalled {
                        Button("Connect Claude Code for approvals") { model.installHooks?() }
                            .buttonStyle(PillButton(fill: Theme.accent)).padding(.top, 4)
                    }
                }
            }
        }
    }

    /// Sessions that need you first, then busy ones, then the rest by recency.
    static func order(_ a: AgentSession, _ b: AgentSession) -> Bool {
        func rank(_ s: AgentSession) -> Int {
            switch s.state {
            case .needsApproval, .needsInput: return 0
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

    var body: some View {
        HStack(spacing: 10) {
            status.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.project).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text([session.agent, session.host].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if session.isActive {
                Text(session.since, style: .timer)
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textMuted)
            } else {
                Text(session.since, style: .relative)
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
    }

    private var detail: String {
        switch session.state {
        case .idle: return "Ready"
        case .working(let what): return what == "Thinking" ? session.task.map { "Thinking · \($0)" } ?? what : what
        case .needsApproval(let what): return "Needs approval · \(what)"
        case .needsInput: return "Waiting for your reply"
        case .done: return "Finished"
        }
    }

    @ViewBuilder private var status: some View {
        switch session.state {
        case .working:
            PulsingSymbol(name: "sparkle", color: NSColor(hex: 0xD97757), size: 12)
        case .needsApproval:
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.warning)
        case .needsInput:
            Image(systemName: "text.bubble.fill").foregroundStyle(Theme.accent)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
        case .idle:
            Image(systemName: "circle").foregroundStyle(Theme.textMuted)
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
        VStack(alignment: .leading, spacing: 8) {
            let session = model.board.sessions.first { $0.id == request.sessionID }
            // Who is asking: agent, where it runs, which project, and its task.
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.warning)
                Text(session?.agent ?? "Claude Code")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.claude)
                Text(Self.place(session: session, project: request.project))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                if model.approvals.count > 1 {
                    Text("+\(model.approvals.count - 1) more").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("wants to use \(request.tool)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let task = session?.task {
                    Text("· \(task)").font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                        .help(task)
                }
            }
            Text(request.preview)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
            HStack(spacing: 8) {
                Button("Ask in terminal") { model.decide?(request, nil) }
                    .buttonStyle(PillButton(fill: Theme.raised, foreground: Theme.textSecondary))
                    .help("Let Claude Code show its own prompt instead")
                Spacer()
                Button("Deny") { model.decide?(request, .deny) }
                    .buttonStyle(PillButton(fill: Theme.critical))
                if !request.suggestions.isEmpty {
                    Button("Always allow") { model.decide?(request, .allowAlways) }
                        .buttonStyle(PillButton(fill: Theme.raised, foreground: Theme.textPrimary))
                        .help("Allow, and don't ask again for this kind of call")
                }
                Button("Allow") { model.decide?(request, .allow) }
                    .buttonStyle(PillButton(fill: Theme.good))
            }
        }
    }
}

// MARK: Usage

struct UsageView: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.planName ?? "Plan limits").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let updated = model.planUpdated {
                        (Text("Updated ") + Text(updated, style: .relative) + Text(" ago"))
                            .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                }
                if let plan = model.plan {
                    ForEach(plan.limits.prefix(3)) { LimitMeter(limit: $0) }
                    if let extra = plan.extra {
                        Text(String(format: "Extra usage: %@ of %@", money(extra.used), extra.limit.map(money) ?? "no limit"))
                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Text(model.planError ?? "Loading…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                if let error = model.planError, model.plan != nil {
                    Text(error).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SpendView(spend: model.spend).frame(width: 220)
        }
    }

    private func money(_ value: Double) -> String { String(format: "$%.2f", value) }
}

struct LimitMeter: View {
    let limit: PlanLimit

    var body: some View {
        let used = limit.percentUsed
        let fill = used >= 90 ? Theme.critical : used >= 75 ? Theme.warning : Theme.accent
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(limit.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                if used >= 75 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(fill)
                }
                Spacer()
                Text("\(Int(used.rounded()))% used · \(Int(limit.percentLeft.rounded()))% left")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.accentTrack)
                    Capsule().fill(fill).frame(width: max(4, geo.size.width * min(used, 100) / 100))
                }
            }
            .frame(height: 6)
            if let reset = limit.resetsAt {
                Text("Resets \(Self.resetText(reset))").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
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
    let spend: SpendSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spend (API value)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .help("What your Claude Code usage would cost at API prices, from local transcripts")
            if let spend {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Figure(label: "Today", value: spend.today, large: true)
                    Figure(label: "7 days", value: spend.last7Days)
                    Figure(label: "30 days", value: spend.last30Days)
                }
                DailyBars(values: spend.daily).frame(height: 34)
                Text("Last 14 days").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.compact(value)).font(.system(size: large ? 18 : 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
        }
    }

    static func compact(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "$%.1fK", v / 1000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }
}

/// One bar per day; today in the accent, earlier days de-emphasised. Hover a bar for its value.
struct DailyBars: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 0, 0.01)
            let gap: CGFloat = 2
            let width = (geo.size.width - gap * CGFloat(max(values.count - 1, 0))) / CGFloat(max(values.count, 1))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(values.indices, id: \.self) { i in
                    let height = values[i] > 0 ? max(2, geo.size.height * values[i] / peak) : 1
                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2, style: .continuous)
                        .fill(i == values.count - 1 ? Theme.accent : Theme.deemphasis)
                        .frame(width: width, height: height)
                        .frame(height: geo.size.height, alignment: .bottom)
                        .contentShape(Rectangle())
                        .help("\(Self.day(i, of: values.count)): \(Figure.compact(values[i]))")
                }
            }
        }
    }

    static func day(_ index: Int, of count: Int) -> String {
        let ago = count - 1 - index
        if ago == 0 { return "Today" }
        let date = Calendar.current.date(byAdding: .day, value: -ago, to: Date()) ?? Date()
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: Music

struct MusicView: View {
    let model: AppModel

    var body: some View {
        if let now = model.nowPlaying {
            HStack(spacing: 16) {
                Artwork(image: model.artwork, size: 112, corner: 14)
                VStack(alignment: .leading, spacing: 6) {
                    Text(now.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(now.artist).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Text(now.album).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer(minLength: 4)
                    if now.duration > 0 { Progress(now: now) }
                    HStack(spacing: 22) {
                        control("backward.fill", .previous)
                        control(now.isPlaying ? "pause.fill" : "play.fill", .playPause, size: 22)
                        control("forward.fill", .next)
                        Spacer()
                        Text(now.sourceName).font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    if now.usesMediaKeys && !MediaKeys.isAllowed {
                        Text("Controls use your media keys: allow Notchboard in System Settings \u{203A} Privacy & Security \u{203A} Accessibility.")
                            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            EmptyState(symbol: "music.note", title: "Nothing playing",
                       detail: "Play something in Spotify, Apple Music, or YouTube in your browser.")
        }
    }

    private func control(_ symbol: String, _ command: MusicCommand, size: CGFloat = 15) -> some View {
        Button { model.musicCommand?(command) } label: {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Progress runs locally between player updates, ticking once a second.
struct Progress: View {
    let now: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = now.position(at: context.date)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Theme.textPrimary)
                            .frame(width: now.duration > 0 ? geo.size.width * position / now.duration : 0)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(Self.time(position))
                    Spacer()
                    Text("-" + Self.time(max(0, now.duration - position)))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

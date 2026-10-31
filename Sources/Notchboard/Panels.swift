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
            HStack(spacing: 7) {
                AgentIcon(size: 22)
                Text(session?.agent ?? "Claude Code")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xF0A58A))
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
        // On top of the panel's own padding: room on every side, like the music panel.
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// The agent's mark: Claude's sparkle on an orange tile.
struct AgentIcon: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xE48A6B), Color(hex: 0xB9583B)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "sparkle").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
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

/// Big artwork on the left over a blurred copy of itself; title, progress and
/// controls on the right, with the play button in the artwork's colour.
struct MusicView: View {
    let model: AppModel

    var body: some View {
        if let now = model.nowPlaying {
            let tint = model.artworkTint ?? NSColor(hex: 0xC3C2B7)
            HStack(alignment: .center, spacing: 18) {
                Artwork(image: model.artwork, size: 120, corner: 14)
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(now.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).help(now.title)
                        EqualizerBars(color: tint, active: now.isPlaying)
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
                    }
                    // Centred in the text column, under the progress bar.
                    HStack(spacing: 18) {
                        control("backward.fill", .previous)
                        Button { model.musicCommand?(.playPause) } label: {
                            Image(systemName: now.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 17)).foregroundStyle(.black)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color(nsColor: tint)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        control("forward.fill", .next)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 124)
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
        .help("Notchboard presses the media keys to control the browser, which needs Accessibility permission.")
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

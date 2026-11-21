import VisorCore
import SwiftUI

/// Sizes shared by the view and the window controller's hover hit-testing.
@MainActor
struct NotchLayout {
    var notch: CGSize

    /// Each side of the closed notch: what it shows, as measured by the view,
    /// with the same inset to the notch and to its outer edge.
    func leftEar(_ model: AppModel) -> CGFloat { CGFloat(NotchEars.width(content: Double(model.leftEarContent))) }
    func rightEar(_ model: AppModel) -> CGFloat { CGFloat(NotchEars.width(content: Double(model.rightEarContent))) }

    /// Moves the closed shape sideways when its ears differ, keeping the notch covered.
    func shift(_ model: AppModel) -> CGFloat {
        // Open, the panel stays centred: every header has the same three slots each side.
        if model.expanded { return 0 }
        guard showsEars(model) else { return 0 }
        return CGFloat(NotchEars.shift(left: Double(leftEar(model)), right: Double(rightEar(model))))
    }

    /// The open panel's width for every tab (four 24 pt tabs fit left of the
    /// camera), approvals included.
    static let width: CGFloat = 460
    static let expandedSize = CGSize(width: width, height: 200)
    /// Approvals: the usual width; taller when the "Always allow" link shows under the buttons.
    static let approvalSize = CGSize(width: width, height: 193)
    static let approvalAlwaysExtra: CGFloat = 25
    static let musicSize = CGSize(width: width, height: 182)
    static let nothingPlayingHeight: CGFloat = 150
    /// The compact Now Playing row: artwork beside title and controls.
    static let compactMusicContent: CGFloat = 70
    /// The "limit is back" card: a title row and one meter.
    static let limitBackContent: CGFloat = 70
    static let clipboardSize = CGSize(width: width, height: 240)
    /// Usage with Copilot below Claude.
    static let usageWithCopilotSize = CGSize(width: width, height: 312)
    /// Usage with Copilot and Antigravity in the provider column; the tallest panel.
    static let usageWithAntigravitySize = CGSize(width: width, height: 450)
    /// Usage with OpenCode's Go limits and local token card.
    static let usageWithOpenCodeSize = CGSize(width: width, height: 450)
    /// Connected accounts: a row per tool.
    static let accountsSize = CGSize(width: width, height: 272)
    /// The longest the Agents list grows before it scrolls.
    static let listMaxHeight: CGFloat = 402
    /// The window is a little larger than the biggest panel, room for the shadow.
    static let windowSize = CGSize(width: 620, height: 480)

    func flare(expanded: Bool) -> CGFloat { expanded ? 12 : 6 }

    /// Room from an open panel's edges to its content and header, on every tab.
    static let inset = CGFloat(NotchEars.panelInset)
    /// Between the header and the content.
    static let contentTop: CGFloat = 8

    /// A panel just tall enough for content of this height, with the same room below it.
    func fitting(_ content: CGFloat) -> CGFloat { notch.height + Self.contentTop + content + Self.inset }

    func size(for model: AppModel) -> CGSize {
        if model.expanded {
            if let first = model.approvals.first {
                return CGSize(width: Self.approvalSize.width,
                              height: Self.approvalSize.height + (first.alwaysAllowLabel == nil ? 0 : Self.approvalAlwaysExtra))
            }
            if model.welcome { return CGSize(width: Self.width, height: fitting(WelcomeView.height)) }
            if model.summary != nil { return CGSize(width: Self.width, height: fitting(TurnSummaryView.height)) }
            if model.limitBack != nil { return CGSize(width: Self.expandedSize.width, height: fitting(Self.limitBackContent)) }
            if model.narrowMusic {
                // Narrow: just wide enough for the header's three slots each side.
                let width = CGFloat(NotchEars.musicWidth(notch: Double(notch.width), tabsRight: 3))
                return CGSize(width: width, height: model.compactMusic ? fitting(Self.compactMusicContent) : Self.musicSize.height)
            }
            if model.tab == .usage && model.showAccounts { return Self.accountsSize }
            if model.tab == .usage && model.usageTokens { return CGSize(width: Self.expandedSize.width, height: fitting(TokensView.height)) }
            if model.tab == .usage {
                // Plan limits sit under a bar with the switch to Tokens.
                let bar = UsageBar.height + UsageBar.gap
                // The gap between tools is a little more than the old 20pt.
                // Plus a line under each tool whose provider has an incident.
                let dividers = CGFloat(max(0, model.usageSections.count - 1)) * UsageView.toolGapExtra
                    + CGFloat(model.incidents.count) * (IncidentLine.height + 8)
                // No taller than the tallest panel the window has room for; past that, the list scrolls.
                func taller(_ size: CGSize) -> CGSize {
                    CGSize(width: size.width, height: min(size.height + bar + dividers, Self.usageWithAntigravitySize.height + bar))
                }
                if model.shows(.antigravity) && (model.antigravity != nil || model.antigravityError != nil || model.antigravityLoading) {
                    return taller(Self.usageWithAntigravitySize)
                }
                if model.shows(.openCode) && (model.openCode != nil || model.openCodeGo != nil || model.openCodeError != nil) {
                    return taller(Self.usageWithOpenCodeSize)
                }
                if model.shows(.copilot) && !model.copilot.isEmpty { return taller(Self.usageWithCopilotSize) }
                return taller(Self.expandedSize)
            }
            if model.tab == .clipboard { return Self.clipboardSize }
            if model.tab == .plugins {
                let content = model.pluginsContentHeight > 0 ? model.pluginsContentHeight + PluginsView.footer : PluginsView.estimate(model.plugins)
                return CGSize(width: Self.expandedSize.width, height: min(Self.listMaxHeight, fitting(content)))
            }
            if model.showsOffice {
                // The room runs to the panel's bottom edge: no room below it.
                return CGSize(width: Self.expandedSize.width,
                              height: notch.height + Self.contentTop + OfficeView.height(for: model.board.sessions))
            }
            if model.tab == .agents && !model.board.sessions.isEmpty {
                // Grow with the list: a header per agent group and rows of two cards, then scroll.
                let digest = AgentsDigest(sessions: model.board.sessions)
                var content: CGFloat
                if digest.capped && !model.agentsShowAll {
                    content = CGFloat(NotchEars.agentsDigest(cards: digest.top.count, idleLines: digest.idle.count))
                } else {
                    let sizes = AgentsView.groups(model.board.sessions).map(\.sessions.count)
                    content = CGFloat(NotchEars.agentsGrid(groupSizes: sizes)) + (digest.capped ? 6 + 26 : 0)  // "Show fewer"
                }
                if !model.hooksInstalled { content += 6 + 26 }  // the Connect button under the list
                if !model.clashes.isEmpty { content += ClashBanner.height + 6 }  // two agents on one file
                return CGSize(width: Self.expandedSize.width, height: min(Self.listMaxHeight, fitting(content)))
            }
            // Nothing playing: a little shorter than the other panels, it's only a message.
            if model.tab == .music && model.nowPlaying == nil { return CGSize(width: Self.width, height: Self.nothingPlayingHeight) }
            return model.tab == .music && model.nowPlaying != nil ? Self.musicSize : Self.expandedSize
        }
        let ears = showsEars(model) ? leftEar(model) + rightEar(model) : 0
        return CGSize(width: notch.width + ears + 2 * flare(expanded: false), height: notch.height)
    }

    func showsEars(_ model: AppModel) -> Bool {
        model.hasActivity || model.isPlaying || model.peek != nil || !model.pluginBadges.isEmpty
    }
}

struct NotchView: View {
    @Bindable var model: AppModel
    let layout: NotchLayout

    var body: some View {
        let size = layout.size(for: model)
        let flare = layout.flare(expanded: model.expanded)
        let shape = NotchShape(top: flare, bottom: model.expanded ? 24 : 9)
        ZStack(alignment: .top) {
            if model.expanded {
                ExpandedView(model: model, layout: layout)
                    .padding(.horizontal, flare)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            } else {
                CollapsedView(model: model, layout: layout)
                    .padding(.horizontal, flare)
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background {
            // Approvals: a soft mint glow from the top-left corner, matching the buttons.
            if model.expanded && model.showsCard {
                RadialGradient(colors: [ConsentButton.mint.opacity(0.16), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 380)
                    .transition(.opacity)
            }
        }
        .background {
            // Music: blurred artwork behind a dark shade, lit by the artwork colour.
            if model.showsMusic, let backdrop = model.artworkBackdrop {
                ZStack {
                    Image(nsImage: backdrop).resizable().aspectRatio(contentMode: .fill).opacity(0.6)
                    LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    if let tint = model.artworkTint {
                        RadialGradient(colors: [Color(nsColor: tint).opacity(0.45), .clear],
                                       center: UnitPoint(x: 0.15, y: 0.7), startRadius: 0, endRadius: 300)
                    }
                }
                .transition(.opacity)
            }
        }
        .background(Theme.surface)
        .animation(.easeOut(duration: 0.4), value: model.artworkBackdrop)
        .clipShape(shape)
        .shadow(color: .black.opacity(model.expanded ? 0.45 : 0), radius: 10, y: 4)
        .offset(x: layout.shift(model))
        .animation(Theme.spring, value: model.expanded)
        .animation(Theme.spring, value: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.providerIncidents, model.incidents)
    }
}

// MARK: Collapsed

/// The notch at rest: invisible on a notched screen, with small "ears" either
/// side when agents are busy or music plays.
struct CollapsedView: View {
    let model: AppModel
    let layout: NotchLayout

    var body: some View {
        HStack(spacing: 0) {
            if layout.showsEars(model) {
                // Each side is sized from its measured content, so whatever it
                // shows has the same gap to the notch and to the outer edge.
                let gap = CGFloat(NotchEars.inset)
                measured(left) { model.leftEarContent = $0 }
                    .padding(.trailing, gap).frame(width: layout.leftEar(model), alignment: .trailing)
                Spacer(minLength: layout.notch.width)
                measured(right) { model.rightEarContent = $0 }
                    .padding(.leading, gap).frame(width: layout.rightEar(model), alignment: .leading)
            }
        }
        .frame(height: layout.notch.height)
    }

    /// The content at its own width, reported whenever it changes (0 when empty).
    private func measured<Content: View>(_ content: Content, _ report: @escaping (CGFloat) -> Void) -> some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            content
        }
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { report($0) }
    }

    /// Whose badge a peek shows, and its hover text.
    private static func describe(_ peek: Peek) -> (agent: String, help: String) {
        switch peek {
        case .done(let turn):
            let detail = [turn.project, turn.durationText].compactMap { $0 }.joined(separator: " · ")
            return (turn.agent, "\(turn.agent) finished" + (detail.isEmpty ? "" : ": " + detail))
        case .answered(let agent):
            return (agent, "\(agent): answered")
        case .plugin(_, let news):
            return ("", news.subtitle.isEmpty ? news.title : news.title + ": " + news.subtitle)
        case .clash(let clash):
            return (clash.agents[0], "\(clash.agents.joined(separator: " and ")) both edited \(clash.path)")
        case .status(let agent, let incident):
            return (agent, incident.title)
        }
    }

    @ViewBuilder private var left: some View {
        if let peek = model.peek, case .plugin(let icon, let news) = peek {
            Image(systemName: news.icon ?? icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PluginStyle.color(news.state))
                .help(Self.describe(peek).help)
        } else if let peek = model.peek, case .status(_, let incident) = peek {
            Circle().fill(IncidentLine.color(incident)).frame(width: 9, height: 9)
                .help(Self.describe(peek).help)
        } else if let peek = model.peek, case .clash(let clash) = peek {
            // Both agents' marks with an orange ⇄ between them.
            HStack(spacing: 5) {
                AgentMark(agent: clash.agents[0], size: 14)
                ClashBadge()
                AgentMark(agent: clash.agents[1], size: 14)
            }
            .help(Self.describe(peek).help)
        } else if let peek = model.peek {
            // The agent's mark with a green ✓ on its corner, like the "?" and
            // "!" badges on the right; the project and time are in the hover text.
            let (agent, help) = Self.describe(peek)
            AgentMark(agent: agent, size: 16)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white, Theme.good)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black).padding(-1.5))
                        .offset(x: 5, y: 4)
                }
                // Counts the badge reaching past the corner.
                .padding(.trailing, 5)
                .help(help)
        } else if model.hasActivity {
            AgentBadge(board: model.board, approvals: Set(model.approvals.map { AgentBoard.agentName($0.provider) }))
        } else if model.isPlaying {
            Artwork(image: model.artwork, size: 20, corner: 5)
        }
    }

    @ViewBuilder private var right: some View {
        if let peek = model.peek, case .status(let agent, _) = peek {
            Text("\(IncidentLine.name(agent)) is having issues")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                .help(Self.describe(peek).help)
        } else if let peek = model.peek, case .clash = peek {
            Text("same file")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                .help(Self.describe(peek).help)
        } else if let peek = model.peek, case .answered = peek {
            Text("Answered")
                .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1)
        } else if let peek = model.peek, case .plugin(_, let news) = peek {
            Text(news.title)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
        } else if let note = model.attentionNote {
            // Takes the right side over the artwork until it's dealt with.
            let bubble = AttentionBubble(kind: note.kind, size: note.icon == nil ? 13 : 9)
            Group {
                if let icon = note.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        .overlay(alignment: .bottomTrailing) {
                            bubble.background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black)).offset(x: 5, y: 4)
                        }
                        // Counts the bubble reaching past the corner.
                        .padding(.trailing, 5)
                } else {
                    bubble
                }
            }
            .help(note.help)
        } else if model.isPlaying {
            if model.hasActivity || model.peek != nil {
                // The agent has the left side: the bars sit on the artwork's
                // corner, like the "?" on the app icon, so the right stays small.
                Artwork(image: model.artwork, size: 20, corner: 5)
                    .overlay(alignment: .bottomTrailing) {
                        EqualizerBars.mini(color: model.artworkTint ?? .white, active: model.nowPlaying?.surelyPlaying ?? false)
                            .padding(2.5)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black))
                            .offset(x: 5, y: 4)
                    }
                    // Counts the bars reaching past the corner; their black
                    // backing doesn't show on the notch.
                    .padding(.trailing, 2.5)
            } else {
                EqualizerBars(color: NSColor(hex: 0xC3C2B7))
            }
        } else if !model.quotas.isEmpty || !model.pluginBadges.isEmpty {
            HStack(spacing: 6) {
                // Plugins' badges first, nearest the notch: they're news; the quotas are standing numbers.
                ForEach(Array(model.pluginBadges.enumerated()), id: \.offset) { _, badge in
                    PluginBadgeView(badge: badge)
                }
                ForEach(model.quotas) { quota in
                    // Mark on top, percent below, so each agent is one narrow column.
                    VStack(spacing: 1.5) {
                        // Always the agent's own colour, so each is recognisable;
                        // the percent below carries the warning colour.
                        AgentMark(agent: quota.agent, size: 10)
                            // An open incident on this tool: a small dot on its mark.
                            .overlay(alignment: .topTrailing) {
                                if let incident = model.incidents[quota.agent] {
                                    Circle().fill(IncidentLine.color(incident)).frame(width: 5, height: 5)
                                        .background(Circle().fill(.black).padding(-1.5)).offset(x: 3, y: -2)
                                }
                            }
                        // The time left when it runs out within the hour.
                        Text(quota.text)
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(quota.level == .critical ? Theme.critical
                                : quota.level == .warning ? Theme.warning
                                : Theme.textSecondary)
                    }
                    .help(quota.runsOutSoon ? quota.label + ", runs out in " + quota.text + " at this pace" : quota.label)
                }
            }
        }
    }
}

/// What each agent looks like: its mark and colour.
enum AgentStyle {
    /// Bright, for marks on black.
    static func mark(_ agent: String) -> NSColor {
        switch agent {
        case "Copilot CLI": return NSColor(hex: 0xA78BFA)
        case "Antigravity": return NSColor(hex: 0x3186FF)
        case "OpenCode": return NSColor(hex: 0xEDEDED)
        case "Codex CLI": return NSColor(hex: 0x10A37F)
        case "Gemini CLI": return NSColor(hex: 0xE879F9)
        default: return NSColor(hex: 0xD97757)
        }
    }
    /// The tile behind the mark in lists.
    static let tile = Color.white.opacity(0.08)
}

/// Amber "!" bubble: approve something. Blue "?" bubble: answer something.
struct AttentionBubble: View {
    let kind: Attention
    let size: CGFloat

    var body: some View {
        PulsingSymbol(name: kind == .question ? "questionmark.bubble.fill" : "exclamationmark.bubble.fill",
                      color: kind == .question ? NSColor(hex: 0x5AA2F0) : NSColor(hex: 0xFAB219),
                      glyph: kind == .question ? .white : .black,
                      size: size)
            .id(kind)
    }
}

/// The closed notch's agent marks: one per agent with its count, at most two,
/// then "+N". An agent waiting for you shows as an amber bubble and always
/// gets one of the two slots (the board lists waiting agents first).
struct AgentBadge: View {
    let board: AgentBoard
    /// Agents whose approval cards are open.
    let approvals: Set<String>

    var body: some View {
        let marks = NotchMarks.make(board, approvalsFrom: approvals)
        return HStack(spacing: 6) {
            ForEach(marks.shown, id: \.agent) { entry in
                HStack(spacing: 2) {
                    // A waiting agent's mark holds still; its "!" or "?" shows on the right side.
                    PulsingSymbol(name: "", logo: entry.agent, color: AgentStyle.mark(entry.agent),
                                  size: 12, active: !entry.waiting)
                        .id("\(entry.agent)\(String(describing: entry.attention))")
                    if entry.count > 1 {
                        Text("\(entry.count)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
                .help(entry.attention == .question ? "\(entry.agent) asks you something"
                      : entry.waiting ? "\(entry.agent) needs your approval" : "\(entry.agent): \(entry.count) working")
            }
            if !marks.more.isEmpty {
                Text("+\(marks.more.count)")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .help(marks.more.joined(separator: ", "))
            }
        }
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.raised
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: Expanded

struct ExpandedView: View {
    @Bindable var model: AppModel
    let layout: NotchLayout

    /// The office runs to the panel's edges; everything else sits inside the inset.
    private var fullBleed: Bool {
        // Only the office itself; anything shown in its place (a summary, the hello) keeps the inset.
        model.showsOffice && model.approvals.isEmpty && model.limitBack == nil && !model.compactMusic
            && model.summary == nil && !model.welcome
    }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: layout.notch.height)
            Group {
                if let approval = model.approvals.first {
                    ApprovalView(model: model, request: approval)
                } else if model.welcome {
                    WelcomeView(model: model)
                } else if let summary = model.summary {
                    TurnSummaryView(model: model, turn: summary)
                } else if let back = model.limitBack {
                    LimitBackView(back: back)
                } else {
                    switch model.tab {
                    case .agents:
                        if model.showsOffice {
                            OfficeView(model: model)
                        } else {
                            AgentsView(model: model)
                        }
                    case .usage:
                        if model.showAccounts { AccountsView(model: model) }
                        else if model.usageTokens { TokensView(model: model) }
                        else {
                            VStack(spacing: UsageBar.gap) {
                                UsageBar(model: model)
                                UsageView(model: model)
                            }
                        }
                    case .music: if model.compactMusic { CompactMusicView(model: model) } else { MusicView(model: model) }
                    case .bar: BarView(model: model)
                    case .clipboard: ClipboardView(model: model)
                    case .plugins: PluginsView(model: model)
                    }
                }
            }
            // The same room on every tab: the sides and bottom match the header's tabs.
            // The office runs edge to edge; its own bar keeps the inset.
            .padding(.horizontal, fullBleed ? 0 : NotchLayout.inset)
            .padding(.top, NotchLayout.contentTop)
            .padding(.bottom, fullBleed ? 0 : NotchLayout.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The same header on every panel: three slots each side of the camera, packed
    /// from the outer edges, so the panel stays centred and both sides end the same
    /// distance from the camera. Left: Agents, Usage, Music. Right: Clipboard,
    /// Plugins and the agents' badge, which keeps its slot even when nothing runs.
    private var header: some View {
        let size = NotchEars.musicTab
        return HStack(spacing: 0) {
            tabs([Tab.agents, .usage, .music][...], size: size)
            Spacer(minLength: layout.notch.width)
            HStack(spacing: size.spacing) {
                tabs([Tab.clipboard, .plugins][...], size: size)
                AgentSlot(board: model.board, approvals: Set(model.approvals.map { AgentBoard.agentName($0.provider) }))
                    .frame(width: size.width, height: 22)
            }
        }
        .padding(.horizontal, NotchLayout.inset)
    }

    private func tabs(_ list: ArraySlice<Tab>, size: (width: Double, spacing: Double)) -> some View {
        HStack(spacing: size.spacing) {
            ForEach(Array(list), id: \.self) { tab in
                TabButton(tab: tab, selected: model.tab == tab && !model.showsCard, width: size.width,
                          help: tab == .agents ? (model.agentsOffice ? "Agents: the office. Click again for the list"
                                                                     : "Agents: the list. Click again for the office") : nil) {
                    // Agents again, while on it: switch between the list and the office.
                    if tab == .agents && model.tab == .agents && !model.showsCard {
                        model.agentsOffice.toggle()
                        return
                    }
                    if model.tab != tab { model.showAccounts = false }
                    model.tab = tab
                    if tab == .usage { model.refreshPlan?() }
                    if tab == .music { model.refreshVolume?() }
                }
            }
        }
    }
}

/// The agents' badge in its header slot, one tab wide: the mark of the agent
/// that needs you (or has the most sessions) and how many are running.
struct AgentSlot: View {
    let board: AgentBoard
    let approvals: Set<String>

    var body: some View {
        let marks = NotchMarks.make(board, approvalsFrom: approvals)
        let total = board.working + board.waiting
        if let first = marks.shown.first {
            PulsingSymbol(name: "", logo: first.agent, color: AgentStyle.mark(first.agent), size: 12, active: !first.waiting)
                .id("\(first.agent)\(String(describing: first.attention))")
                .overlay(alignment: .bottomTrailing) {
                    if total > 1 {
                        // A tab-wide slot fits one digit and a plus; the exact counts are in the help.
                        Text(total > 9 ? "9+" : "\(total)").font(.system(size: 8, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            .offset(x: 6, y: 3)
                    }
                }
                .help((marks.shown.map { "\($0.agent): \($0.count)" } + marks.more).joined(separator: ", "))
        }
    }
}

struct TabButton: View {
    let tab: Tab
    let selected: Bool
    var width: CGFloat = 30
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: tab.symbolSize, weight: .semibold))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textMuted)
                .frame(width: width, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? tab.rawValue.capitalized)
    }
}

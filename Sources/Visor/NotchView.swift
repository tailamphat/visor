import VisorCore
import SwiftUI

/// Sizes shared by the view and the window controller's hover hit-testing.
@MainActor
struct NotchLayout {
    var notch: CGSize

    /// The left ear: the working agents' marks, the "done" news, or the artwork.
    func leftEar(_ model: AppModel) -> CGFloat {
        if let peek = model.peek {
            // ✓ (13) + mark (12), 5 apart, then the project and duration.
            var content: Double = 13 + 5 + 12
            if case .done(let turn) = peek {
                let text = [turn.project, turn.durationText].compactMap { $0 }.joined(separator: " · ")
                content += 5 + Self.textWidth(text, .systemFont(ofSize: 11, weight: .semibold))
            }
            return CGFloat(NotchEars.width(content: content))
        }
        if model.hasActivity {
            let marks = NotchMarks.make(model.board, approvalsFrom: Set(model.approvals.map { AgentBoard.agentName($0.provider) }))
            return CGFloat(NotchEars.width(content: marks.contentWidth { text in
                text.hasPrefix("+") ? Self.textWidth(text, .systemFont(ofSize: 9, weight: .bold))
                    : Self.textWidth(text, .monospacedDigitSystemFont(ofSize: 10, weight: .bold))
            }))
        }
        return CGFloat(NotchEars.width(content: model.isPlaying ? 20 : 0))
    }

    /// The right ear: "Answered", the attention bubble, music, or the quota columns.
    func rightEar(_ model: AppModel) -> CGFloat {
        if let peek = model.peek, case .answered = peek {
            return CGFloat(NotchEars.width(content: Self.textWidth("Answered", .monospacedDigitSystemFont(ofSize: 11, weight: .medium))))
        }
        if let note = model.attentionNote {
            // The app icon with its bubble 5 pt past the corner, or the bubble alone (drawn 17 pt wide).
            return CGFloat(NotchEars.width(content: note.icon == nil ? 17 : 18 + 5))
        }
        if model.isPlaying {
            let bars = 3 * 3 + 2 * 2.5
            return CGFloat(NotchEars.width(content: model.hasActivity || model.peek != nil ? NotchEars.badgedArtwork : bars))
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        // Each column is its mark (10) over its percent, as wide as the wider one.
        let columns = model.quotas.map { max(10, Self.textWidth($0.text, font)) }
        return CGFloat(NotchEars.width(content: NotchEars.quotas(columns: columns)))
    }

    /// Moves the closed shape sideways when its ears differ, keeping the notch covered.
    func shift(_ model: AppModel) -> CGFloat {
        guard !model.expanded, showsEars(model) else { return 0 }
        return CGFloat(NotchEars.shift(left: Double(leftEar(model)), right: Double(rightEar(model))))
    }

    private static func textWidth(_ text: String, _ font: NSFont) -> Double {
        Double((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The open panel's width for the tabs. Approvals keep 580 for their rule text.
    static let width: CGFloat = 520
    static let expandedSize = CGSize(width: width, height: 200)
    static let approvalSize = CGSize(width: 580, height: 193)
    static let musicSize = CGSize(width: width, height: 182)
    /// The compact Now Playing row: artwork beside title and controls.
    static let compactMusicContent: CGFloat = 70
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
            if !model.approvals.isEmpty { return Self.approvalSize }
            if model.compactMusic {
                return CGSize(width: CGFloat(NotchEars.musicWidth(notch: Double(notch.width))), height: fitting(Self.compactMusicContent))
            }
            if model.tab == .usage && model.showAccounts { return Self.accountsSize }
            if model.tab == .usage {
                if model.shows(.antigravity) && (model.antigravity != nil || model.antigravityError != nil || model.antigravityLoading) {
                    return Self.usageWithAntigravitySize
                }
                if model.shows(.openCode) && (model.openCode != nil || model.openCodeGo != nil || model.openCodeError != nil) {
                    return Self.usageWithOpenCodeSize
                }
                if model.shows(.copilot) && !model.copilot.isEmpty { return Self.usageWithCopilotSize }
            }
            if model.tab == .clipboard { return Self.clipboardSize }
            if model.tab == .agents && !model.board.sessions.isEmpty {
                // Grow with the list: a header per agent group and a row per session, then scroll.
                let groups = Set(model.board.sessions.map(\.agent)).count
                var content = CGFloat(NotchEars.agentsList(groups: groups, sessions: model.board.sessions.count))
                if !model.hooksInstalled { content += 6 + 26 }  // the Connect button under the list
                return CGSize(width: Self.expandedSize.width, height: min(Self.listMaxHeight, fitting(content)))
            }
            return model.tab == .music && model.nowPlaying != nil ? Self.musicSize : Self.expandedSize
        }
        let ears = showsEars(model) ? leftEar(model) + rightEar(model) : 0
        return CGSize(width: notch.width + ears + 2 * flare(expanded: false), height: notch.height)
    }

    func showsEars(_ model: AppModel) -> Bool {
        model.hasActivity || model.isPlaying || model.peek != nil
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
                    .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.06)))
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
                // Content hugs the hardware notch with the same gap on both sides;
                // any spare ear width goes to the outer edge.
                let gap = CGFloat(NotchEars.inset)
                left.padding(.trailing, gap).frame(width: layout.leftEar(model), alignment: .trailing)
                Spacer(minLength: layout.notch.width)
                right.padding(.leading, gap).frame(width: layout.rightEar(model), alignment: .leading)
            }
        }
        .frame(height: layout.notch.height)
    }

    @ViewBuilder private var left: some View {
        if let peek = model.peek {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.system(size: 13))
                switch peek {
                case .done(let turn):
                    AgentMark(agent: turn.agent, size: 12)
                    Text([turn.project, turn.durationText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                case .answered(let agent):
                    AgentMark(agent: agent, size: 12)
                }
            }
        } else if model.hasActivity {
            AgentBadge(board: model.board, approvals: Set(model.approvals.map { AgentBoard.agentName($0.provider) }))
        } else if model.isPlaying {
            Artwork(image: model.artwork, size: 20, corner: 5)
        }
    }

    @ViewBuilder private var right: some View {
        if let peek = model.peek, case .answered = peek {
            Text("Answered")
                .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1)
        } else if let note = model.attentionNote {
            // Takes the right side over the artwork until it's dealt with.
            let bubble = AttentionBubble(kind: note.kind, size: note.icon == nil ? 13 : 9)
            Group {
                if let icon = note.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        .overlay(alignment: .bottomTrailing) {
                            bubble.background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black)).offset(x: 5, y: 4)
                        }
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
            } else {
                EqualizerBars(color: NSColor(hex: 0xC3C2B7))
            }
        } else if !model.quotas.isEmpty {
            HStack(spacing: 6) {
                ForEach(model.quotas) { quota in
                    // Mark on top, percent below, so each agent is one narrow column.
                    VStack(spacing: 1.5) {
                        // Always the agent's own colour, so each is recognisable;
                        // the percent below carries the warning colour.
                        AgentMark(agent: quota.agent, size: 10)
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

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: layout.notch.height)
            Group {
                if let approval = model.approvals.first {
                    ApprovalView(model: model, request: approval)
                } else {
                    switch model.tab {
                    case .agents: AgentsView(model: model)
                    case .usage: if model.showAccounts { AccountsView(model: model) } else { UsageView(model: model) }
                    case .music: if model.compactMusic { CompactMusicView(model: model) } else { MusicView(model: model) }
                    case .bar: BarView(model: model)
                    case .clipboard: ClipboardView(model: model)
                    }
                }
            }
            // The same room on every tab: the sides and bottom match the header's tabs.
            .padding(.horizontal, NotchLayout.inset)
            .padding(.top, NotchLayout.contentTop)
            .padding(.bottom, NotchLayout.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Tabs left of the hardware notch, a glanceable status right of it. The
    /// compact music panel has no room for the status: its tabs sit two a side.
    @ViewBuilder private var header: some View {
        if model.compactMusic {
            HStack(spacing: 0) {
                tabs(Tab.shown.prefix(2)).padding(.leading, NotchLayout.inset)
                Spacer(minLength: layout.notch.width)
                tabs(Tab.shown.dropFirst(2)).padding(.trailing, NotchLayout.inset)
            }
        } else {
            fullHeader
        }
    }

    private func tabs(_ list: ArraySlice<Tab>) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(list), id: \.self) { tab in
                TabButton(tab: tab, selected: model.tab == tab && !model.showsCard) {
                    if model.tab != tab { model.showAccounts = false }
                    model.tab = tab
                    if tab == .usage { model.refreshPlan?() }
                    if tab == .music { model.refreshVolume?() }
                }
            }
        }
    }

    private var fullHeader: some View {
        HStack(spacing: 0) {
            tabs(Tab.shown[...])
            .padding(.leading, NotchLayout.inset)
            Spacer(minLength: layout.notch.width + 16)
            HStack(spacing: 8) {
                if model.hasActivity { AgentBadge(board: model.board, approvals: Set(model.approvals.map { AgentBoard.agentName($0.provider) })) }
                if let session = model.plan?.session, model.shows(.claude) {
                    Text("\(Int(session.percentLeft.rounded()))% left")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(Theme.textSecondary)
                }
                if model.tab == .usage && !model.showsCard {
                    Button {
                        model.showAccounts.toggle()
                        if model.showAccounts { model.refreshPlan?() }
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(model.showAccounts ? Theme.textPrimary : Theme.textMuted)
                            .frame(width: 24, height: 22)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(model.showAccounts ? Color.white.opacity(0.14) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Connected accounts")
                }
            }
            .padding(.trailing, NotchLayout.inset)
        }
    }
}

struct TabButton: View {
    let tab: Tab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textMuted)
                .frame(width: 30, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.rawValue.capitalized)
    }
}

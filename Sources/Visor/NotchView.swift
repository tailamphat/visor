import VisorCore
import SwiftUI

/// Sizes shared by the view and the window controller's hover hit-testing.
@MainActor
struct NotchLayout {
    var notch: CGSize

    static let earWidth: CGFloat = 38

    /// Both ears widen together (the notch stays centred) to fit a second agent
    /// mark and the +N chip.
    func earWidth(_ model: AppModel) -> CGFloat {
        CGFloat(NotchMarks.earWidth(agents: model.board.activeAgents.count))
    }
    static let expandedSize = CGSize(width: 580, height: 200)
    static let approvalSize = CGSize(width: 580, height: 196)
    static let musicSize = CGSize(width: 580, height: 196)
    static let clipboardSize = CGSize(width: 580, height: 240)
    /// Usage with Copilot below Claude.
    static let usageWithCopilotSize = CGSize(width: 580, height: 272)
    /// The window is a little larger than the biggest panel, room for the shadow.
    static let windowSize = CGSize(width: 620, height: 320)

    func flare(expanded: Bool) -> CGFloat { expanded ? 12 : 6 }

    func size(for model: AppModel) -> CGSize {
        if model.expanded {
            if !model.approvals.isEmpty { return Self.approvalSize }
            if model.tab == .usage && !model.copilot.isEmpty { return Self.usageWithCopilotSize }
            if model.tab == .clipboard { return Self.clipboardSize }
            if model.tab == .agents && !model.board.sessions.isEmpty {
                // Grow with the list: a header per agent group and a row per session, then scroll.
                let groups = Set(model.board.sessions.map(\.agent)).count
                let content = CGFloat(groups) * 24 + CGFloat(model.board.sessions.count) * 52 + 30
                return CGSize(width: Self.expandedSize.width,
                              height: min(NotchLayout.windowSize.height - 28, max(Self.expandedSize.height, notch.height + content)))
            }
            return model.tab == .music && model.nowPlaying != nil ? Self.musicSize : Self.expandedSize
        }
        let ears = showsEars(model) ? 2 * earWidth(model) : 0
        return CGSize(width: notch.width + ears + 2 * flare(expanded: false), height: notch.height)
    }

    func showsEars(_ model: AppModel) -> Bool {
        model.hasActivity || model.isPlaying || model.justFinished
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
            if model.expanded && !model.approvals.isEmpty {
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
                left.frame(width: layout.earWidth(model))
                Spacer(minLength: layout.notch.width)
                right.frame(width: layout.earWidth(model))
            }
        }
        .frame(height: layout.notch.height)
    }

    @ViewBuilder private var left: some View {
        if model.hasActivity {
            AgentBadge(board: model.board, approvals: model.approvals.count)
        } else if model.justFinished {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.system(size: 14))
        } else if model.isPlaying {
            Artwork(image: model.artwork, size: 20, corner: 5)
        }
    }

    @ViewBuilder private var right: some View {
        if model.isPlaying {
            if model.hasActivity || model.justFinished {
                // The agent has the left side: show "playing" as a bar badge on the artwork.
                Artwork(image: model.artwork, size: 20, corner: 5)
                    .overlay(alignment: .bottomTrailing) {
                        EqualizerBars.mini(color: model.artworkTint ?? .white, active: true)
                            .padding(2.5)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black))
                            .offset(x: 4, y: 4)
                    }
            } else {
                EqualizerBars(color: NSColor(hex: 0xC3C2B7))
            }
        } else if let left = model.plan?.session?.percentLeft {
            Text("\(Int(left.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(left <= 10 ? Theme.critical : left <= 25 ? Theme.warning : Theme.textSecondary)
        }
    }
}

/// What each agent looks like: its mark and colour.
enum AgentStyle {
    static func symbol(_ agent: String) -> String {
        agent == "Copilot CLI" ? "chevron.left.forwardslash.chevron.right" : "sparkle"
    }
    /// Bright, for marks on black.
    static func mark(_ agent: String) -> NSColor {
        agent == "Copilot CLI" ? NSColor(hex: 0xA78BFA) : NSColor(hex: 0xD97757)
    }
    /// The tile behind the mark in lists.
    static func tile(_ agent: String) -> [Color] {
        agent == "Copilot CLI" ? [Color(hex: 0xA07BF0), Color(hex: 0x6E40C9)] : [Color(hex: 0xE48A6B), Color(hex: 0xB9583B)]
    }
}

/// The closed notch's agent marks: one per agent with its count, at most two,
/// then "+N". An agent waiting for you shows as an amber bubble and always
/// gets one of the two slots (the board lists waiting agents first).
struct AgentBadge: View {
    let board: AgentBoard
    let approvals: Int

    var body: some View {
        let marks = NotchMarks.make(board, pendingApproval: approvals > 0)
        return HStack(spacing: 6) {
            ForEach(marks.shown, id: \.agent) { entry in
                HStack(spacing: 2) {
                    PulsingSymbol(name: entry.waiting ? "exclamationmark.bubble.fill" : AgentStyle.symbol(entry.agent),
                                  color: entry.waiting ? NSColor(hex: 0xFAB219) : AgentStyle.mark(entry.agent),
                                  size: entry.agent == "Copilot CLI" && !entry.waiting ? 11 : 13)
                        .id("\(entry.agent)\(entry.waiting)")
                    if entry.count > 1 {
                        Text("\(entry.count)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
                .help(entry.waiting ? "\(entry.agent) needs you" : "\(entry.agent): \(entry.count) working")
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
                    case .usage: UsageView(model: model)
                    case .music: MusicView(model: model)
                    case .bar: BarView(model: model)
                    case .clipboard: ClipboardView(model: model)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Tabs left of the hardware notch, a glanceable status right of it.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    TabButton(tab: tab, selected: model.tab == tab && model.approvals.isEmpty) {
                        model.tab = tab
                        if tab == .usage { model.refreshPlan?() }
                        if tab == .music { model.refreshVolume?() }
                    }
                }
            }
            .padding(.leading, 14)
            Spacer(minLength: layout.notch.width + 16)
            HStack(spacing: 8) {
                if model.hasActivity { AgentBadge(board: model.board, approvals: model.approvals.count) }
                if let session = model.plan?.session {
                    Text("\(Int(session.percentLeft.rounded()))% left")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.trailing, 16)
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

import NotchboardCore
import SwiftUI

/// Sizes shared by the view and the window controller's hover hit-testing.
@MainActor
struct NotchLayout {
    var notch: CGSize

    static let earWidth: CGFloat = 38
    static let expandedSize = CGSize(width: 580, height: 200)
    static let approvalSize = CGSize(width: 580, height: 162)
    static let musicSize = CGSize(width: 580, height: 140)
    /// The window is a little larger than the biggest panel, room for the shadow.
    static let windowSize = CGSize(width: 620, height: 240)

    func flare(expanded: Bool) -> CGFloat { expanded ? 12 : 6 }

    func size(for model: AppModel) -> CGSize {
        if model.expanded {
            if !model.approvals.isEmpty { return Self.approvalSize }
            return model.tab == .music && model.nowPlaying != nil ? Self.musicSize : Self.expandedSize
        }
        let ears = showsEars(model) ? 2 * Self.earWidth : 0
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
        .background(alignment: .topLeading) {
            // Album-art glow behind the music panel.
            if model.showsMusic, let tint = model.artworkTint {
                RadialGradient(colors: [Color(nsColor: tint).opacity(0.7), Color(nsColor: tint).opacity(0.18), .clear],
                               center: UnitPoint(x: 0.12, y: 0.75), startRadius: 0, endRadius: 420)
                    .transition(.opacity)
            }
        }
        .background(Theme.surface)
        .animation(.easeOut(duration: 0.4), value: model.artworkTint)
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
                left.frame(width: NotchLayout.earWidth)
                Spacer(minLength: layout.notch.width)
                right.frame(width: NotchLayout.earWidth)
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
                Artwork(image: model.artwork, size: 20, corner: 5)
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

struct AgentBadge: View {
    let board: AgentBoard
    let approvals: Int

    var body: some View {
        let waiting = approvals > 0 || board.waiting > 0
        HStack(spacing: 3) {
            PulsingSymbol(name: waiting ? "exclamationmark.bubble.fill" : "sparkle",
                          color: NSColor(hex: waiting ? 0xFAB219 : 0xD97757), size: 13)
                .id(waiting)
            let count = board.working + board.waiting
            if count > 1 {
                Text("\(count)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textSecondary)
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

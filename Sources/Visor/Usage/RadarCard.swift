import SwiftUI
import VisorCore

/// "What's new" at the top of Usage: one card per tool with a newer release,
/// until its x is pressed.
struct RadarSection: View {
    let model: AppModel

    static let titleHeight: CGFloat = 14
    static let spacing: CGFloat = 8

    /// The section's height plus the gap to the first tool, for the panel size.
    static func height(_ offers: [ReleaseUpdate]) -> CGFloat {
        guard !offers.isEmpty else { return 0 }
        let cards = offers.reduce(0) { $0 + RadarCard.height($1) }
        return titleHeight + CGFloat(offers.count) * spacing + cards + UsageView.toolGap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack {
                SectionHeader("What's new")
                Spacer(minLength: 8)
                let pending = model.releaseOffers.filter { !$0.updated }.count
                if pending > 0 {
                    Text(pending == 1 ? "1 update" : "\(pending) updates")
                        .font(DS.font(.sm, .semibold)).foregroundStyle(Theme.textMuted)
                }
            }
            .frame(height: Self.titleHeight)
            ForEach(model.releaseOffers, id: \.toolID) { update in
                RadarCard(update: update, updating: model.updatingTool == update.toolID, dismiss: { model.dismissRelease?(update) }, install: { model.updateRelease?(update) })
            }
        }
    }
}

/// A tool, installed -> latest, its top changes, and the x. Update runs the tool's
/// own command in a new Terminal window.
struct RadarCard: View {
    let update: ReleaseUpdate
    let updating: Bool
    let dismiss: () -> Void
    let install: () -> Void

    static let padding: CGFloat = 10
    static let titleRow: CGFloat = 20
    static let changeRow: CGFloat = 15
    static let gap: CGFloat = 5

    /// An updated card is its title row only.
    static func height(_ update: ReleaseUpdate) -> CGFloat {
        let changes = update.updated ? 0 : CGFloat(min(update.changes.count, 3))
        return padding * 2 + titleRow + changes * (changeRow + gap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: 7) {
                AgentMark(agent: update.name, size: 16)
                Text(update.name).font(DS.font(.lg, .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).fixedSize()
                Group {
                    if update.updated {
                        Text(update.installed.description).foregroundStyle(Theme.textPrimary)
                    } else {
                        Text("\(update.installed.description) → ").foregroundStyle(Theme.textSecondary)
                            + Text(update.latest.description).foregroundStyle(Theme.textPrimary)
                    }
                }
                .font(DS.font(.base, .medium, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 8)
                if update.updated {
                    Label("Updated", systemImage: "checkmark").labelStyle(.titleAndIcon)
                        .font(DS.font(.base, .semibold)).foregroundStyle(Theme.onPace).lineLimit(1)
                } else if updating {
                    Text("Updating…").font(DS.font(.sm)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                } else if update.command != nil {
                    Button("Update", action: install)
                        .buttonStyle(CardButton(.secondary))
                        .help("Run the update in a new Terminal window")
                }
                if !update.updated {
                    DismissButton(help: "Dismiss this update", action: dismiss)
                }
            }
            .frame(height: Self.titleRow)
            ForEach(Array(update.changes.prefix(update.updated ? 0 : 3).enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(Theme.textMuted)
                    Text(change).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                }
                .font(DS.font(.base))
                .frame(height: Self.changeRow)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(Theme.raised))
    }
}

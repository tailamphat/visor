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
                Text("WHAT'S NEW").kerning(0.4)
                Spacer(minLength: 8)
                Text(model.releaseOffers.count == 1 ? "1 update" : "\(model.releaseOffers.count) updates")
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textMuted)
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
    /// The Update button's width.
    static let actionSlot: CGFloat = 58

    static func height(_ update: ReleaseUpdate) -> CGFloat {
        let changes = CGFloat(min(update.changes.count, 3))
        return padding * 2 + titleRow + changes * (changeRow + gap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: 7) {
                AgentMark(agent: update.name, size: 16)
                Text(update.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).fixedSize()
                (Text("\(update.installed.description) → ").foregroundStyle(Theme.textSecondary)
                 + Text(update.latest.description).foregroundStyle(Theme.textPrimary))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 8)
                if updating {
                    Text("Updating in Terminal…").font(.system(size: 10)).minimumScaleFactor(0.8).foregroundStyle(Theme.textSecondary).lineLimit(1)
                } else if update.command != nil {
                    Button(action: install) {
                        Text("Update").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            .frame(width: Self.actionSlot, height: Self.titleRow)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Run the update in a new Terminal window")
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss this update")
            }
            .frame(height: Self.titleRow)
            ForEach(Array(update.changes.prefix(3).enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(Theme.textMuted)
                    Text(change).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 11.5))
                .frame(height: Self.changeRow)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
    }
}

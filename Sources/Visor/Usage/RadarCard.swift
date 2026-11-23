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
                let pending = model.releaseOffers.filter { !$0.updated }.count
                if pending > 0 { Text(pending == 1 ? "1 update" : "\(pending) updates") }
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

    /// An updated card is its title row only.
    static func height(_ update: ReleaseUpdate) -> CGFloat {
        let changes = update.updated ? 0 : CGFloat(min(update.changes.count, 3))
        return padding * 2 + titleRow + changes * (changeRow + gap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            HStack(spacing: 7) {
                AgentMark(agent: update.name, size: 16)
                Text(update.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).fixedSize()
                Group {
                    if update.updated {
                        Text(update.installed.description).foregroundStyle(Theme.textPrimary)
                    } else {
                        Text("\(update.installed.description) → ").foregroundStyle(Theme.textSecondary)
                            + Text(update.latest.description).foregroundStyle(Theme.textPrimary)
                    }
                }
                .font(.system(size: 11.5, weight: .medium, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 8)
                if update.updated {
                    Label("Updated", systemImage: "checkmark").labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onPace).lineLimit(1)
                } else if updating {
                    Text("Updating…").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
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
                if !update.updated {
                    Button(action: dismiss) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss this update")
                }
            }
            .frame(height: Self.titleRow)
            ForEach(Array(update.changes.prefix(update.updated ? 0 : 3).enumerated()), id: \.offset) { _, change in
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

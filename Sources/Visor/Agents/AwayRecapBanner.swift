import SwiftUI
import VisorCore

/// On top of the Agents list after 10+ minutes locked: what changed while you
/// were away, waiting on you first, with how long ago each happened. Got it
/// dismisses it; the primary button brings the top item's app forward.
/// It shows `model.away`, which shrinks as each item is handled.
struct AwayRecapBanner: View {
    let away: AwayDigest
    let model: AppModel
    static let titleHeight: CGFloat = 16
    static let rowHeight: CGFloat = 15
    static let buttonsHeight: CGFloat = 18
    static let spacing: CGFloat = 3

    /// The title, a row per item (at most `AwayDigest.maxRows`), "+n more" past
    /// that, and the buttons, inside the banner's inset.
    static func height(for away: AwayDigest) -> CGFloat {
        let (rows, more) = away.rows(limit: AwayDigest.maxRows)
        let lines = Array(repeating: Double(rowHeight), count: rows.count + (more > 0 ? 1 : 0))
        return CGFloat(DesignComponents.Banner.height(rows: [Double(titleHeight)] + lines + [Double(buttonsHeight)],
                                                      spacing: Double(spacing)))
    }

    var body: some View {
        let (rows, more) = away.rows(limit: AwayDigest.maxRows)
        let top = away.top
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(spacing: 6) {
                Text(away.title).font(DS.font(.base, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                if let top, top.kind == .approval || top.kind == .question { SectionHeader("Waiting on you first") }
            }
            .frame(height: Self.titleHeight)
            ForEach(rows) { item in row(item) }
            if more > 0 {
                Text("+\(more) more").font(DS.font(.sm)).foregroundStyle(Theme.textMuted)
                    .frame(height: Self.rowHeight)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 6)
                Button("Got it") { model.dismissAway?() }.buttonStyle(CardButton(.secondary))
                    .help("Dismiss this recap")
                // Only while the top item's session is still there to bring forward.
                if let top, let session = model.board.sessions.first(where: { $0.id == top.session }) {
                    Button("Open \(top.project)") { model.openAway?() }.buttonStyle(CardButton(.primary))
                        .help(session.host.map { "Open \($0)" } ?? "Open")
                }
            }
            .frame(height: Self.buttonsHeight)
        }
        .bannerCard(tint: (top?.kind ?? .finished).tint, height: Self.height(for: away))
    }

    private func row(_ item: AwayItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind.symbol)
                .font(DS.font(.base, .semibold))
                .foregroundStyle(item.kind.tint.onColour, item.kind.tint.solidFill)
            // A long project name gives way first, so what happened stays readable.
            HStack(spacing: 0) {
                Text(item.project).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(" · " + item.detail).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            }
            .font(DS.font(.base))
            Spacer(minLength: 6)
            Text(SessionText.ago(item.at, now: model.agentsNow))
                .font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textMuted).lineLimit(1).fixedSize()
        }
        .frame(height: Self.rowHeight)
        .help("\(item.agent): \(item.project) · \(item.detail)")
    }
}

extension AwayItem.Kind {
    /// The same colours as the closed notch's signs: amber approval, blue
    /// question, coral Stuck, green finished.
    var tint: Color {
        switch self {
        case .approval: return Theme.warning
        case .question: return Theme.question
        case .stuck: return Theme.stuck
        case .finished: return Theme.good
        }
    }

    var symbol: String {
        switch self {
        case .approval: return "exclamationmark.circle.fill"
        case .question: return "questionmark.circle.fill"
        case .stuck: return "arrow.triangle.2.circlepath.circle.fill"
        case .finished: return "checkmark.circle.fill"
        }
    }
}

/// The count on the top item's mark in the away peek, in the top kind's solid
/// fill with its on-colour text.
struct AwayCountBadge: View {
    let count: Int
    let kind: AwayItem.Kind
    /// How much of the mark's corner it covers; a wider count ("9+") grows
    /// outward from there instead of over the mark.
    static let overlap: CGFloat = 6
    /// Clear room after it: the margin the other peeks' round symbols have,
    /// so the gap to the camera reads the same.
    static let margin: CGFloat = 1

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(DS.font(.xs, .bold).monospacedDigit())
            .foregroundStyle(kind.tint.onColour)
            .padding(.horizontal, 3)
            .background(Capsule().fill(kind.tint.solidFill))
            .background(Capsule().fill(Theme.surface).padding(-1.5))
            .fixedSize()
    }
}

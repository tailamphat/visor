import SwiftUI
import VisorCore

/// Over the Agents list while a Claude limit runs out soon: when, the agents
/// with room (up to three), Later and a button that copies the handoff note.
/// It shows `model.handoff`, which is re-derived on every reading, so it goes
/// by itself once the handoff no longer applies.
struct HandoffBanner: View {
    let handoff: Handoff
    let model: AppModel
    static let maxTargets = 3
    static let rowHeight: CGFloat = 14
    static let spacing: CGFloat = 3

    static func height(for handoff: Handoff) -> CGFloat {
        let targets = Array(repeating: Double(rowHeight), count: min(maxTargets, handoff.targets.count))
        return CGFloat(DesignComponents.Banner.height(rows: [16] + targets + [18], spacing: Double(spacing)))
    }

    var body: some View {
        let now = model.agentsNow
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(spacing: 6) {
                AgentMark(agent: "Claude Code", size: 13)
                (Text(title(now: now)).fontWeight(.semibold).foregroundColor(Theme.textPrimary)
                    + Text(project.map { " · \($0)" } ?? "").foregroundColor(Theme.textMuted))
                    .font(DS.font(.base)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text("resets " + SessionText.reset(handoff.resetsAt, now: now))
                    .font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textMuted).lineLimit(1).fixedSize()
            }
            .frame(height: 16)
            ForEach(handoff.targets.prefix(Self.maxTargets), id: \.agent) { target in
                HStack(spacing: 8) {
                    Text(target.agent).font(DS.font(.sm)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).frame(width: 78, alignment: .leading)
                    // No bar without a percent: an empty track would read as "nothing left".
                    if let left = target.percentLeft {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(DS.Fill.subtle)
                                Capsule().fill(Theme.onPace).frame(width: geometry.size.width * min(1, max(0, left / 100)))
                            }
                        }
                        .frame(height: Theme.barHeight)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Text(HandoffInputs.label(for: target, antigravityUpdated: model.antigravityUpdated, now: now))
                        .font(DS.font(.sm, design: .monospaced))
                        .foregroundStyle(target.percentLeft == nil ? Theme.textMuted : Theme.textPrimary)
                        .lineLimit(1).fixedSize()
                        .help(target.agent == "Antigravity" && target.percentLeft == nil ? "Open Usage to check again" : "")
                }
                .frame(height: Self.rowHeight)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 6)
                Button("Later") { model.laterHandoff?(handoff) }.buttonStyle(CardButton(.secondary))
                    .help("Hide until this limit resets")
                Button(model.handoffCopied == handoff.id ? "Copied" : "Copy handoff for \(handoff.targets.first?.agent ?? "")") {
                    model.copyHandoff?(handoff)
                }
                .buttonStyle(CardButton(.primary))
                .help("Copies a note for the other agent: project, task, files touched, last test run")
            }
            .frame(height: 18)
        }
        .bannerCard(tint: Theme.warning, height: Self.height(for: handoff))
    }

    private var project: String? {
        model.board.sessions.first { $0.id == handoff.sessionID }?.project
    }

    private func title(now: Date) -> String {
        guard let at = handoff.runsOutAt, at > now, let time = BurnForecast.duration(at.timeIntervalSince(now)) else {
            return "Claude \(handoff.limitTitle) limit is out"
        }
        return "Claude limit runs out in ~\(time)"
    }
}

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
        let rows = CGFloat(min(maxTargets, handoff.targets.count))
        return 2 * 7 + 16 + 18 + rows * rowHeight + (rows + 1) * spacing
    }

    var body: some View {
        let now = model.agentsNow
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(spacing: 6) {
                AgentMark(agent: "Claude Code", size: 13)
                (Text(title(now: now)).fontWeight(.semibold).foregroundColor(Theme.textPrimary)
                    + Text(project.map { " · \($0)" } ?? "").foregroundColor(Theme.textMuted))
                    .font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text("resets " + SessionText.reset(handoff.resetsAt, now: now))
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textMuted).lineLimit(1).fixedSize()
            }
            .frame(height: 16)
            ForEach(handoff.targets.prefix(Self.maxTargets), id: \.agent) { target in
                HStack(spacing: 8) {
                    Text(target.agent).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).frame(width: 78, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            if let left = target.percentLeft {
                                Capsule().fill(Theme.onPace).frame(width: geometry.size.width * min(1, max(0, left / 100)))
                            }
                        }
                    }
                    .frame(height: Theme.barHeight)
                    Text(target.percentLeft.map { "\(Int($0.rounded()))% left" } ?? "no recent reading")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(target.percentLeft == nil ? Theme.textMuted : Theme.textPrimary)
                        .lineLimit(1).fixedSize()
                }
                .frame(height: Self.rowHeight)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 6)
                button("Later", primary: false) { model.laterHandoff?(handoff) }
                    .help("Hide until this limit resets")
                button(model.handoffCopied == handoff.id ? "Copied" : "Copy handoff for \(handoff.targets.first?.agent ?? "")",
                       primary: true) { model.copyHandoff?(handoff) }
                    .help("Copies a note for the other agent: project, task, files touched, last test run")
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: Self.height(for: handoff))
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.warning.opacity(0.35), lineWidth: 1))
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

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(primary ? .white : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 9).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(primary ? Theme.accent : Color.white.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

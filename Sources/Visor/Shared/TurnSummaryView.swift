import SwiftUI
import VisorCore

/// What a turn just did, when the notch opens during its "done" peek: how long
/// it took, the files it changed and by how much, the commands it ran, and how
/// its tests went, with a way back to the agent and to the diff.
struct TurnSummaryView: View {
    let model: AppModel
    let turn: FinishedTurn
    static let height: CGFloat = 122

    var body: some View {
        let stats = turn.stats
        let session = model.board.sessions.first { $0.id == turn.sessionID }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").font(DS.font(.lg)).foregroundStyle(Theme.good)
                Text("\(turn.project) finished").font(DS.font(.lg, .semibold)).foregroundStyle(Theme.textPrimary)
                if let time = turn.durationText {
                    Text("· \(time)").font(DS.font(.md)).foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
                AgentMark(agent: turn.agent, size: 12)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    figure("\(stats.files.count)", stats.files.count == 1 ? "file changed" : "files changed")
                    figure("+\(stats.added) −\(stats.removed)", "lines")
                    figure("\(stats.commands)", stats.commands == 1 ? "command" : "commands")
                    if let tests = stats.tests { testFigure(tests) }
                }
                let (files, more) = stats.shortFiles(in: turn.cwd, limit: 3)
                if !files.isEmpty {
                    Text(files.joined(separator: " · ") + (more > 0 ? "  +\(more)" : ""))
                        .font(DS.font(.base, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(Theme.raised))
            HStack(spacing: 6) {
                if let session {
                    pill(session.host.map { "Open in \($0)" } ?? "Open the terminal") { model.focusAgent?(session) }
                }
                if !stats.files.isEmpty { pill("View diff") { model.viewDiff?(turn) } }
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(DS.font(.lg, .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            Text(label).font(DS.font(.sm)).foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private func testFigure(_ tests: TurnStats.Tests) -> some View {
        switch tests {
        case .passed(let command): status("tests passed", command, Theme.good)
        case .failed(let command): status("tests failed", command, Theme.critical)
        case .ran(let command): status("tests ran", command, Theme.textPrimary)
        }
    }

    private func status(_ title: String, _ command: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(DS.font(.lg, .semibold)).foregroundStyle(color)
            Text(command).font(DS.font(.sm)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
        }
        .help(command)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(DS.font(.base, .semibold)).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(Theme.raised))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

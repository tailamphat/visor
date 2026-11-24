import SwiftUI
import VisorCore

/// Shown for a few seconds when a limit that had run out, or nearly, resets.
struct LimitBackView: View {
    let back: LimitReturn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                AgentIcon(agent: back.agent, size: 22)
                Text("\(back.agent == "Claude Code" ? "Claude" : back.agent) limit is back")
                    .font(DS.font(.lg, .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("just now").font(DS.font(.base)).foregroundStyle(Theme.textMuted)
            }
            LimitMeter(title: back.title, used: 100 - back.percentLeft, caption: caption)
        }
    }

    /// "Ran out at 14:05 · next reset 20:00"
    private var caption: String {
        [back.ranOutAt.map { "Ran out at " + $0.formatted(date: .omitted, time: .shortened) },
         back.nextReset.map { "next reset " + LimitMeter.resetPhrase($0) }]
            .compactMap { $0 }.joined(separator: " · ").capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct ApprovalView: View {
    let model: AppModel
    let request: ApprovalRequest

    /// "in notchboard · Ghostty"
    static func place(session: AgentSession?, project: String) -> String {
        let parts = [project.isEmpty ? nil : "in \(project)", session?.host].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            let session = model.board.sessions.first { $0.id == request.sessionID }
            // Who is asking: agent, where it runs, which project.
            let agent = session?.agent ?? AgentBoard.agentName(request.provider)
            HStack(spacing: 7) {
                AgentIcon(agent: agent, size: 22)
                Text(agent)
                    .font(DS.font(.lg, .semibold))
                    .foregroundStyle(AgentStyle.name(agent))
                Text(Self.place(session: session, project: request.project))
                    .font(DS.font(.md)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                if model.approvals.count > 1 {
                    Text("+\(model.approvals.count - 1) more").font(DS.font(.base)).foregroundStyle(Theme.textMuted)
                }
            }
            // What it wants, and the task it's working on.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("wants to \(request.action)")
                    .font(DS.font(.xl, .semibold)).foregroundStyle(Theme.textPrimary)
                if let task = session?.task {
                    Text("· \(task)").font(DS.font(.base)).foregroundStyle(Theme.textMuted).lineLimit(1)
                        .help(task)
                }
            }
            (Text(request.tool == "Bash" ? "$ " : "").foregroundColor(Theme.textMuted) + Text(request.preview))
                .font(DS.font(.md, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(DS.Fill.subtle))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DS.Fill.subtle, lineWidth: 1))
            // Deny and Allow, each as wide as its label, together in the centre.
            HStack(spacing: 8) {
                Button { model.decide?(request, .deny) } label: {
                    Label { KeyHint(title: "Deny", key: "esc") } icon: { Image(systemName: "xmark") }
                }
                .buttonStyle(ConsentButton(kind: .deny))
                Button { model.decide?(request, .allow) } label: {
                    Label { KeyHint(title: "Allow", key: "↩") } icon: { Image(systemName: "checkmark") }
                }
                .buttonStyle(ConsentButton(kind: .allow))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
            // "Always" is the choice to make deliberately: a quiet link under them, its rule in view.
            if let always = request.alwaysAllowLabel {
                Button { model.decide?(request, .allowAlways) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(DS.font(.sm, .semibold))
                        Text("Always allow")
                        Text(always).font(DS.font(.base, design: .monospaced)).foregroundStyle(DS.Palette.mint).lineLimit(1)
                        KeyCap(key: "A")
                    }
                    .font(DS.font(.base, .medium))
                    .foregroundStyle(DS.Palette.alwaysText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help("Allow this now, and don't ask again for \(always)")
            }
        }
    }
}

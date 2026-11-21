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
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("just now").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(agent == "Copilot CLI" ? Color(hex: 0xC4B0FF) : Color(hex: 0xF0A58A))
                Text(Self.place(session: session, project: request.project))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                if model.approvals.count > 1 {
                    Text("+\(model.approvals.count - 1) more").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            // What it wants, and the task it's working on.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("wants to \(request.action)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let task = session?.task {
                    Text("· \(task)").font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                        .help(task)
                }
            }
            (Text(request.tool == "Bash" ? "$ " : "").foregroundColor(Theme.textMuted) + Text(request.preview))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
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
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                        Text("Always allow")
                        Text(always).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: 0x8FB89C)).lineLimit(1)
                        KeyCap(key: "A")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(hex: 0xB9D9C3))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help("Allow this now, and don't ask again for \(always)")
            }
        }
    }
}

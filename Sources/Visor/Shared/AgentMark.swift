import SwiftUI
import VisorCore

// Agent brand marks: each tool's own logo and colour, outside the design system by
// the epic (scripts/design-literals.txt skips this file, as it does AgentStyle).

/// The agent's own mark in its brand colour, on a dark tile.
struct AgentIcon: View {
    var agent = "Claude Code"
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(AgentStyle.tile)
            .frame(width: size, height: size)
            .overlay(AgentMark(agent: agent, size: size * 0.62))
    }
}

/// The agent's own mark (Claude's starburst, Copilot's face), drawn from its vector artwork.
struct AgentMark: View {
    var agent: String
    var size: CGFloat
    var color: Color?

    var body: some View {
        LogoShape(agent: agent).fill(color ?? Color(nsColor: AgentStyle.mark(agent)))
            .frame(width: size, height: size)
            .accessibilityLabel(agent)
    }
}

struct LogoShape: Shape {
    let agent: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return Path(AgentLogo.path(for: agent))
            .applying(CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale).scaledBy(x: scale, y: scale))
    }
}

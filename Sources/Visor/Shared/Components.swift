import SwiftUI
import VisorCore

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var button: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Theme.textMuted)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if let button, let action {
                Button(button, action: action).buttonStyle(PillButton(fill: Theme.accent)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Approval buttons: a quiet outlined Deny, a neutral Always allow, and a
/// solid Allow as the main action. All press down slightly.
struct ConsentButton: ButtonStyle {
    enum Kind { case deny, secondary, allow }
    var kind: Kind

    static let mint = Color(hex: 0x7EE0A0)
    static let rose = Color(hex: 0xFF8F86)

    /// Soft mint: a solid mint Allow, a mint-tinted Always, a rose-tinted Deny.
    private var text: Color {
        switch kind {
        case .allow: return Color(hex: 0x06260F)
        case .secondary: return Color(hex: 0xC9F3D6)
        case .deny: return Color(hex: 0xFF9D95)
        }
    }
    private var fill: Color {
        switch kind {
        case .allow: return Self.mint
        case .secondary: return Self.mint.opacity(0.12)
        case .deny: return Self.rose.opacity(0.12)
        }
    }
    private var stroke: Color {
        switch kind {
        case .allow: return .clear
        case .secondary: return Self.mint.opacity(0.25)
        case .deny: return Self.rose.opacity(0.25)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .labelStyle(ConsentLabel())
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .brightness(pressed ? -0.08 : 0)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(Capsule())
    }
}

/// A button title with the key that presses it while the pointer is over the card.
struct KeyHint: View {
    let title: String
    let key: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            KeyCap(key: key)
        }
    }
}

struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.foreground.opacity(0.16)))
            .opacity(0.8)
            .help("Press \(key) while the pointer is over the card")
    }
}

/// Icon then title, with the icon a touch bolder.
struct ConsentLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .bold))
            configuration.title
        }
    }
}

struct PillButton: ButtonStyle {
    var fill: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule())
    }
}

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

/// A band of diagonal grey stripes: a plugin's `ui.divider()`, which can't be
/// mistaken for a meter's solid track.
struct ToolDivider: View {
    static let band: CGFloat = 6
    static let room: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
            var stripes = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(stripes, with: .color(.white.opacity(0.16)), lineWidth: 1.5)
        }
        .frame(height: Self.band)
        .padding(.vertical, Self.room)
        .accessibilityHidden(true)
    }
}

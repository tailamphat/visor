import SwiftUI
import VisorCore

private typealias Spec = DesignComponents

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var button: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: DS.Size.iconLarge)).foregroundStyle(Theme.textMuted)
            Text(title).font(DS.font(.lg, .semibold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(DS.font(.base)).foregroundStyle(Theme.textSecondary)
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

    static let mint = DS.Palette.mint
    static let rose = DS.Palette.rose

    /// Soft mint: a solid mint Allow, a mint-tinted Always, a rose-tinted Deny.
    private var text: Color {
        switch kind {
        case .allow: return DS.Palette.allowText
        case .secondary: return DS.Palette.alwaysText
        case .deny: return DS.Palette.denyText
        }
    }
    private var fill: Color {
        switch kind {
        case .allow: return Self.mint
        case .secondary: return Self.mint.opacity(DS.Fill.Opacity.medium)
        case .deny: return Self.rose.opacity(DS.Fill.Opacity.medium)
        }
    }
    private var stroke: Color {
        switch kind {
        case .allow: return .clear
        case .secondary: return Self.mint.opacity(DS.Fill.Opacity.heavy)
        case .deny: return Self.rose.opacity(DS.Fill.Opacity.heavy)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .labelStyle(ConsentLabel())
            .font(DS.font(.md, .semibold))
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
            .font(.system(size: CGFloat(Spec.KeyCap.type), weight: .semibold))
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: CGFloat(Spec.KeyCap.radius), style: .continuous)
                .fill(.foreground.opacity(Spec.KeyCap.fill)))
            .opacity(Spec.KeyCap.opacity)
            .help("Press \(key) while the pointer is over the card")
    }
}

/// Icon then title, with the icon a touch bolder.
struct ConsentLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(DS.font(.base, .bold))
            configuration.title
        }
    }
}

/// A capsule button on a solid fill; its text takes the fill's on-colour.
struct PillButton: ButtonStyle {
    var fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.font(.md, .semibold))
            .foregroundStyle(fill.onColour)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule().fill(configuration.isPressed ? fill.pressedFill : fill))
            .contentShape(Capsule())
    }
}

/// A band of diagonal grey stripes: a plugin's `ui.divider()`, which can't be
/// mistaken for a meter's solid track.
struct ToolDivider: View {
    static let band: CGFloat = 6
    static let room: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            context.clip(to: Capsule(style: .continuous).path(in: CGRect(origin: .zero, size: size)))
            var stripes = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(stripes, with: .color(DS.Fill.strong), lineWidth: 1.5)
        }
        .frame(height: Self.band)
        .padding(.vertical, Self.room)
        .accessibilityHidden(true)
    }
}

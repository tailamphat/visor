import SwiftUI
import VisorCore

/// Shared components, drawn from `DesignComponents` (VisorCore, tested) and the
/// `DS` tokens. Use these instead of a view's own button, badge or card chrome.

private typealias Spec = DesignComponents

/// A small button inside a card: `.primary` (accent fill, white text) for the
/// main action, `.secondary` (white fill) beside it. Dims while held.
struct CardButton: ButtonStyle {
    enum Kind { case primary, secondary }

    var kind: Kind
    /// The primary fill; nil is Visor's accent (a plugin passes its own).
    var tint: Color?

    init(_ kind: Kind, tint: Color? = nil) {
        self.kind = kind
        self.tint = tint
    }

    private var fill: Color {
        kind == .primary ? tint ?? Theme.accent : Color.white.opacity(Spec.CardButton.secondaryFill)
    }
    private var text: Color { kind == .primary ? .white : Theme.textPrimary }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: CGFloat(Spec.CardButton.type), weight: .semibold))
            .foregroundStyle(text)
            .lineLimit(1)
            .padding(.horizontal, CGFloat(Spec.CardButton.padding))
            .frame(height: CGFloat(Spec.CardButton.height))
            .background(RoundedRectangle(cornerRadius: CGFloat(Spec.CardButton.radius), style: .continuous).fill(fill))
            .opacity(configuration.isPressed ? Spec.CardButton.pressedOpacity : 1)
            .contentShape(Rectangle())
    }
}

/// The "x" that dismisses a card.
struct DismissButton: View {
    /// The tooltip: say what goes ("Dismiss this update", "Close").
    var help = "Dismiss"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: CGFloat(Spec.DismissButton.type), weight: .bold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: CGFloat(Spec.DismissButton.size), height: CGFloat(Spec.DismissButton.size))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A small capsule label: `.solid(tint)` with black text ("Stuck?"), or
/// `.neutral` on a white fill (a version, a count).
struct Badge: View {
    enum Style { case solid(Color), neutral }

    let title: String
    var style: Style = .neutral

    init(_ title: String, _ style: Style = .neutral) {
        self.title = title
        self.style = style
    }

    var body: some View {
        Text(title).font(.system(size: CGFloat(Spec.Badge.type), weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, CGFloat(Spec.Badge.paddingX)).padding(.vertical, CGFloat(Spec.Badge.paddingY))
            .background(Capsule().fill(fill))
    }

    private var foreground: Color {
        if case .solid = style { return .black }
        return Theme.textPrimary
    }
    private var fill: Color {
        switch style {
        case .solid(let tint): return tint
        case .neutral: return Color.white.opacity(Spec.Badge.neutralFill)
        }
    }
}

/// An uppercase muted title over a group of rows.
struct SectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.system(size: CGFloat(Spec.SectionHeader.type), weight: .semibold))
            .textCase(.uppercase).tracking(CGFloat(Spec.SectionHeader.tracking))
            .foregroundStyle(Theme.textMuted).lineLimit(1)
    }
}

extension View {
    /// A tinted banner card: the same inset on all four sides, the tint at a
    /// subtle fill inside a tint stroke. `height` fixes the card's height
    /// (`DesignComponents.Banner.height(rows:spacing:)`).
    func bannerCard(tint: Color, height: CGFloat? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(Spec.Banner.radius), style: .continuous)
        return padding(CGFloat(Spec.Banner.inset))
            .frame(height: height)
            .background(shape.fill(tint.opacity(Spec.Banner.fill)))
            .overlay(shape.strokeBorder(tint.opacity(Spec.Banner.strokeOpacity), lineWidth: 1))
    }

    /// The banner card on one line (Music hints, the clash banner): the same tint,
    /// stroke and corner at a fixed `height`, the card's inset at the sides only,
    /// so a short row isn't clipped by the inset above and below.
    func compactBanner(tint: Color, height: CGFloat = CGFloat(Spec.Banner.compactHeight)) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(Spec.Banner.radius), style: .continuous)
        return padding(.horizontal, CGFloat(Spec.Banner.inset))
            .frame(height: height)
            .background(shape.fill(tint.opacity(Spec.Banner.fill)))
            .overlay(shape.strokeBorder(tint.opacity(Spec.Banner.strokeOpacity), lineWidth: 1))
    }

    /// A drop shadow from the design system; `shown` false fades it to nothing
    /// (animated with the view, like the panel's on open).
    func dsShadow(_ shadow: DS.Shadow, shown: Bool = true) -> some View {
        self.shadow(color: .black.opacity(shown ? shadow.opacity : 0), radius: shadow.radius, y: shadow.y)
    }
}

/// Album artwork in a rounded square (closed notch, Music); a note on the
/// raised colour while there's no art.
struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.raised
                    Image(systemName: "music.note").font(.system(size: size * CGFloat(Spec.Artwork.iconRatio)))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

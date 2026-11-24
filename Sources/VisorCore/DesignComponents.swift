import Foundation

/// The shared components' measurements, all taken from `DesignTokens`. The
/// SwiftUI components in `Sources/Visor/DesignSystem/SharedComponents.swift` draw
/// with these; plain names so plugin pieces can map onto them later.
public enum DesignComponents {
    private typealias T = DesignTokens

    /// One measurement and the scale it must sit on; `scale` nil marks a
    /// component's own constant, not a token.
    public struct Measurement: Sendable {
        public let name: String
        public let value: Double
        public let scale: [DesignScale.Step]?
    }

    /// Every measurement below (a test checks each one sits on its scale).
    /// Add a new one here too.
    public static let measurements: [Measurement] = [
        Measurement(name: "CardButton.height", value: CardButton.height, scale: DesignScale.size),
        Measurement(name: "CardButton.radius", value: CardButton.radius, scale: DesignScale.radius),
        Measurement(name: "CardButton.type", value: CardButton.type, scale: DesignScale.typeScale),
        Measurement(name: "CardButton.padding", value: CardButton.padding, scale: DesignScale.space),
        Measurement(name: "CardButton.secondaryFill", value: CardButton.secondaryFill, scale: DesignScale.fill),
        Measurement(name: "CardButton.pressedOpacity", value: CardButton.pressedOpacity, scale: nil),
        Measurement(name: "Banner.inset", value: Banner.inset, scale: DesignScale.size),
        Measurement(name: "Banner.radius", value: Banner.radius, scale: DesignScale.radius),
        Measurement(name: "Banner.fill", value: Banner.fill, scale: DesignScale.fill),
        Measurement(name: "Banner.strokeOpacity", value: Banner.strokeOpacity, scale: nil),
        Measurement(name: "Banner.compactHeight", value: Banner.compactHeight, scale: nil),
        Measurement(name: "Badge.type", value: Badge.type, scale: DesignScale.typeScale),
        Measurement(name: "Badge.paddingX", value: Badge.paddingX, scale: DesignScale.space),
        Measurement(name: "Badge.paddingY", value: Badge.paddingY, scale: DesignScale.space),
        Measurement(name: "Badge.neutralFill", value: Badge.neutralFill, scale: DesignScale.fill),
        Measurement(name: "SectionHeader.type", value: SectionHeader.type, scale: DesignScale.typeScale),
        Measurement(name: "SectionHeader.tracking", value: SectionHeader.tracking, scale: nil),
        Measurement(name: "DismissButton.size", value: DismissButton.size, scale: DesignScale.size),
        Measurement(name: "DismissButton.type", value: DismissButton.type, scale: DesignScale.typeScale),
        Measurement(name: "Backdrop.artwork", value: Backdrop.artwork, scale: nil),
        Measurement(name: "Backdrop.shadeTop", value: Backdrop.shadeTop, scale: DesignScale.fill),
        Measurement(name: "Backdrop.shadeBottom", value: Backdrop.shadeBottom, scale: nil),
        Measurement(name: "Backdrop.tint", value: Backdrop.tint, scale: nil),
        Measurement(name: "Artwork.iconRatio", value: Artwork.iconRatio, scale: nil),
        Measurement(name: "KeyCap.type", value: KeyCap.type, scale: DesignScale.typeScale),
        Measurement(name: "KeyCap.radius", value: KeyCap.radius, scale: DesignScale.radius),
        Measurement(name: "KeyCap.fill", value: KeyCap.fill, scale: DesignScale.fill),
        Measurement(name: "KeyCap.opacity", value: KeyCap.opacity, scale: nil),
        Measurement(name: "Popover.radius", value: Popover.radius, scale: DesignScale.radius),
        Measurement(name: "Popover.fill", value: Popover.fill, scale: nil),
        Measurement(name: "Shadow.opacity", value: Shadow.opacity, scale: nil),
        Measurement(name: "Shadow.radius", value: Shadow.radius, scale: nil),
        Measurement(name: "Shadow.y", value: Shadow.y, scale: nil),
        Measurement(name: "Shadow.largeRadius", value: Shadow.largeRadius, scale: nil),
        Measurement(name: "Shadow.largeY", value: Shadow.largeY, scale: nil),
        Measurement(name: "Shadow.smallRadius", value: Shadow.smallRadius, scale: nil),
        Measurement(name: "Shadow.toastOpacity", value: Shadow.toastOpacity, scale: nil),
        Measurement(name: "Shadow.toastY", value: Shadow.toastY, scale: nil),
        Measurement(name: "Shadow.liftedOpacity", value: Shadow.liftedOpacity, scale: nil),
        Measurement(name: "IntroLight.dim", value: IntroLight.dim, scale: nil),
        Measurement(name: "IntroLight.halo", value: IntroLight.halo, scale: nil),
        Measurement(name: "IntroLight.haloWarm", value: IntroLight.haloWarm, scale: nil),
        Measurement(name: "IntroLight.trailMiddle", value: IntroLight.trailMiddle, scale: nil),
        Measurement(name: "IntroLight.trailWarm", value: IntroLight.trailWarm, scale: nil),
        Measurement(name: "IntroLight.glint", value: IntroLight.glint, scale: nil),
        Measurement(name: "IntroLight.glow", value: IntroLight.glow, scale: nil),
        Measurement(name: "IntroLight.trailRadius", value: IntroLight.trailRadius, scale: nil),
        Measurement(name: "IntroLight.glowRadius", value: IntroLight.glowRadius, scale: nil),
        Measurement(name: "IntroLight.sparkRadius", value: IntroLight.sparkRadius, scale: nil),
    ]

    /// A small button inside a card.
    public enum CardButton {
        public static let height = T.Size.button
        public static let radius = T.Radius.sm
        public static let type = T.TypeScale.base
        public static let padding = T.Space.md
        /// The secondary kind's white fill; the primary kind fills with the accent.
        public static let secondaryFill = T.Fill.medium
        /// Held down: the whole button at this opacity, as the plain style did.
        public static let pressedOpacity = 0.75
    }

    /// A tinted card over a list (Stuck?, handoff): the tint at `fill` inside a
    /// tint stroke, the same inset on all four sides.
    public enum Banner {
        public static let inset = T.Size.cardInset
        public static let radius = T.Radius.md
        public static let fill = T.Fill.subtle
        public static let strokeOpacity: Double = 0.35
        /// A one-line banner (Music hints): this height, the inset at the sides only.
        public static let compactHeight: Double = 26

        /// Rows of fixed heights stacked with `spacing`, inside the inset.
        public static func height(rows: [Double], spacing: Double) -> Double {
            2 * inset + rows.reduce(0, +) + Double(max(0, rows.count - 1)) * spacing
        }
    }

    /// A small capsule label: solid tint with black text, or neutral white fill.
    public enum Badge {
        public static let type = T.TypeScale.sm
        public static let paddingX = T.Space.sm
        public static let paddingY = T.Space.hair
        public static let neutralFill = T.Fill.medium
    }

    /// An uppercase muted title over a group of rows.
    public enum SectionHeader {
        public static let type = T.TypeScale.sm
        public static let tracking: Double = 0.6
    }

    /// An "x" that dismisses a card.
    public enum DismissButton {
        public static let size = T.Size.button
        public static let type = T.TypeScale.sm
    }

    /// The music panel's backdrop: the blurred artwork under a black shade that
    /// darkens downwards, lit by the artwork's colour.
    public enum Backdrop {
        /// The artwork's opacity.
        public static let artwork: Double = 0.6
        /// The black shade at the top...
        public static let shadeTop = T.Fill.heavy
        /// ...and at the bottom.
        public static let shadeBottom: Double = 0.8
        /// The artwork colour's glow.
        public static let tint: Double = 0.45
    }

    /// Album artwork in a rounded square; without art, a note at this share of its size.
    public enum Artwork {
        public static let iconRatio: Double = 0.45
    }

    /// The key that presses a button ("esc", "↩"), beside its title: a small
    /// rounded tile in the text colour, a little dimmed.
    public enum KeyCap {
        public static let type = T.TypeScale.sm
        public static let radius = T.Radius.xs
        public static let fill = T.Fill.strong
        public static let opacity: Double = 0.8
    }

    /// A panel floating over a view (the office's world picker): near-black so
    /// the view under it barely shows.
    public enum Popover {
        public static let radius = T.Radius.lg
        public static let fill: Double = 0.92
    }

    /// Drop shadows: black at a strength, blurred by a radius, moved down by y.
    public enum Shadow {
        /// The open panel and small artwork (closed-notch music).
        public static let opacity: Double = 0.45
        public static let radius: Double = 10
        public static let y: Double = 4
        /// Large artwork (the Music panel): the same strength, softer and deeper.
        public static let largeRadius: Double = 14
        public static let largeY: Double = 6
        /// A toast (Clipboard's undo) and a dragged row (Connected accounts).
        public static let smallRadius: Double = 8
        public static let toastOpacity: Double = 0.4
        public static let toastY: Double = 3
        public static let liftedOpacity: Double = 0.5
    }

    /// The intro's light (Intro.swift): strengths of the palette's intro colours
    /// and the soft corners of its glow shapes. One animation's own values.
    public enum IntroLight {
        /// The screen dimmed behind the flight (surface at this strength).
        public static let dim: Double = 0.5
        /// The halo behind the icon: introGlow, fading into Claude's warm colour.
        public static let halo: Double = 0.4
        public static let haloWarm: Double = 0.12
        /// The light trail: violet in the middle, warm at the tail.
        public static let trailMiddle: Double = 0.85
        public static let trailWarm: Double = 0.6
        /// The glint across the icon.
        public static let glint: Double = 0.9
        /// The glow round the notch as the icon lands.
        public static let glow: Double = 0.25
        public static let trailRadius: Double = 4
        public static let glowRadius: Double = 16
        public static let sparkRadius: Double = 2
    }
}

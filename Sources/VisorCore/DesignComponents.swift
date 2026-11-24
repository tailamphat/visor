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
}

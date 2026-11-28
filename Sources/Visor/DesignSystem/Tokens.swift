import SwiftUI
import VisorCore

/// A colour drawn as a solid fill (`DesignContrast.solid`): the fill itself
/// (darkened just enough for white text where needed), its text colour and its
/// held colour, resolved from its sRGB value once per colour and kept, so a
/// button's body never converts colours again.
struct SolidFill {
    let fill: Color
    let on: Color
    let pressed: Color

    private static var cache: [Color: SolidFill] = [:]
    private static let lock = NSLock()

    static func of(_ fill: Color) -> SolidFill {
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[fill] { return known }
        // A translucent fill is taken over the black surface first.
        var hex = DesignTokens.Palette.textPrimary
        if let rgb = NSColor(fill).usingColorSpace(.sRGB) {
            let alpha = rgb.alphaComponent
            func byte(_ c: CGFloat) -> UInt32 { UInt32((min(max(c * alpha, 0), 1) * 255).rounded()) }
            hex = byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent)
        }
        let spec = DesignContrast.solid(hex)
        let solid = SolidFill(fill: Color(hex: spec.fill), on: Color(hex: spec.on), pressed: Color(hex: DesignContrast.pressed(spec)))
        cache[fill] = solid
        return solid
    }
}

extension Color {
    /// This colour as a solid button or badge fill: darkened just enough for
    /// white text where it needs it, else as it is.
    var solidFill: Color { SolidFill.of(self).fill }
    /// The text and icon colour on `solidFill`: white, or black on a light fill.
    var onColour: Color { SolidFill.of(self).on }
    /// `solidFill` while its button is held: moved away from its text colour.
    var pressedFill: Color { SolidFill.of(self).pressed }
}

/// The design tokens as SwiftUI values. Values live in VisorCore's
/// `DesignTokens` (tested, and read by the website generator); this file only
/// converts them. `Theme` stays the entry point for colours.
///
/// Use: `.font(DS.font(.sm, .semibold))`, `RoundedRectangle(cornerRadius: DS.Radius.md)`,
/// `.fill(DS.Fill.subtle)`, `.padding(DS.Space.sm)`, `.frame(height: DS.Size.button)`.
enum DS {
    /// A step of `DesignScale.typeScale`, looked up by name once, so a step
    /// renamed or dropped in VisorCore stops a debug build the first time a font is made.
    enum TypeStep: String, CaseIterable {
        case xs, sm, base, md, lg, xl, display

        private static let table: [TypeStep: CGFloat] = {
            var table: [TypeStep: CGFloat] = [:]
            for step in DesignScale.typeScale {
                if let key = TypeStep(rawValue: step.name) { table[key] = CGFloat(step.value) }
            }
            assert(table.count == allCases.count && DesignScale.typeScale.count == allCases.count,
                   "DS.TypeStep and DesignScale.typeScale disagree")
            return table
        }()

        var points: CGFloat { Self.table[self] ?? CGFloat(DesignTokens.TypeScale.base) }
    }

    /// A system font on the type scale. Weights: regular, medium, semibold, bold
    /// (light only with display).
    static func font(_ step: TypeStep, _ weight: Font.Weight = .regular,
                     design: Font.Design = .default) -> Font {
        .system(size: step.points, weight: weight, design: design)
    }

    enum Radius {
        static let xs = CGFloat(DesignTokens.Radius.xs)
        static let sm = CGFloat(DesignTokens.Radius.sm)
        static let md = CGFloat(DesignTokens.Radius.md)
        static let lg = CGFloat(DesignTokens.Radius.lg)
    }

    /// White over black at the scale's strengths; `DS.Fill.Opacity` for tints.
    enum Fill {
        static let faint = Color.white.opacity(DesignTokens.Fill.faint)
        static let subtle = Color.white.opacity(DesignTokens.Fill.subtle)
        static let medium = Color.white.opacity(DesignTokens.Fill.medium)
        static let strong = Color.white.opacity(DesignTokens.Fill.strong)
        static let heavy = Color.white.opacity(DesignTokens.Fill.heavy)

        /// White at a strength a component names (`PluginPieces.trackFill`), for
        /// measurements a test already holds to the fill scale.
        static func white(_ strength: Double) -> Color { Color.white.opacity(strength) }

        /// The same strengths as numbers, for tinted fills (`Theme.stuck.opacity(DS.Fill.Opacity.subtle)`).
        enum Opacity {
            static let faint = DesignTokens.Fill.faint
            static let subtle = DesignTokens.Fill.subtle
            static let medium = DesignTokens.Fill.medium
            static let strong = DesignTokens.Fill.strong
            static let heavy = DesignTokens.Fill.heavy
        }
    }

    enum Space {
        static let none = CGFloat(DesignTokens.Space.none)
        static let hair = CGFloat(DesignTokens.Space.hair)
        static let xxs = CGFloat(DesignTokens.Space.xxs)
        static let xs = CGFloat(DesignTokens.Space.xs)
        static let sm = CGFloat(DesignTokens.Space.sm)
        static let md = CGFloat(DesignTokens.Space.md)
        static let lg = CGFloat(DesignTokens.Space.lg)
        static let xl = CGFloat(DesignTokens.Space.xl)
        static let xxl = CGFloat(DesignTokens.Space.xxl)
        static let xxxl = CGFloat(DesignTokens.Space.xxxl)
    }

    enum Size {
        static let bar = CGFloat(DesignTokens.Size.bar)
        static let cardInset = CGFloat(DesignTokens.Size.cardInset)
        static let button = CGFloat(DesignTokens.Size.button)
        static let iconLarge = CGFloat(DesignTokens.Size.iconLarge)
    }

    /// Palette colours that `Theme` doesn't name (approval buttons, the intro's light, a local build's blueprint).
    enum Palette {
        static let mint = Color(hex: DesignTokens.Palette.mint)
        static let rose = Color(hex: DesignTokens.Palette.rose)
        static let allowText = Color(hex: DesignTokens.Palette.allowText)
        static let alwaysText = Color(hex: DesignTokens.Palette.alwaysText)
        static let denyText = Color(hex: DesignTokens.Palette.denyText)
        static let introGlow = Color(hex: DesignTokens.Palette.introGlow)
        static let introSky = Color(hex: DesignTokens.Palette.introSky)
        static let introSpark = Color(hex: DesignTokens.Palette.introSpark)
        static let violet = Color(hex: DesignTokens.Palette.violet)
        /// A local build's grid and pen line (`DesignComponents.Blueprint`).
        static let blueprint = Color(hex: DesignTokens.Palette.blueprint)
    }

    /// Drop shadows (`DesignComponents.Shadow`); draw one with `.dsShadow(_:shown:)`.
    struct Shadow {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat

        private typealias S = DesignComponents.Shadow
        /// The open panel, and small artwork.
        static let panel = Shadow(opacity: S.opacity, radius: CGFloat(S.radius), y: CGFloat(S.y))
        /// Large artwork.
        static let artwork = Shadow(opacity: S.opacity, radius: CGFloat(S.largeRadius), y: CGFloat(S.largeY))
        /// A toast over a list.
        static let toast = Shadow(opacity: S.toastOpacity, radius: CGFloat(S.smallRadius), y: CGFloat(S.toastY))
        /// A row lifted while dragged.
        static let lifted = Shadow(opacity: S.liftedOpacity, radius: CGFloat(S.smallRadius), y: CGFloat(S.y))
    }
}

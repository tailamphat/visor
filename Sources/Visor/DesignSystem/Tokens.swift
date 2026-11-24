import SwiftUI
import VisorCore

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

    /// Palette colours that `Theme` doesn't name (approval buttons).
    enum Palette {
        static let mint = Color(hex: DesignTokens.Palette.mint)
        static let rose = Color(hex: DesignTokens.Palette.rose)
        static let allowText = Color(hex: DesignTokens.Palette.allowText)
        static let alwaysText = Color(hex: DesignTokens.Palette.alwaysText)
        static let denyText = Color(hex: DesignTokens.Palette.denyText)
    }
}

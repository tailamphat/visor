import Foundation

/// Visor's design values: every colour, type size, radius, fill strength,
/// spacing and fixed size the app draws with. The app wraps them as SwiftUI
/// values in `Sources/Visor/DesignSystem/Tokens.swift`; `Theme` reads its
/// colours from here.
///
/// Keep one value per line, `public static let name: Type = literal`, inside
/// `public enum Group {`: the website's token generator reads this file as text.
/// Add every new value to `DesignScale.all` too (a test checks they agree).
public enum DesignTokens {
    /// sRGB hex colours. The notch is pure black, so these are tuned for black.
    public enum Palette {
        public static let surface: UInt32 = 0x000000
        public static let raised: UInt32 = 0x1A1A19
        public static let textPrimary: UInt32 = 0xFFFFFF
        public static let textSecondary: UInt32 = 0xC3C2B7
        public static let textMuted: UInt32 = 0x8A8980
        public static let accent: UInt32 = 0x3987E5
        /// Drawn at 45% opacity behind accent meters.
        public static let accentTrack: UInt32 = 0x184F95
        public static let deemphasis: UInt32 = 0x4A4A46
        public static let claude: UInt32 = 0xD97757
        public static let good: UInt32 = 0x0CA30C
        /// "On pace": the good green, light enough for small text on black.
        public static let onPace: UInt32 = 0x5FC95F
        /// Two agents on the same file: orange, never an approval's amber.
        public static let clash: UInt32 = 0xFF8A3D
        public static let warning: UInt32 = 0xFAB219
        /// An agent asking you something: blue, apart from an approval's amber.
        public static let question: UInt32 = 0x5AA2F0
        public static let critical: UInt32 = 0xD03B3B
        /// Stuck warnings: coral, apart from amber, the clash orange and the question blue.
        public static let stuck: UInt32 = 0xFF6B6B
        /// Approval buttons: Allow fill and Always tint.
        public static let mint: UInt32 = 0x7EE0A0
        /// Approval buttons: Deny tint.
        public static let rose: UInt32 = 0xFF8F86
        public static let allowText: UInt32 = 0x06260F
        public static let alwaysText: UInt32 = 0xC9F3D6
        public static let denyText: UInt32 = 0xFF9D95
    }

    /// Text sizes in points. Weights: regular, medium, semibold, bold (light only with display).
    public enum TypeScale {
        public static let xs: Double = 9
        public static let sm: Double = 10
        public static let base: Double = 11
        public static let md: Double = 12
        public static let lg: Double = 13
        public static let xl: Double = 15
        public static let display: Double = 26
    }

    /// Corner radii in points (continuous corners).
    public enum Radius {
        public static let xs: Double = 3
        public static let sm: Double = 5
        public static let md: Double = 9
        public static let lg: Double = 12
    }

    /// White fill strengths (opacity over black) for cards, tiles, buttons and strokes.
    public enum Fill {
        public static let faint: Double = 0.05
        public static let subtle: Double = 0.08
        public static let medium: Double = 0.12
        public static let strong: Double = 0.16
        public static let heavy: Double = 0.25
    }

    /// Padding and stack spacing in points: a 2 pt grid.
    public enum Space {
        public static let none: Double = 0
        public static let hair: Double = 1
        public static let xxs: Double = 2
        public static let xs: Double = 4
        public static let sm: Double = 6
        public static let md: Double = 8
        public static let lg: Double = 10
        public static let xl: Double = 12
        public static let xxl: Double = 16
        public static let xxxl: Double = 20
    }

    /// Fixed sizes in points.
    public enum Size {
        /// Every progress bar and meter.
        public static let bar: Double = 4
        /// Padding inside a banner card, the same on all four sides.
        public static let cardInset: Double = 10
        /// Height of a small button in a card.
        public static let button: Double = 18
        /// SF Symbol icons in empty states (not text: not on the type scale).
        public static let iconLarge: Double = 20
    }
}

/// The scales as tables, and the rule that moves an old literal onto them.
public enum DesignScale {
    public struct Step: Equatable, Sendable {
        public let name: String
        public let value: Double
        public init(_ name: String, _ value: Double) { self.name = name; self.value = value }
    }

    public struct Entry: Equatable, Sendable {
        public let group: String
        public let name: String
        public let value: Double
    }

    private typealias T = DesignTokens

    public static let typeScale: [Step] = [
        Step("xs", T.TypeScale.xs), Step("sm", T.TypeScale.sm), Step("base", T.TypeScale.base),
        Step("md", T.TypeScale.md), Step("lg", T.TypeScale.lg), Step("xl", T.TypeScale.xl),
        Step("display", T.TypeScale.display),
    ]
    public static let radius: [Step] = [
        Step("xs", T.Radius.xs), Step("sm", T.Radius.sm), Step("md", T.Radius.md), Step("lg", T.Radius.lg),
    ]
    public static let fill: [Step] = [
        Step("faint", T.Fill.faint), Step("subtle", T.Fill.subtle), Step("medium", T.Fill.medium),
        Step("strong", T.Fill.strong), Step("heavy", T.Fill.heavy),
    ]
    public static let space: [Step] = [
        Step("none", T.Space.none), Step("hair", T.Space.hair), Step("xxs", T.Space.xxs), Step("xs", T.Space.xs),
        Step("sm", T.Space.sm), Step("md", T.Space.md), Step("lg", T.Space.lg), Step("xl", T.Space.xl),
        Step("xxl", T.Space.xxl), Step("xxxl", T.Space.xxxl),
    ]
    public static let size: [Step] = [
        Step("bar", T.Size.bar), Step("cardInset", T.Size.cardInset), Step("button", T.Size.button),
        Step("iconLarge", T.Size.iconLarge),
    ]
    public static let palette: [Step] = {
        let p = T.Palette.self
        let colours: [(String, UInt32)] = [
            ("surface", p.surface), ("raised", p.raised), ("textPrimary", p.textPrimary),
            ("textSecondary", p.textSecondary), ("textMuted", p.textMuted), ("accent", p.accent),
            ("accentTrack", p.accentTrack), ("deemphasis", p.deemphasis), ("claude", p.claude),
            ("good", p.good), ("onPace", p.onPace), ("clash", p.clash), ("warning", p.warning),
            ("question", p.question), ("critical", p.critical), ("stuck", p.stuck), ("mint", p.mint),
            ("rose", p.rose), ("allowText", p.allowText), ("alwaysText", p.alwaysText), ("denyText", p.denyText),
        ]
        return colours.map { Step($0.0, Double($0.1)) }
    }()

    /// Every token, grouped as in `DesignTokens` (colours as their hex value).
    public static let all: [Entry] = {
        let groups: [(String, [Step])] = [
            ("Palette", palette), ("TypeScale", typeScale), ("Radius", radius),
            ("Fill", fill), ("Space", space), ("Size", size),
        ]
        return groups.flatMap { group in group.1.map { Entry(group: group.0, name: $0.name, value: $0.value) } }
    }()

    /// The step nearest `value`; a tie goes to the smaller step, so nothing grows
    /// inside a fixed-height row. Values past either end clamp to that end.
    /// Distances are compared with a small tolerance so decimal ties (0.1 between
    /// 0.08 and 0.12) count as ties.
    public static func snap(_ value: Double, to steps: [Step]) -> Step {
        precondition(!steps.isEmpty, "snap needs a scale")
        var best = steps[0]
        var bestDistance = abs(value - best.value)
        for step in steps.dropFirst() {
            let distance = abs(value - step.value)
            if distance < bestDistance - 1e-9 {
                best = step
                bestDistance = distance
            }
        }
        return best
    }
}

import Foundation

/// The contrast contract: every text and icon colour drawn on a fill reads at
/// WCAG 2's minimum ratio. A solid fill (a primary button, a solid badge) takes
/// white text, the fill darkened just enough to reach 4.5:1; black text only on
/// the light fills (`blackTextFills`) and where white would need the fill more
/// than `maxDarkening` darker (it would read as another colour, orange as brown).
/// The shared components draw with `solid(_:)`, so no view and no plugin can
/// put white text on a light tint.
///
/// `fills` is the pairing table; `pairs` lists every text-on-fill pair the shared
/// components can produce, and a test fails on any pair under its minimum.
public enum DesignContrast {
    private typealias P = DesignTokens.Palette
    private typealias T = DesignTokens

    /// What is drawn on the fill, and the ratio it needs.
    public enum Use: Sendable, Equatable {
        /// Text below `TypeScale.xl`: 4.5:1.
        case text
        /// Text at `TypeScale.xl` and up: 3:1.
        case largeText
        /// Icons and UI marks (a banner's symbol, the dismiss x, a meter's fill): 3:1.
        case icon

        public var minimum: Double { self == .text ? 4.5 : 3 }
    }

    /// Text at the scale's large steps (xl and up) counts as large.
    public static func use(forType points: Double) -> Use {
        points >= T.TypeScale.xl ? .largeText : .text
    }

    // MARK: - WCAG 2

    private static func channel(_ value: UInt32) -> Double {
        let c = Double(value & 0xFF) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Relative luminance of an sRGB colour, 0 (black) to 1 (white).
    public static func luminance(_ hex: UInt32) -> Double {
        0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    /// Contrast ratio of two colours, 1 to 21, in either order.
    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `tint` at `opacity` over `ground`, rounded to sRGB bytes.
    public static func composite(_ tint: UInt32, opacity: Double, over ground: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let t = Double((tint >> shift) & 0xFF), g = Double((ground >> shift) & 0xFF)
            out |= UInt32((t * opacity + g * (1 - opacity)).rounded()) << shift
        }
        return out
    }

    // MARK: - The pairing table

    /// The light fills: always black text, never darkened (amber, the cup's
    /// yellow, mint, the light green, and the stuck coral, which darkened would
    /// read as critical's red).
    public static let blackTextFills: Set<UInt32> = [P.warning, P.awake, P.mint, P.onPace, P.stuck]
    /// The most a fill is darkened for white text; past it, black text. The
    /// blues, violet, reds and greens of the palette need at most 25.5%; the
    /// oranges and the rose need 30% or more and would read as brown.
    public static let maxDarkening = 0.27
    /// Darkening steps of 0.5%.
    public static let darkeningStep = 0.005

    /// How a colour is drawn as a solid fill: the fill (darkened `darkened`
    /// toward black when white text needs it) and the text colour on it.
    public struct Solid: Sendable, Equatable {
        public let fill: UInt32
        public let on: UInt32
        public let darkened: Double
    }

    /// White text where the fill can carry it (darkened by the smallest step
    /// that reaches 4.5:1, at most 25%), else black text on the fill as it is.
    public static func solid(_ hex: UInt32) -> Solid {
        let black = Solid(fill: hex, on: P.surface, darkened: 0)
        if blackTextFills.contains(hex) { return black }
        var step = 0
        while Double(step) * darkeningStep <= maxDarkening + 1e-9 {
            let amount = Double(step) * darkeningStep
            let fill = step == 0 ? hex : composite(P.surface, opacity: amount, over: hex)
            if ratio(P.textPrimary, fill) >= Use.text.minimum { return Solid(fill: fill, on: P.textPrimary, darkened: amount) }
            step += 1
        }
        return black
    }

    /// The text and icon colour on `fill` drawn as a solid (`solid(fill).on`).
    public static func on(_ fill: UInt32) -> UInt32 { solid(fill).on }

    public struct Fill: Sendable {
        public let name: String
        public let hex: UInt32
        public var on: UInt32 { DesignContrast.solid(hex).on }
        /// The fill as drawn solid (darkened for white text where needed).
        public var solid: UInt32 { DesignContrast.solid(hex).fill }
    }

    /// Every colour the design system offers as a solid fill, and so every
    /// colour a component or a plugin can put text on.
    public static let fills: [Fill] = [
        Fill(name: "surface", hex: P.surface), Fill(name: "raised", hex: P.raised),
        Fill(name: "deemphasis", hex: P.deemphasis), Fill(name: "accentTrack", hex: P.accentTrack),
        Fill(name: "accent", hex: P.accent), Fill(name: "warning", hex: P.warning), Fill(name: "awake", hex: P.awake),
        Fill(name: "good", hex: P.good), Fill(name: "clash", hex: P.clash), Fill(name: "question", hex: P.question),
        Fill(name: "critical", hex: P.critical), Fill(name: "stuck", hex: P.stuck), Fill(name: "claude", hex: P.claude),
        Fill(name: "localBuild", hex: P.localBuild), Fill(name: "onPace", hex: P.onPace), Fill(name: "violet", hex: P.violet),
        Fill(name: "mint", hex: P.mint), Fill(name: "rose", hex: P.rose),
        Fill(name: "textPrimary", hex: P.textPrimary), Fill(name: "textSecondary", hex: P.textSecondary),
        Fill(name: "textMuted", hex: P.textMuted),
    ]

    /// The tints a component fills solidly (CardButton primary, Badge solid, PillButton).
    static let solidTints: [Fill] = fills.filter {
        !["surface", "raised", "deemphasis", "accentTrack"].contains($0.name)
    }

    /// A held button's fill: the solid fill moved away from its text by
    /// `1 - CardButton.pressedOpacity` (lighter under black text, darker under
    /// white), so holding it never lowers the text's contrast.
    public static func pressed(_ solid: Solid) -> UInt32 {
        let away = solid.on == P.surface ? P.textPrimary : P.surface
        return composite(away, opacity: 1 - DesignComponents.CardButton.pressedOpacity, over: solid.fill)
    }

    /// `Theme.accentTrack`: the accent track colour at this strength, behind Usage meters.
    public static let accentTrackOpacity: Double = 0.45

    /// The tracks meters fill: Usage's accent track, and plugin meters' white track.
    public static let meterTracks: [(name: String, hex: UInt32)] = [
        ("accentTrack", composite(P.accentTrack, opacity: accentTrackOpacity, over: P.surface)),
        ("plugin track", composite(P.textPrimary, opacity: PluginPieces.trackFill, over: P.surface)),
    ]

    // MARK: - Plugin accents

    /// The grounds a plugin's colours sit on: the black notch, and the inside of
    /// a banner in each tint a plugin can pick (its own accent included).
    public static func pluginGrounds(accent: UInt32) -> [UInt32] {
        let tints = PluginColor.allCases.map(\.hex) + [accent]
        return [P.surface] + tints.map { composite($0, opacity: DesignComponents.Banner.fill, over: P.surface) }
    }

    /// A plugin's manifest accent, made readable once at load: mixed toward white
    /// in 5% steps until it reads as text (4.5:1) on the notch and inside every
    /// banner. An accent that already reads is returned unchanged.
    public static func readableAccent(_ hex: UInt32) -> UInt32 {
        func reads(_ colour: UInt32) -> Bool {
            pluginGrounds(accent: colour).allSatisfy { ratio(colour, $0) >= Use.text.minimum }
        }
        var colour = hex
        var step = 0
        while !reads(colour) && step < 20 {
            step += 1
            colour = composite(P.textPrimary, opacity: Double(step) * 0.05, over: hex)
        }
        return colour
    }

    // MARK: - Every pair the components produce

    public struct Pair: Sendable {
        public let name: String
        public let foreground: UInt32
        public let background: UInt32
        public let use: Use
        public var ratio: Double { DesignContrast.ratio(foreground, background) }
        public var passes: Bool { ratio >= use.minimum }
    }

    /// Every text and icon the shared components (and visor.ui, which draws with
    /// them) can put on a fill.
    public static let pairs: [Pair] = {
        typealias D = DesignComponents
        var out: [Pair] = []
        func add(_ name: String, _ fg: UInt32, _ bg: UInt32, _ use: Use) {
            out.append(Pair(name: name, foreground: fg, background: bg, use: use))
        }
        let white = P.textPrimary
        let pluginTints = PluginColor.allCases.map { (name: $0.rawValue, hex: $0.hex) }

        // Solid fills: the main button, the solid badge, the pill button.
        for tint in solidTints {
            let s = solid(tint.hex)
            add("CardButton.primary on \(tint.name)", s.on, s.fill, use(forType: D.CardButton.type))
            add("CardButton.primary held on \(tint.name)", s.on, pressed(s), use(forType: D.CardButton.type))
            add("PillButton held on \(tint.name)", s.on, pressed(s), use(forType: T.TypeScale.md))
            add("Badge.solid on \(tint.name)", s.on, s.fill, use(forType: D.Badge.type))
        }
        add("PillButton on accent", solid(P.accent).on, solid(P.accent).fill, use(forType: T.TypeScale.md))

        // Banners: the tint faintly over black, in every tint a view or plugin picks.
        var bannerTints: [(name: String, hex: UInt32)] = solidTints.map { ($0.name, $0.hex) }
        for tint in pluginTints where !bannerTints.contains(where: { $0.hex == tint.hex }) { bannerTints.append(tint) }
        for tint in bannerTints {
            let ground = composite(tint.hex, opacity: D.Banner.fill, over: P.surface)
            for kind in ["bannerCard", "compactBanner"] {
                add("\(kind) \(tint.name): title textPrimary", P.textPrimary, ground, use(forType: T.TypeScale.base))
                add("\(kind) \(tint.name): body textSecondary", P.textSecondary, ground, use(forType: T.TypeScale.base))
                add("\(kind) \(tint.name): muted textMuted", P.textMuted, ground, use(forType: T.TypeScale.sm))
                // Music's hints write their action in the tint at base size: text, not just an icon.
                add("\(kind) \(tint.name): text and icon in the tint", tint.hex, ground, use(forType: T.TypeScale.base))
            }
            add("bannerCard \(tint.name): DismissButton", P.textMuted, ground, .icon)
            let secondary = composite(white, opacity: D.CardButton.secondaryFill, over: ground)
            add("bannerCard \(tint.name): CardButton.secondary", P.textPrimary, secondary, use(forType: D.CardButton.type))
            // Held, the whole secondary button (text too) dims to pressedOpacity.
            add("bannerCard \(tint.name): CardButton.secondary held",
                composite(P.textPrimary, opacity: D.CardButton.pressedOpacity, over: ground),
                composite(secondary, opacity: D.CardButton.pressedOpacity, over: ground), use(forType: D.CardButton.type))
            let neutral = composite(white, opacity: D.Badge.neutralFill, over: ground)
            add("bannerCard \(tint.name): Badge.neutral", P.textPrimary, neutral, use(forType: D.Badge.type))
        }

        // A plugin's text colours inside a banner of each plugin tint.
        for tint in pluginTints {
            let ground = composite(tint.hex, opacity: D.Banner.fill, over: P.surface)
            for colour in pluginTints {
                add("plugin text \(colour.name) in a \(tint.name) banner", colour.hex, ground, .text)
            }
        }

        // Approval buttons.
        add("ConsentButton.allow", P.allowText, P.mint, use(forType: T.TypeScale.md))
        add("ConsentButton.always", P.alwaysText, composite(P.mint, opacity: T.Fill.medium, over: P.surface), use(forType: T.TypeScale.md))
        add("ConsentButton.deny", P.denyText, composite(P.rose, opacity: T.Fill.medium, over: P.surface), use(forType: T.TypeScale.md))

        // Text on the panel and on raised cards.
        for (ground, name) in [(P.surface, "surface"), (P.raised, "raised")] {
            add("textPrimary on \(name)", P.textPrimary, ground, .text)
            add("textSecondary on \(name)", P.textSecondary, ground, .text)
            add("textMuted on \(name)", P.textMuted, ground, .text)
            add("SectionHeader on \(name)", P.textMuted, ground, use(forType: D.SectionHeader.type))
            add("Badge.neutral on \(name)", P.textPrimary, composite(white, opacity: D.Badge.neutralFill, over: ground), use(forType: D.Badge.type))
            add("DismissButton on \(name)", P.textMuted, ground, .icon)
        }

        // Meter labels and status text on the panel; status text on raised cards.
        for colour in pluginTints { add("meter label \(colour.name) on surface", colour.hex, P.surface, .text) }
        for (name, hex) in [("onPace", P.onPace), ("warning", P.warning), ("question", P.question)] {
            add("status text \(name) on raised", hex, P.raised, .text)
        }
        // Meter fills against their tracks (Usage's LimitMeter, plugin meters).
        for track in meterTracks {
            for (name, hex) in [("accent", P.accent), ("warning", P.warning), ("critical", P.critical), ("good", P.good), ("onPace", P.onPace)] {
                add("meter fill \(name) on the \(track.name)", hex, track.hex, .icon)
            }
        }
        return out
    }()
}

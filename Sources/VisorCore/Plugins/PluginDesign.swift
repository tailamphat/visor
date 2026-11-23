import Foundation

/// The design system as plugins see it: palette colours, type steps and
/// weights by name, never hex, points or pixels. Unknown names give nil, and
/// the piece keeps its default look.

/// A palette colour a plugin may pick (`color =`, `tint =`). Text and status
/// colours only: the approval buttons' colours mean "approve" in Visor, and
/// surfaces are Visor's own. Raw values are `DesignTokens.Palette` names.
public enum PluginColor: String, CaseIterable, Sendable {
    /// The plugin's own accent from plugin.json, else Visor's.
    case accent
    case good, warning, critical, question, stuck, clash, claude, onPace
    case textPrimary, textSecondary, textMuted

    /// Case-insensitive; anything but a known name is nil.
    public init?(name: Any?) {
        guard let text = name as? String else { return nil }
        let key = text.lowercased()
        guard let found = Self.allCases.first(where: { $0.rawValue.lowercased() == key }) else { return nil }
        self = found
    }

    /// The palette value (`accent` is Visor's; the app swaps in the plugin's).
    public var hex: UInt32 {
        let p = DesignTokens.Palette.self
        switch self {
        case .accent: return p.accent
        case .good: return p.good
        case .warning: return p.warning
        case .critical: return p.critical
        case .question: return p.question
        case .stuck: return p.stuck
        case .clash: return p.clash
        case .claude: return p.claude
        case .onPace: return p.onPace
        case .textPrimary: return p.textPrimary
        case .textSecondary: return p.textSecondary
        case .textMuted: return p.textMuted
        }
    }
}

/// A step of `DesignScale.typeScale`, by name (`size =`).
public enum PluginTypeStep: String, CaseIterable, Sendable {
    case xs, sm, base, md, lg, xl, display

    public init?(name: Any?) {
        guard let text = name as? String, let step = Self(rawValue: text.lowercased()) else { return nil }
        self = step
    }

    public var points: Double {
        DesignScale.typeScale.first { $0.name == rawValue }?.value ?? DesignTokens.TypeScale.base
    }
}

/// The design system's weights (`weight =`).
public enum PluginWeight: String, CaseIterable, Sendable {
    case regular, medium, semibold, bold

    public init?(name: Any?) {
        guard let text = name as? String, let weight = Self(rawValue: text.lowercased()) else { return nil }
        self = weight
    }
}

/// `ui.banner`: the shared tinted card, with an optional badge, title, text,
/// dismiss action and pieces inside.
public struct PluginBanner: Equatable, Sendable {
    /// nil: the plugin's accent.
    public var tint: PluginColor?
    public var badge: String?
    public var title: String
    public var text: String
    /// The handler the "x" calls; nil: no "x".
    public var dismiss: String?
    public var children: [PluginNode]

    public init(tint: PluginColor?, badge: String?, title: String, text: String, dismiss: String?, children: [PluginNode]) {
        self.tint = tint
        self.badge = badge
        self.title = title
        self.text = text
        self.dismiss = dismiss
        self.children = children
    }
}

/// The plugin pieces' fixed measurements, from `DesignTokens`; the app draws
/// with these. `scale` nil marks a piece's own constant (a test checks the rest).
public enum PluginPieces {
    private typealias T = DesignTokens

    public typealias Measurement = DesignComponents.Measurement

    /// Every measurement below.
    public static let measurements: [Measurement] = [
        Measurement(name: "blockGap", value: blockGap, scale: DesignScale.space),
        Measurement(name: "stackGap", value: stackGap, scale: DesignScale.space),
        Measurement(name: "columnsGap", value: columnsGap, scale: DesignScale.space),
        Measurement(name: "statsGap", value: statsGap, scale: DesignScale.space),
        Measurement(name: "rowRadius", value: rowRadius, scale: DesignScale.radius),
        Measurement(name: "rowPadding", value: rowPadding, scale: DesignScale.space),
        Measurement(name: "barRadius", value: barRadius, scale: DesignScale.radius),
        Measurement(name: "trackFill", value: trackFill, scale: DesignScale.fill),
        Measurement(name: "hoverFill", value: hoverFill, scale: DesignScale.fill),
        Measurement(name: "pickerFill", value: pickerFill, scale: DesignScale.fill),
        Measurement(name: "pickerOnFill", value: pickerOnFill, scale: DesignScale.fill),
        Measurement(name: "rowHeight", value: rowHeight, scale: nil),
        Measurement(name: "headerHeight", value: headerHeight, scale: nil),
        Measurement(name: "barsHeight", value: barsHeight, scale: nil),
        Measurement(name: "dot", value: dot, scale: nil),
        Measurement(name: "toggleWidth", value: toggleWidth, scale: nil),
        Measurement(name: "toggleHeight", value: toggleHeight, scale: nil),
        Measurement(name: "footer", value: footer, scale: nil),
        Measurement(name: "barOpacity", value: barOpacity, scale: nil),
        Measurement(name: "placeholderLine", value: placeholderLine, scale: nil),
    ]

    /// Between plugins in the tab.
    public static let blockGap = T.Space.xxl
    public static let stackGap = T.Space.lg
    public static let columnsGap = T.Space.xxl
    public static let statsGap = T.Space.xxxl
    /// List rows, picker segments and placeholders.
    public static let rowRadius = T.Radius.sm
    public static let rowPadding = T.Space.sm
    public static let barRadius = T.Radius.xs
    /// Empty meter tracks, empty bars, placeholders and chips.
    public static let trackFill = T.Fill.subtle
    public static let hoverFill = T.Fill.faint
    public static let pickerFill = T.Fill.faint
    public static let pickerOnFill = T.Fill.strong
    /// A list row, as in `visor.panel`.
    public static let rowHeight: Double = 24
    /// The plugin's name row.
    public static let headerHeight: Double = 22
    public static let barsHeight: Double = 44
    /// A row's status dot.
    public static let dot: Double = 7
    public static let toggleWidth: Double = 28
    public static let toggleHeight: Double = 16
    /// The tab's footer links.
    public static let footer: Double = 26
    /// A filled bar in `ui.bars`: its colour, a little softened.
    public static let barOpacity = 0.85
    /// A grey line before a plugin's first view.
    public static let placeholderLine: Double = 8
}

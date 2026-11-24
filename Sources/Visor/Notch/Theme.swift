import SwiftUI
import VisorCore

/// Colours for the notch: the entry point views use. Values come from the design
/// tokens (`DesignTokens.Palette`, see `DesignSystem/Tokens.swift`). The surface is
/// pure black so the panel melts into the hardware notch.
enum Theme {
    private typealias P = DesignTokens.Palette
    /// Every progress bar and meter in the app: Usage, Agents' context, Tokens, Music, plugins.
    static let barHeight = DS.Size.bar
    /// Padding inside a banner card (Stuck, handoff), the same on all four sides.
    static let cardInset = DS.Size.cardInset
    static let surface = Color(hex: P.surface)
    static let raised = Color(hex: P.raised)
    static let textPrimary = Color(hex: P.textPrimary)
    static let textSecondary = Color(hex: P.textSecondary)
    static let textMuted = Color(hex: P.textMuted)

    static let accent = Color(hex: P.accent)
    static let accentTrack = Color(hex: P.accentTrack).opacity(0.45)
    static let deemphasis = Color(hex: P.deemphasis)
    static let claude = Color(hex: P.claude)

    static let good = Color(hex: P.good)
    /// "On pace": the good green, light enough for small text on black.
    static let onPace = Color(hex: P.onPace)
    /// Two agents on the same file: orange, so it never reads as an approval's amber.
    static let clash = Color(hex: P.clash)
    static let warning = Color(hex: P.warning)
    /// An agent asking you something: blue, apart from an approval's amber.
    static let question = Color(hex: P.question)
    static let critical = Color(hex: P.critical)
    /// Stuck warnings: coral, apart from the approval amber, the clash orange and the question blue.
    static let stuck = Color(hex: P.stuck)
    /// The keep-awake cup: its own amber, so the closed notch shows approval amber only for an approval.
    static let awake = Color(hex: P.awake)

    static let spring = Animation.spring(response: 0.28, dampingFraction: 0.86)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The notch outline: flares out into the menu bar at the top corners and is
/// rounded at the bottom, like the hardware notch.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let b = min(bottom, (w - 2 * top) / 2, h - top)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: top, y: top), control: CGPoint(x: top, y: 0))
        p.addLine(to: CGPoint(x: top, y: h - b))
        p.addQuadCurve(to: CGPoint(x: top + b, y: h), control: CGPoint(x: top, y: h))
        p.addLine(to: CGPoint(x: w - top - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - top, y: h - b), control: CGPoint(x: w - top, y: h))
        p.addLine(to: CGPoint(x: w - top, y: top))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - top, y: 0))
        p.closeSubpath()
        return p
    }
}

/// What each agent looks like: its mark and colour.
enum AgentStyle {
    /// Bright, for marks on black.
    static func mark(_ agent: String) -> NSColor {
        switch agent {
        case "Copilot CLI": return NSColor(hex: 0xA78BFA)
        case "Antigravity": return NSColor(hex: 0x3186FF)
        case "OpenCode": return NSColor(hex: 0xEDEDED)
        case "Codex CLI": return NSColor(hex: 0x10A37F)
        case "Gemini CLI": return NSColor(hex: 0xE879F9)
        default: return NSColor(hex: 0xD97757)
        }
    }
    /// The agent's name on the approval card: a light tint of its brand colour.
    static func name(_ agent: String) -> Color {
        agent == "Copilot CLI" ? Color(hex: 0xC4B0FF) : Color(hex: 0xF0A58A)
    }
    /// The tile behind the mark in lists.
    static let tile = Color.white.opacity(0.08)
}

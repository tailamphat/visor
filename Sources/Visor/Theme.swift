import SwiftUI

/// Colours for the notch. The surface is pure black so the panel melts into the
/// hardware notch; chart colours come from the data-viz palette's dark steps.
enum Theme {
    static let surface = Color.black
    static let raised = Color(hex: 0x1A1A19)
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0xC3C2B7)
    static let textMuted = Color(hex: 0x8A8980)

    static let accent = Color(hex: 0x3987E5)
    static let accentTrack = Color(hex: 0x184F95).opacity(0.45)
    static let deemphasis = Color(hex: 0x4A4A46)
    static let claude = Color(hex: 0xD97757)

    static let good = Color(hex: 0x0CA30C)
    static let warning = Color(hex: 0xFAB219)
    /// An agent asking you something: blue, apart from an approval's amber.
    static let question = Color(hex: 0x5AA2F0)
    static let serious = Color(hex: 0xEC835A)
    static let critical = Color(hex: 0xD03B3B)

    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.82)
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

import AppKit
import VisorCore

/// The film worlds' characters in soft clay, as in the mockup: drawn on a 14 x 22
/// room-pixel canvas at 4x detail, then shown in the usual sprite's place. Every
/// pose the office uses works: sitting (the legs drop out of view), facing away
/// (the back of the head), blinking, typing, reading and waving.
enum FilmCast {
    static let width = 14.0
    static let height = 22.0

    struct Pose {
        var front: Bool
        var sits: Bool
        var blink: Bool
        /// Typing and waving alternate between two frames.
        var frame: Int
        var typing: Bool
        var waving: Bool
        var reading: Bool
        /// A fan of playing cards in hand, at the starship's poker table.
        var cards = false
    }

    static func image(_ figure: PixelPerson.Figure, _ pose: Pose) -> CGImage? {
        guard let p = Pixels(width: Int(width), height: Int(height), scale: 4) else { return nil }
        // Sitting: everything 3.5 room pixels lower, so the legs fall below the canvas.
        let c = Clay(p: p, x: 7, y: height - 0.5 + (pose.sits ? 3.5 : 0), pose: pose)
        c.draw(figure)
        return p.image
    }
}

/// The drawing kit for one character, with feet at (x, y).
private struct Clay {
    let p: Pixels
    let x: Double
    let y: Double
    let pose: FilmCast.Pose

    // MARK: Primitives

    func clay(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double, _ top: UInt32, _ bottom: UInt32, hl: Double = 0.2) {
        p.clay(x, y, w, h, radius: max(0, min(r, w / 2, h / 2)), top: top, bottom: bottom)
        if hl > 0 {
            let inset = min(r, w / 3)
            p.fill(x + inset, y + 0.5, w - 2 * inset, 0.5, NSColor.white.withAlphaComponent(hl))
        }
    }
    func dot(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ hex: UInt32) { p.fill(x, y, w, h, hex) }
    func ell(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ color: NSColor) { p.ellipse(cx - rx, cy - ry, 2 * rx, 2 * ry, color) }
    func ell(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ hex: UInt32) { ell(cx, cy, rx, ry, NSColor(hex: hex)) }
    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ width: Double, _ hex: UInt32) {
        let c = p.context, h = Double(p.height)
        c.saveGState()
        c.setShouldAntialias(true)
        c.setStrokeColor(NSColor(hex: hex).cgColor)
        c.setLineWidth(width)
        c.move(to: CGPoint(x: x1, y: h - y1)); c.addLine(to: CGPoint(x: x2, y: h - y2))
        c.strokePath()
        c.restoreGState()
    }

    // MARK: Parts

    static let dark: (UInt32, UInt32) = (0x2A2A30, 0x18181C)
    static let skins: [(UInt32, UInt32)] = [(0xEBCDB2, 0xD6B194), (0xD6A886, 0xBF8F6D), (0x9C6A48, 0x7E5236), (0x6E4630, 0x573623)]

    func legs(_ color: (UInt32, UInt32)) {
        guard !pose.sits else { return }
        clay(x - 2.5, y - 3, 2, 3, 0.8, color.0, color.1, hl: 0)
        clay(x + 0.5, y - 3, 2, 3, 0.8, color.0, color.1, hl: 0)
    }
    func body(_ color: (UInt32, UInt32), wide: Double = 8, tall: Double = 7, r: Double = 2.5) {
        clay(x - wide / 2, y - 9, wide, tall, r, color.0, color.1)
        hands()
    }
    /// Hands at the chest while typing (they alternate), a book while reading, a raised hand to wave.
    func hands(_ skin: UInt32 = 0xEBCDB2) {
        if pose.typing {
            ell(x - 2.5, y - 4 - (pose.frame == 0 ? 0.6 : 0), 1, 0.8, skin)
            ell(x + 2.5, y - 4 - (pose.frame == 1 ? 0.6 : 0), 1, 0.8, skin)
        }
        if pose.reading { clay(x - 2.5, y - 6, 5, 3.5, 0.6, 0xF2EBD6, 0xD9CFB4, hl: 0) }
        if pose.cards && pose.front {
            for (k, tilt) in [-1.2, 0, 1.2].enumerated() {
                let cx = x - 3.6 + Double(k) * 1.3
                p.polygon([(cx, y - 7.5 + abs(tilt) * 0.3), (cx + 2, y - 7.8 + abs(tilt) * 0.3), (cx + 2.2 + tilt * 0.3, y - 4.4), (cx + 0.2 + tilt * 0.3, y - 4.2)],
                          NSColor(hex: 0xF4F1EA))
                dot(cx + 0.7, y - 6.8, 0.7, 0.7, k == 1 ? 0x1E1E26 : 0xC8463C)
            }
            ell(x - 2, y - 4.3, 1, 0.8, skin)
        }
        if pose.waving {
            let up = pose.frame == 1 ? 1.0 : 0
            clay(x + 4, y - 14 - up, 1.6, 6, 0.8, 0xD6D2C8, 0xB8B4AA, hl: 0)
            ell(x + 4.8, y - 14.5 - up, 1.2, 1.2, skin)
        }
    }
    func head(_ skin: (UInt32, UInt32), at hy: Double) { clay(x - 5, hy, 10, 9.5, 4, skin.0, skin.1, hl: 0.12) }
    func hair(_ color: (UInt32, UInt32), at hy: Double) { clay(x - 5.5, hy - 1, 11, 4.5, 3, color.0, color.1, hl: 0.12) }
    /// The back of a head: all hair, or all helmet.
    func back(_ color: (UInt32, UInt32), at hy: Double, r: Double = 4) { clay(x - 5.5, hy - 1, 11, 10, r, color.0, color.1, hl: 0.12) }
    func eyes(at hy: Double, _ hex: UInt32 = 0x1E140E, blush: Bool = true) {
        if pose.blink {
            dot(x - 2.7, hy + 5.3, 1.4, 0.5, hex); dot(x + 1.3, hy + 5.3, 1.4, 0.5, hex)
        } else {
            dot(x - 2.5, hy + 4.5, 1, 1.5, hex); dot(x + 1.5, hy + 4.5, 1, 1.5, hex)
        }
        if blush {
            ell(x - 3.2, hy + 6.8, 0.9, 0.5, NSColor(hex: 0xDC6E64).withAlphaComponent(0.4))
            ell(x + 3.2, hy + 6.8, 0.9, 0.5, NSColor(hex: 0xDC6E64).withAlphaComponent(0.4))
        }
    }
    func saber(_ sx: Double, _ sy: Double, _ hex: UInt32) {
        guard !pose.sits, !pose.typing, !pose.reading else { return }
        p.glow(sx, sy - 6, radius: 6, NSColor(hex: hex).withAlphaComponent(0.4))
        dot(sx - 0.7, sy, 1.4, 2.6, 0x8F939C)
        clay(sx - 0.7, sy - 11, 1.4, 11, 0.7, hex, hex, hl: 0)
        p.fill(sx - 0.25, sy - 11, 0.5, 11, NSColor.white.withAlphaComponent(0.75))
    }
    func delta(_ dx: Double, _ dy: Double) {
        p.polygon([(dx, dy - 1.3), (dx + 0.9, dy + 1), (dx, dy + 0.4), (dx - 0.9, dy + 1)], NSColor(hex: 0xE8C46A))
    }
    /// The original series' tunic: one colour, badge on the chest.
    func tunic(_ color: (UInt32, UInt32)) {
        legs(Self.dark)
        clay(x - 4, y - 9, 8, 7, 2.5, color.0, color.1)
        if pose.front { delta(x + 1.8, y - 7.3) }
        hands()
    }
    /// The later uniform: black with coloured shoulders.
    func twoTone(_ shoulders: (UInt32, UInt32)) {
        legs(Self.dark)
        clay(x - 4, y - 9, 8, 7, 2.5, Self.dark.0, Self.dark.1)
        clay(x - 4, y - 9, 8, 3.4, 1.6, shoulders.0, shoulders.1, hl: 0.15)
        if pose.front { delta(x + 1.8, y - 7.5) }
        hands()
    }

    // MARK: Characters

    func draw(_ figure: PixelPerson.Figure) {
        let hy = y - 18, front = pose.front
        let skin0 = Self.skins[0], skin1 = Self.skins[1], skin2 = Self.skins[2], skin3 = Self.skins[3]
        switch figure {
        case .vader:
            if !pose.sits { clay(x - 6, y - 10, 12, 10, 3, 0x2A2A30, 0x18181C, hl: 0.1) }
            legs(Self.dark)
            clay(x - 4, y - 9.5, 8, 7, 2.5, 0x26262C, 0x16161A)
            if front {
                clay(x - 2.5, y - 8.5, 5, 3, 0.8, 0x3A3A44, 0x26262E, hl: 0)
                dot(x - 1.8, y - 7.8, 0.8, 0.8, 0xE05A5A); dot(x - 0.4, y - 7.8, 0.8, 0.8, 0x6CC487); dot(x + 1, y - 7.8, 0.8, 0.8, 0x5E86C2)
            }
            hands(0x26262C)
            clay(x - 6, y - 20, 12, 11, 5, 0x2E2E36, 0x141418, hl: 0.35)
            p.polygon([(x - 6, y - 13), (x - 7, y - 9), (x + 7, y - 9), (x + 6, y - 13)], NSColor(hex: 0x141418))
            if front {
                clay(x - 4, y - 16, 3.4, 2.4, 1.2, 0x4A4A56, 0x2A2A32, hl: 0); clay(x + 0.6, y - 16, 3.4, 2.4, 1.2, 0x4A4A56, 0x2A2A32, hl: 0)
                p.polygon([(x - 2, y - 13), (x + 2, y - 13), (x + 1, y - 10), (x - 1, y - 10)], NSColor(hex: 0x3A3A44))
            }
            saber(x + 6, y - 6, 0xFF3B3B)
        case .yoda:
            let s = 3.0  // shorter than everyone else
            clay(x - 3.5, y - 6, 7, 6, 2.5, 0x8C7458, 0x6A563F)
            if !pose.sits && !pose.typing { dot(x + 4.5, y - 9, 0.8, 9, 0x6E5236) }
            hands(0x8FBF6E)
            p.polygon([(x - 4, y - 12 + s - 3), (x - 6.8, y - 14 + s - 3), (x - 4, y - 9.5 + s - 3)], NSColor(hex: 0x7BAA5C))
            p.polygon([(x + 4, y - 12 + s - 3), (x + 6.8, y - 14 + s - 3), (x + 4, y - 9.5 + s - 3)], NSColor(hex: 0x7BAA5C))
            clay(x - 4.5, y - 15, 9, 8.5, 4, 0x8FBF6E, 0x6E9E52)
            if front {
                if pose.blink { dot(x - 2.8, y - 11, 1.6, 0.5, 0x1E140E); dot(x + 1.2, y - 11, 1.6, 0.5, 0x1E140E) }
                else { ell(x - 2, y - 11, 1, 1, 0x1E140E); ell(x + 2, y - 11, 1, 1, 0x1E140E); dot(x - 2.4, y - 11.6, 0.5, 0.5, 0xFFFFFF); dot(x + 1.6, y - 11.6, 0.5, 0.5, 0xFFFFFF) }
                dot(x - 1, y - 8.5, 2, 0.5, 0x4E7E3A)
            }
        case .r2:
            clay(x - 6, y - 8, 2.5, 8, 1, 0xE8E6E0, 0xC3C0B8, hl: 0); clay(x + 3.5, y - 8, 2.5, 8, 1, 0xE8E6E0, 0xC3C0B8, hl: 0)
            clay(x - 4, y - 12, 8, 11, 2, 0xF0EEE8, 0xCFCCC4)
            dot(x - 3, y - 10, 6, 1.4, 0x3B63B8)
            if front { dot(x - 2.5, y - 7, 2, 3, 0x3B63B8); dot(x + 0.5, y - 7, 2, 1, 0x8A93A3) }
            p.ellipse(x - 4.3, y - 16.3, 8.6, 8.6, NSColor(hex: 0xD9D6CE))
            dot(x - 4.3, y - 12, 8.6, 1.4, 0xCFCCC4)
            dot(x - 4.3, y - 12.4, 8.6, 0.8, 0x9A9890)
            dot(x - 3, y - 14.5, 2.5, 1.4, 0x3B63B8); dot(x + 1.5, y - 14.5, 2, 1.4, 0x3B63B8)
            if front {
                ell(x - 0.5, y - 14, 1, 1, 0x1E1E28)
                ell(x - 0.7, y - 14.2, 0.4, 0.4, pose.frame == 1 ? 0xFF8A8A : 0xE05A5A)
            }
        case .threepio:
            legs((0xD9B048, 0xB08A2C))
            clay(x - 4, y - 10, 8, 8, 2.5, 0xE8C25A, 0xC49A34)
            if front { dot(x - 2, y - 7, 4, 2, 0x8A6A24) }
            hands(0xE8C25A)
            clay(x - 4.5, y - 19.5, 9, 9.5, 4, 0xF0CC62, 0xC9A03A, hl: 0.35)
            if front {
                p.glow(x, y - 15, radius: 5, NSColor(hex: 0xFFE9A0).withAlphaComponent(0.3))
                if pose.blink { dot(x - 3, y - 15, 2, 0.5, 0x8A6A24); dot(x + 1, y - 15, 2, 0.5, 0x8A6A24) }
                else { ell(x - 2, y - 15, 1.4, 1.4, 0xFFE9A0); ell(x + 2, y - 15, 1.4, 1.4, 0xFFE9A0) }
                dot(x - 1.5, y - 11.8, 3, 0.6, 0x8A6A24)
            }
        case .chewie:
            legs((0x7A5434, 0x5C3E24))
            clay(x - 6, y - 12, 12, 10, 4, 0x8E6440, 0x6E4A2C)
            for i in 0..<5 { dot(x - 5 + Double(i) * 2.4, y - 11 + Double(i % 2), 0.6, 2, 0xA87A50) }
            line(x - 5, y - 11, x + 5, y - 4, 1.3, 0x3A2A1E)
            for i in 0..<4 { dot(x - 3.5 + Double(i) * 2.4, y - 10 + Double(i) * 1.6, 1.1, 1.1, 0xC9C6BE) }
            hands(0x8E6440)
            clay(x - 5.5, y - 21, 11, 10.5, 4.5, 0x8E6440, 0x6E4A2C)
            if front {
                clay(x - 3, y - 16.5, 6, 4.5, 2, 0xB08A62, 0x8E6A46, hl: 0)
                if pose.blink { dot(x - 2.8, y - 17.5, 1.6, 0.5, 0x1E140E); dot(x + 1.2, y - 17.5, 1.6, 0.5, 0x1E140E) }
                else { dot(x - 2.5, y - 18, 1, 1.5, 0x1E140E); dot(x + 1.5, y - 18, 1, 1.5, 0x1E140E) }
                dot(x - 0.8, y - 14.5, 1.6, 0.9, 0x3A2416)
            }
        case .trooper:
            legs((0xECEAE4, 0xC9C6BE))
            clay(x - 4.5, y - 9, 9, 7, 3, 0xF0EEE8, 0xCFCCC4)
            if front { dot(x - 1, y - 8, 2, 3, 0x2A2E38) }
            dot(x - 4.5, y - 4, 9, 0.8, 0x2A2E38)
            hands(0xF0EEE8)
            clay(x - 5.5, y - 19.5, 11, 11, 5, 0xF6F4EE, 0xD2CFC6, hl: 0.35)
            if front {
                clay(x - 4, y - 16, 3.5, 2.2, 1, 0x1E1E26, 0x121218, hl: 0); clay(x + 0.5, y - 16, 3.5, 2.2, 1, 0x1E1E26, 0x121218, hl: 0)
                p.polygon([(x - 2.5, y - 12.5), (x + 2.5, y - 12.5), (x + 1.5, y - 10.5), (x - 1.5, y - 10.5)], NSColor(hex: 0x1E1E26))
                dot(x - 1, y - 12, 0.5, 1, 0x8A93A3); dot(x + 0.5, y - 12, 0.5, 1, 0x8A93A3)
            }
        case .luke:
            legs((0xC9C4B8, 0xA8A398))
            body((0xEAE6DC, 0xC9C4B8)); dot(x - 4, y - 5, 8, 1, 0x6A5034)
            if front { head(skin0, at: hy); hair((0xD9B46A, 0xB8924A), at: hy); eyes(at: hy) } else { back((0xD9B46A, 0xB8924A), at: hy) }
            saber(x + 6, y - 5, 0x4CE06A)
        case .leia:
            clay(x - 4.5, y - 9, 9, pose.sits ? 6 : 9, 3, 0xF2EFE8, 0xD2CEC4); dot(x - 4.5, y - 5, 9, 0.8, 0xC9C4B8)
            hands()
            ell(x - 6, y - 13.5, 2.6, 3, 0x5A3A22); ell(x + 6, y - 13.5, 2.6, 3, 0x5A3A22)
            ell(x - 6, y - 13.5, 1.3, 1.6, 0x40281A); ell(x + 6, y - 13.5, 1.3, 1.6, 0x40281A)
            if front { head(skin0, at: hy); clay(x - 5.5, y - 19, 11, 4, 3, 0x5A3A22, 0x40281A); eyes(at: hy) } else { back((0x5A3A22, 0x40281A), at: hy) }
        case .han:
            legs((0x3A4A6A, 0x2A3650))
            body((0xEAE6DC, 0xC9C4B8))
            clay(x - 4, y - 9, 2.6, 7, 1.2, Self.dark.0, Self.dark.1, hl: 0); clay(x + 1.4, y - 9, 2.6, 7, 1.2, Self.dark.0, Self.dark.1, hl: 0)
            clay(x + 3.5, y - 4.5, 2.6, 3.2, 0.8, 0x4A3A2A, 0x36291C, hl: 0)
            if front {
                head(skin1, at: hy); hair((0x5A3A22, 0x40281A), at: hy); eyes(at: hy)
                dot(x - 0.5, y - 11.2, 2.2, 0.5, 0x7A3F2E); dot(x + 1.5, y - 11.6, 0.6, 0.5, 0x7A3F2E)
            } else { back((0x5A3A22, 0x40281A), at: hy) }
        case .obiwan:
            legs((0x5A4634, 0x46362A))
            clay(x - 5, y - 9, 10, 8, 3, 0x8C7458, 0x6A563F); clay(x - 1.2, y - 9, 2.4, 7, 1, 0xC9B894, 0xA8977A, hl: 0)
            hands()
            clay(x - 5.5, y - 19.5, 11, 11, 4.5, 0x8C7458, 0x6A563F)
            if front {
                clay(x - 4, y - 16.5, 8, 7.5, 3.5, skin0.0, skin0.1, hl: 0); eyes(at: hy)
                clay(x - 3, y - 11.5, 6, 3.5, 1.8, 0xE2DED4, 0xBDB8AC, hl: 0)
            }
            saber(x + 6, y - 6, 0x4FA8FF)
        case .kirk:
            tunic((0xE2B43C, 0xBC9024)); dot(x - 4, y - 3.5, 8, 0.6, 0x1E1E26)
            face(skin0, (0x7A4A2A, 0x5A3218), at: hy)
        case .spock:
            tunic((0x5A8FD0, 0x3E6EAE))
            p.polygon([(x - 5, y - 15), (x - 6.8, y - 19), (x - 4.5, y - 13)], NSColor(hex: skin0.1))
            p.polygon([(x + 5, y - 15), (x + 6.8, y - 19), (x + 4.5, y - 13)], NSColor(hex: skin0.1))
            if front {
                head(skin0, at: hy); clay(x - 5.3, y - 19, 10.6, 4.2, 1.2, 0x1E1E26, 0x121218); eyes(at: hy)
                dot(x + 1.2, y - 14.6, 2, 0.5, 0x1E1E26); dot(x + 2.7, y - 15, 0.6, 0.5, 0x1E1E26)
            } else { back((0x1E1E26, 0x121218), at: hy, r: 2) }
        case .mccoy:
            tunic((0x5A8FD0, 0x3E6EAE))
            if !pose.typing { clay(x + 3.5, y - 8, 3, 3.5, 1, 0xC9C6BE, 0xA8A59E); ell(x + 5, y - 7, 0.7, 0.7, 0x6CC487) }
            face(skin0, (0x4A3020, 0x341F12), at: hy)
        case .scotty:
            tunic((0xC8463C, 0xA0342C))
            if !pose.sits { clay(x - 7, y - 6, 3, 4, 0.8, 0x8F939C, 0x6A6E78) }
            face(skin0, (0x3A2A22, 0x24180F), at: hy)
            if front { dot(x - 2, y - 11.5, 4, 0.9, 0x3A2A22) }
        case .uhura:
            legs(Self.dark)
            clay(x - 4.5, y - 9, 9, 7, 3, 0xC8463C, 0xA0342C)
            if front { delta(x + 1.8, y - 7.3) }
            hands(skin3.0)
            clay(x - 2, y - 22, 4, 3, 1.5, 0x1E1612, 0x120C08, hl: 0)
            if front {
                head(skin3, at: hy); clay(x - 5.5, y - 20, 11, 5, 3, 0x1E1612, 0x120C08); eyes(at: hy)
                p.ring(x - 5, y - 11, radius: 0.9, width: 0.4, NSColor(hex: 0xE8C46A))
                dot(x + 4.5, y - 14, 1.4, 1.6, 0x9C9890)
            } else { back((0x1E1612, 0x120C08), at: hy) }
        case .sulu:
            tunic((0xE2B43C, 0xBC9024))
            face(skin1, (0x1E1E26, 0x121218), at: hy)
        case .picard:
            twoTone((0x8E2A34, 0x6E1E26))
            head(skin0, at: hy)
            clay(x - 5.3, y - 15, 1.8, 3.5, 0.9, 0x8A8A90, 0x6A6A70, hl: 0); clay(x + 3.5, y - 15, 1.8, 3.5, 0.9, 0x8A8A90, 0x6A6A70, hl: 0)
            if front { eyes(at: hy) }
        case .data:
            twoTone((0xD9A94A, 0xB88A30))
            clay(x - 5, y - 18, 10, 9.5, 4, 0xEEE6CC, 0xD5CBA8, hl: 0.15)
            if front { clay(x - 5.5, y - 19.2, 11, 4, 3, 0x2A2420, 0x1A1612); eyes(at: hy, 0xD99A1E, blush: false) }
            else { back((0x2A2420, 0x1A1612), at: hy) }
        case .worf:
            twoTone((0xD9A94A, 0xB88A30))
            line(x - 4, y - 9, x + 4, y - 3, 1.1, 0xC9A85A)
            clay(x - 6, y - 18, 3, 9, 1.4, 0x2A1E18, 0x1A120E, hl: 0); clay(x + 3, y - 18, 3, 9, 1.4, 0x2A1E18, 0x1A120E, hl: 0)
            if front {
                head(skin3, at: hy)
                for i in 0..<3 { dot(x - 1.6, y - 18 + Double(i) * 1.5, 3.2, 0.7, 0x4E3020) }
                clay(x - 5.5, y - 19.5, 11, 2.6, 1.3, 0x2A1E18, 0x1A120E, hl: 0); eyes(at: hy)
            } else { back((0x2A1E18, 0x1A120E), at: hy) }
        case .geordi:
            twoTone((0xD9A94A, 0xB88A30))
            if front {
                head(skin2, at: hy); hair((0x1E1612, 0x120C08), at: hy)
                clay(x - 5.5, y - 14.5, 11, 2.4, 1.2, 0xC9C6BE, 0x8F939C, hl: 0.4)
                for i in 0..<6 { dot(x - 4 + Double(i) * 1.5, y - 13.8, 0.7, 1, 0x4FA8FF) }
            } else { back((0x1E1612, 0x120C08), at: hy) }
        }
    }

    /// A plain head: skin and hair facing you, all hair from behind.
    func face(_ skin: (UInt32, UInt32), _ hairColor: (UInt32, UInt32), at hy: Double) {
        if pose.front { head(skin, at: hy); hair(hairColor, at: hy); eyes(at: hy) } else { back(hairColor, at: hy) }
    }
}

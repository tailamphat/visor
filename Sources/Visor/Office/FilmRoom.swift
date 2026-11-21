import AppKit
import VisorCore

/// The film worlds' rooms, on the same layout as the studio so everyone sits
/// and walks to the same spots: a hangar in the galaxy, a starship's deck in
/// Starfleet. The terminal is the same rack everywhere; the other stations
/// dress for the film. Soft clay, dim colours, drawn at 2x like the studio.
enum FilmRoom {
    static func galaxy(_ scene: OfficeScene, props: Bool) -> CGImage? {
        let layout = scene.layout
        guard let p = Pixels(width: Int(OfficeLayout.width), height: Int(layout.height), scale: OfficeRoom.detail) else { return nil }
        let w = OfficeLayout.width, h = layout.height
        // Floor: worn hexagonal deck plates.
        p.fill(0, 0, w, h, 0x2A231C)
        var y = 0.0, row = 0
        while y < h + 9 {
            var x = row % 2 == 0 ? -7.0 : 0
            while x < w + 14 {
                p.polygon([(x + 3.8, y + 0.5), (x + 10.2, y + 0.5), (x + 13.5, y + 4.5), (x + 10.2, y + 8.5), (x + 3.8, y + 8.5), (x + 0.5, y + 4.5)],
                          NSColor(hex: (Int(x) + row) % 3 == 0 ? 0x30281F : 0x352C24))
                x += 14
            }
            y += 9; row += 1
        }
        tables(p, scene, top: 0x6E6255, bottom: 0x544A40, strip: NSColor(hex: 0x6EBEF0).withAlphaComponent(0.6), tint: 0.14) { screen in
            switch device(at: screen) {
            case 0:     // a slanted console with red, amber and green buttons
                p.round(screen.x - 1.5, screen.y + 2.5, 9, 3.5, radius: 1.2, NSColor(hex: 0x5E5448))
                p.polygon([(screen.x - 1, screen.y + 4.5), (screen.x + 7, screen.y + 4.5), (screen.x + 6.3, screen.y - 0.8), (screen.x - 0.3, screen.y - 0.8)], NSColor(hex: 0x3A3028))
                p.glow(screen.x + 3, screen.y + 2, radius: 5, NSColor(hex: 0x6EC8F5).withAlphaComponent(0.3))
                for (k, color) in [0xE05A5A, 0xE6B04A, 0x6CC487].enumerated() { p.fill(screen.x + 0.5 + Double(k) * 2, screen.y + 4.6, 1, 0.8, UInt32(color)) }
            case 1:     // a hologram projector: a disc on a small base
                p.clay(screen.x, screen.y + 3.6, 6, 2.2, radius: 1, top: 0x6E6255, bottom: 0x4E443A)
                p.ellipse(screen.x + 1, screen.y + 3.2, 4, 1.2, NSColor(hex: 0x9FE0FF))
                p.glow(screen.x + 3, screen.y + 1.5, radius: 5, NSColor(hex: 0x6EC8F5).withAlphaComponent(0.35))
            default:    // a datapad lying on the table
                p.round(screen.x - 1, screen.y - 0.8, 8, 5.6, radius: 1.2, NSColor(hex: 0x8A8A90))
                p.fill(screen.x + 5.6, screen.y + 3.4, 0.8, 0.8, 0xE6B04A)
            }
        }
        let t = layout.stationTop, o = (w - 212) / 2
        // A solid amber line along the corridor.
        p.fill(0, layout.deskBottom + 3, w, 0.8, 0xD9A441)
        terminal(p, o: o, t: t)
        // Docs: a library of old books and scrolls, a glowing holocron on top.
        library(p, x: 37 + o, t: t, top: 0x6A5E50, bottom: 0x52483D, back: 0x3A3028,
                books: [(0xA84E40, 0x863B30), (0xC08A3E, 0x9C6E2C), (0x6C8A5C, 0x527046), (0x8A7458, 0x6A563F), (0x4F76A8, 0x3B5B86)])
        p.glow(40 + o, t - 5, radius: 6, NSColor(hex: 0x6EC8F5).withAlphaComponent(0.45))
        p.clay(37.5 + o, t - 7.5, 5, 4.5, radius: 1, top: 0x7CD0F5, bottom: 0x3E9AC8)
        p.clay(59 + o, t - 6, 7, 3, radius: 1.5, top: 0xE8DCC0, bottom: 0xC9B994)
        // You: a command console; its screen glows amber while someone waits.
        p.shadow(92 + o, t + 8, 32, 9, radius: 4)
        p.clay(92 + o, t + 8, 32, 9, radius: 4, top: 0x6E6255, bottom: 0x544A40)
        for (k, color) in [0xD9663E, 0xE6B04A, 0x6CC487, 0x4EA8D9, 0xD9663E, 0xE6B04A].enumerated() {
            p.fill(96 + o + Double(k) * 4.5, t + 11, 2, 1.4, UInt32(color))
        }
        p.round(102 + o, t + 1, 12, 7, radius: 1.5, NSColor(hex: 0x1E1B17))
        p.fill(103 + o, t + 2, 10, 5, scene.waiting > 0 ? 0xC98E26 : 0x1E3A4E)
        // Web: a holotable projecting a battle station.
        let web = OfficeLayout.webX
        p.glow(web, t + 8, radius: 15, NSColor(hex: 0x5EBEF2).withAlphaComponent(0.3))
        p.clay(web - 11, t + 14, 22, 7, radius: 3.5, top: 0x6E6255, bottom: 0x544A40)
        p.polygon([(web - 8, t + 14), (web + 8, t + 14), (web + 5, t - 1), (web - 5, t - 1)], NSColor(hex: 0x6EC8F5).withAlphaComponent(0.16))
        p.ellipse(web - 5, t + 3, 10, 10, NSColor(hex: 0x7CD0F5).withAlphaComponent(0.55))
        p.fill(web - 5, t + 8, 10, 0.5, NSColor(hex: 0xBFEFFF))
        p.ring(web + 1.5, t + 5.8, radius: 1.5, width: 0.5, NSColor(hex: 0xBFEFFF))
        // Break: a game of holochess on a round table, little monsters flickering on the board.
        let brk = OfficeLayout.sofaX
        p.ellipse(brk - 13, t + 12, 26, 7, NSColor.black.withAlphaComponent(0.3))
        p.clay(brk - 5, t + 8, 10, 7, radius: 2, top: 0x5C4D3D, bottom: 0x46392D)
        p.ellipse(brk - 12, t + 3, 24, 9, NSColor(hex: 0x3A3028))
        p.ellipse(brk - 11, t + 3.5, 22, 7.5, NSColor(hex: 0x4A3E32))
        for k in 0..<8 {
            let a = Double(k) / 8 * 2 * .pi
            p.ellipse(brk + cos(a) * 7 - 1.2, t + 7.2 + sin(a) * 2.4 - 0.5, 2.4, 1, NSColor(hex: k % 2 == 0 ? 0x2E2720 : 0x7A6248))
        }
        p.glow(brk, t + 3, radius: 10, NSColor(hex: 0x6EC8F5).withAlphaComponent(0.35))
        for (mx, color) in [(brk - 4, 0x7CD0F5), (brk + 3, 0x9FE0A8), (brk, 0xF2B0D8)] where props {
            p.ellipse(mx - 1.2, t + 1.5, 2.4, 3.5, NSColor(hex: UInt32(color)).withAlphaComponent(0.85))
        }
        return p.image
    }

    static func starfleet(_ scene: OfficeScene, props: Bool) -> CGImage? {
        let layout = scene.layout
        guard let p = Pixels(width: Int(OfficeLayout.width), height: Int(layout.height), scale: OfficeRoom.detail) else { return nil }
        let w = OfficeLayout.width, h = layout.height
        // Floor: deep navy carpet with a faint grid.
        p.fill(0, 0, w, h, 0x1C1E2C)
        var y = 0.0
        while y < h { p.fill(0, y, w, 0.5, 0x22253A); y += 6 }
        var x = 0.0
        while x < w { p.fill(x, 0, 0.5, h, 0x202334); x += 12 }
        let pastel: [UInt32] = [0xE2A050, 0x9C8CC9, 0xD98A7A, 0x6F8FCF]
        var seat = 0
        tables(p, scene, top: 0x3A3D52, bottom: 0x2B2D3E, strip: NSColor(hex: 0xE2A050).withAlphaComponent(0.6), tint: 0.15) { screen in
            switch device(at: screen) {
            case 0:     // a black console with rounded pastel bars
                p.round(screen.x - 1.5, screen.y - 1.5, 9, 7.5, radius: 1.8, NSColor(hex: 0x16172A))
                p.round(screen.x - 0.5, screen.y + 4.4, 7, 0.9, radius: 0.45, NSColor(hex: pastel[seat % pastel.count]))
            case 1:     // a PADD: a gold-edged tablet, a stylus beside it
                p.round(screen.x - 1, screen.y - 1, 8, 6.2, radius: 1.2, NSColor(hex: 0xC9A86A))
                p.fill(screen.x + 7.6, screen.y - 1, 0.5, 5.5, 0xC9C6BE)
            default:    // a tricorder: the lid up behind its screen, buttons on the body
                p.round(screen.x - 1, screen.y - 1.2, 8, 5.4, radius: 1, NSColor(hex: 0x3A3A42))
                p.round(screen.x - 1, screen.y + 4, 8, 2.4, radius: 0.8, NSColor(hex: 0x2A2A30))
                for (k, color) in [0xE05A5A, 0x6CC487, 0xE2A050].enumerated() { p.fill(screen.x + 0.5 + Double(k) * 2, screen.y + 4.8, 1, 0.8, UInt32(color)) }
            }
            seat += 1
        }
        let t = layout.stationTop, o = (w - 212) / 2
        p.fill(0, layout.deskBottom + 3, w, 0.8, 0x34374F)
        x = 4
        while x < w { p.fill(x, layout.deskBottom + 2.8, 2, 1.2, 0x9C8CC9); x += 10 }
        terminal(p, o: o, t: t)
        // Docs: the captain's bookshelf of real books, a model starship on top.
        library(p, x: 37 + o, t: t, top: 0x4E4466, bottom: 0x3C3452, back: 0x22253A,
                books: [(0x8E2A34, 0x6E1E26), (0xD9A94A, 0xB88A30), (0x5A8FD0, 0x3E6EAE), (0x2E4A3A, 0x22382C), (0xC9C6BE, 0xA8A59E)])
        p.clay(34.5 + o, t - 5.5, 10, 2, radius: 1, top: 0xC9C6BE, bottom: 0x8F939C)
        p.clay(36.5 + o, t - 7.5, 2, 2.5, radius: 0.8, top: 0xC9C6BE, bottom: 0x8F939C)
        p.clay(40 + o, t - 7, 4, 1.2, radius: 0.6, top: 0xC9C6BE, bottom: 0x8F939C)
        p.clay(60 + o, t - 5.5, 6, 2.5, radius: 0.8, top: 0x3A3D52, bottom: 0x2B2D3E)
        // You: the captain's chair, and a console beside it that glows amber while someone waits.
        p.shadow(101 + o, t + 1, 16, 15, radius: 6)
        p.clay(101 + o, t - 1, 16, 14, radius: 6, top: 0x4A3E5A, bottom: 0x3A3048)
        p.clay(103 + o, t + 7, 12, 9, radius: 3, top: 0x5A4C6C, bottom: 0x463A56)
        p.clay(97 + o, t + 9, 5, 4, radius: 2, top: 0x3A3D52, bottom: 0x2B2D3E)
        p.clay(116 + o, t + 9, 5, 4, radius: 2, top: 0x3A3D52, bottom: 0x2B2D3E)
        p.fill(98 + o, t + 10, 1.4, 1, 0xE6B04A); p.fill(117.5 + o, t + 10, 1.4, 1, 0xE2A050)
        p.round(122 + o, t + 4, 7, 9, radius: 1.5, NSColor(hex: 0x0E0F1C))
        p.fill(123 + o, t + 5, 5, 4, scene.waiting > 0 ? 0xC98E26 : 0x2A2D42)
        // Web: a sensor scope: rings, a sweep line and two contacts.
        let web = OfficeLayout.webX
        p.glow(web, t + 9, radius: 14, NSColor(hex: 0x6F8FCF).withAlphaComponent(0.25))
        p.clay(web - 8, t + 15, 16, 5, radius: 2.5, top: 0x3A3D52, bottom: 0x2B2D3E)
        for r in stride(from: 3.0, through: 9, by: 3) { p.ring(web, t + 9, radius: r, width: 0.5, NSColor(hex: 0x8FA9E8).withAlphaComponent(0.6)) }
        let c = p.context, ch = Double(p.height)
        c.saveGState(); c.setShouldAntialias(true)
        c.setStrokeColor(NSColor(hex: 0x8FA9E8).withAlphaComponent(0.7).cgColor); c.setLineWidth(0.5)
        c.move(to: CGPoint(x: web, y: ch - (t + 9))); c.addLine(to: CGPoint(x: web + 7, y: ch - (t + 4))); c.strokePath()
        c.restoreGState()
        p.ellipse(web + 3.1, t + 5.1, 1.8, 1.8, NSColor(hex: 0xE6B04A))
        p.ellipse(web - 4.7, t + 11.3, 1.4, 1.4, NSColor(hex: 0xD98A7A))
        // Break: poker night at a green table, and a replicator serving tea.
        let brk = OfficeLayout.sofaX
        p.round(brk - 24, t - 6, 9, 13, radius: 2, NSColor(hex: 0x2A2D42))
        p.round(brk - 23, t - 4.5, 7, 7, radius: 1.5, NSColor(hex: 0x0E1020))
        p.glow(brk - 19.5, t - 1, radius: 5, NSColor(hex: 0x8FA9E8).withAlphaComponent(0.45))
        p.clay(brk - 21, t - 0.5, 3, 3, radius: 0.8, top: 0xFFFFFF, bottom: 0xDCD6CC)
        p.ellipse(brk - 14, t + 10, 28, 7, NSColor.black.withAlphaComponent(0.3))
        p.clay(brk - 3, t + 8, 6, 7, radius: 1.5, top: 0x3A3D52, bottom: 0x2B2D3E)
        p.ellipse(brk - 13, t + 2, 26, 10, NSColor(hex: 0x5A4030))
        p.ellipse(brk - 11.5, t + 2.6, 23, 8.4, NSColor(hex: 0x2E7A4E))
        for (cx, cy) in [(brk - 7, t + 4.5), (brk - 4, t + 6.5), (brk + 3, t + 5), (brk + 6, t + 6.5)] where props {
            p.fill(cx, cy, 2, 2.6, 0xF4F1EA); p.fill(cx + 0.5, cy + 0.6, 0.8, 0.8, 0xC8463C)
        }
        for (k, color) in [0xC8463C, 0xE8C46A, 0x5A8FD0].enumerated() where props {
            for n in 0..<3 { p.ellipse(brk - 1.5 + Double(k) * 1.6, t + 6 - Double(n) * 0.6, 2, 0.9, NSColor(hex: UInt32(color))) }
        }
        return p.image
    }

    // MARK: Shared

    /// Which device stands at a seat, 0-2, the same for the room and the seat's screen.
    static func device(at screen: OfficePoint) -> Int {
        (Int(screen.x / 11) + Int(screen.y / 7)) % 3
    }

    /// Each tool's table: a tinted zone, the table, a light strip, and what's at each seat.
    private static func tables(_ p: Pixels, _ scene: OfficeScene, top: UInt32, bottom: UInt32, strip: NSColor, tint: Double,
                               seat: (OfficePoint) -> Void) {
        let layout = scene.layout
        for island in layout.islands {
            let color = AgentStyle.mark(island.agent)
            p.round(island.x, island.y, island.width, OfficeLayout.islandHeight, radius: 6, color.withAlphaComponent(tint))
            p.shadow(island.x + 2, island.y + 18, island.width - 4, 15, radius: 5)
            p.clay(island.x + 2, island.y + 18, island.width - 4, 15, radius: 5, top: top, bottom: bottom)
            p.fill(island.x + 6, island.y + 25, island.width - 12, 0.8, strip)
            for i in 0..<island.seats { seat(layout.seat(island, i).screen) }
        }
    }

    /// The terminal is the same rack in every world: a screen of green lines and three drives.
    private static func terminal(_ p: Pixels, o: Double, t: Double) {
        let x = 9 + o, y = t - 3
        p.shadow(x, y, 20, 24, radius: 4)
        p.clay(x, y, 20, 24, radius: 4, top: 0x4A4F5A, bottom: 0x363A44)
        p.clay(x + 2.5, y + 2.5, 15, 9, radius: 2, top: 0x16201C, bottom: 0x101814)
        for i in 0..<3 { p.fill(x + 4, y + 4.5 + Double(i) * 2.3, Double(3 + (i * 4) % 8), 0.9, 0x6FCB85) }
        for i in 0..<3 {
            p.clay(x + 2.5, y + 13.5 + Double(i) * 3.3, 15, 2.6, radius: 1, top: 0x3D424C, bottom: 0x2E323A)
            p.fill(x + 4, y + 14.4 + Double(i) * 3.3, 0.9, 0.9, i == 1 ? 0xD9A441 : 0x6FCB85)
        }
    }

    /// Docs in every world: a bookshelf of three rows, a book leaning in the middle one.
    private static func library(_ p: Pixels, x: Double, t: Double, top: UInt32, bottom: UInt32, back: UInt32, books: [(UInt32, UInt32)]) {
        let y = t - 3
        p.shadow(x, y, 30, 24, radius: 3)
        p.clay(x, y, 30, 24, radius: 3, top: top, bottom: bottom)
        for r in 0..<3 {
            let ry = y + 2.5 + Double(r) * 7
            p.round(x + 2, ry, 26, 6, radius: 1, NSColor(hex: back))
            for i in 0..<7 {
                let tall = 4 + Double((i + r) % 3) * 0.6
                let (a, b) = books[(i + r * 2) % books.count]
                p.clay(x + 3 + Double(i) * 3.4, ry + 6 - tall, 2.8, tall, radius: 0.6, top: a, bottom: b)
            }
        }
        let (a, _) = books[0]
        p.polygon([(x + 25.2, y + 15.5), (x + 27.8, y + 14.6), (x + 29.2, y + 18.6), (x + 26.6, y + 19.5)], NSColor(hex: a))
    }
}

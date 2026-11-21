import AppKit
import SwiftUI
import VisorCore

/// The room behind the people, a cozy studio at night in soft clay: a warm
/// wooden floor, a lamp pooling light on each table, rounded furniture lit
/// from above with soft shadows. Drawn at 2x so the curves stay smooth.
enum OfficeRoom {
    static let detail = 2

    /// `props`: the break game's pieces and cards drawn still, for a thumbnail;
    /// the office animates its own (`BreakProps`).
    static func image(_ scene: OfficeScene, world: OfficeWorld, props: Bool = false) -> CGImage? {
        switch world {
        case .studio: return studio(scene)
        case .galaxy: return FilmRoom.galaxy(scene, props: props)
        case .starfleet: return FilmRoom.starfleet(scene, props: props)
        }
    }

    private static func studio(_ scene: OfficeScene) -> CGImage? {
        let layout = scene.layout
        guard let p = Pixels(width: Int(OfficeLayout.width), height: Int(layout.height), scale: detail) else { return nil }
        let w = OfficeLayout.width, h = layout.height
        // Floor: warm planks, low contrast.
        var y = 0.0
        while y < h {
            let row = Int(y / 5)
            p.fill(0, y, w, 5, row % 2 == 1 ? 0x2B211C : 0x2F241E)
            var x = Double((row * 37) % 41)
            while x < w { p.fill(x, y, 1, 5, 0x251C18); x += 41 }
            y += 5
        }
        // Plants at the ends of the corridor, clear of the tables' names.
        for x in [8.0, w - 18] { plant(p, x, layout.deskBottom + 6) }
        for island in layout.islands {
            let color = AgentStyle.mark(island.agent)
            let mid = island.x + island.width / 2
            p.glow(mid, island.y + 26, radius: island.width * 0.6 + 14, NSColor(hex: 0xFFC478).withAlphaComponent(0.2))
            p.shadow(island.x, island.y, island.width, OfficeLayout.islandHeight, radius: 8)
            p.round(island.x, island.y, island.width, OfficeLayout.islandHeight, radius: 8, color.withAlphaComponent(0.2))
            p.shadow(island.x + 2, island.y + 18, island.width - 4, 15, radius: 5)
            p.clay(island.x + 2, island.y + 18, island.width - 4, 15, radius: 5, top: 0xB08560, bottom: 0x7E5A3C)
            p.fill(island.x + 6, island.y + 19, island.width - 12, 1, NSColor.white.withAlphaComponent(0.25))
            for i in 0..<island.seats {
                let screen = layout.seat(island, i).screen
                p.round(screen.x - 1, screen.y - 1, 8, 6, radius: 1.5, NSColor(hex: 0x120E0C))
            }
            // The lamp on the table.
            p.ellipse(mid - 1.5, island.y + 30, 3, 2, NSColor(hex: 0xF2D08A))
        }
        let t = layout.stationTop, o = (w - 212) / 2
        p.fill(0, layout.deskBottom + 3, w, 1, NSColor(hex: 0x3A2C24))
        // Terminal: a dark clay rack with green lights.
        p.shadow(10 + o, t, 18, 20, radius: 4)
        p.clay(10 + o, t, 18, 20, radius: 4, top: 0x3A302B, bottom: 0x241D1A)
        for i in 0..<4 {
            let row = t + 3 + Double(i) * 4
            p.round(12 + o, row, 14, 3, radius: 1, NSColor(hex: 0x2E2622))
            p.fill(13 + o, row + 1, 1, 1, 0x7EE08A); p.fill(15 + o + Double(i * 2 % 7), row + 1, 3, 1, 0x9BE7A2)
        }
        // Bookshelf
        p.shadow(38 + o, t, 28, 20, radius: 4)
        p.clay(38 + o, t, 28, 20, radius: 4, top: 0x8A6440, bottom: 0x5E4228)
        let books: [UInt32] = [0xC0504D, 0xD98F4E, 0x9BBB59, 0xF2C14E, 0x8064A2, 0x4BACC6]
        for r in 0..<3 {
            p.fill(40 + o, t + 6 + Double(r) * 6, 24, 1, 0x4A3220)
            for i in 0..<7 { p.round(41 + o + Double(i) * 3, t + 2 + Double(r) * 6, 2, 4, radius: 0.6, NSColor(hex: books[(i + r * 2) % books.count])) }
        }
        // Your desk, its screen amber while someone waits
        p.shadow(92 + o, t + 8, 32, 9, radius: 4)
        p.clay(92 + o, t + 8, 32, 9, radius: 4, top: 0xB08560, bottom: 0x7E5A3C)
        p.round(103 + o, t + 2, 10, 7, radius: 1.5, NSColor(hex: 0x120E0C))
        p.fill(104 + o, t + 3, 8, 5, scene.waiting > 0 ? 0x6A5012 : 0x241C1A)
        p.ellipse(117 + o, t + 5, 3, 3, NSColor(hex: 0xF2C14E))
        // Web: a hologram projector; its rings turn above it (`OfficeRoom.ring`).
        p.glow(OfficeLayout.webX, t + 9, radius: 14, NSColor(hex: 0x5EF2FF).withAlphaComponent(0.22))
        p.ellipse(OfficeLayout.webX - 9, t + 16, 18, 5, NSColor.black.withAlphaComponent(0.3))
        p.clay(OfficeLayout.webX - 8, t + 15, 16, 4, radius: 2, top: 0x3A302B, bottom: 0x241D1A)
        p.fill(OfficeLayout.webX - 5, t + 15, 10, 1, NSColor(hex: 0x5EF2FF).withAlphaComponent(0.8))
        p.ellipse(OfficeLayout.webX - 1.5, t + 7.5, 3, 3, NSColor(hex: 0xE6FDFF))
        // Break: a ping-pong table, its net across the middle.
        let brk = OfficeLayout.sofaX
        p.ellipse(brk - 14, t + 11, 28, 5, NSColor.black.withAlphaComponent(0.3))
        for lx in [brk - 10, brk + 8] { p.fill(lx, t + 12, 2, 4, 0x1E1A18) }
        p.round(brk - 12, t + 3, 24, 10, radius: 1, NSColor(hex: 0x2E6B4F))
        p.fill(brk - 12, t + 3, 24, 0.6, NSColor(hex: 0xE7EFE9))
        p.fill(brk - 12, t + 12.4, 24, 0.6, NSColor(hex: 0xE7EFE9))
        p.fill(brk - 12, t + 7.7, 24, 0.5, NSColor(hex: 0xE7EFE9).withAlphaComponent(0.5))
        p.fill(brk - 0.5, t + 1.5, 1, 12, NSColor(hex: 0xF0F0F0).withAlphaComponent(0.8))
        return p.image
    }

    /// One ring of the web hologram, 20 x 20 room pixels drawn finely: the
    /// outer one in long arcs with ticks, the inner one dashed.
    static func ring(outer: Bool) -> CGImage? {
        guard let p = Pixels(width: 20, height: 20, scale: 4) else { return nil }
        let c = p.context
        c.setShouldAntialias(true)
        c.setLineCap(.round)
        let cyan = NSColor(hex: 0x5EF2FF)
        let center = CGPoint(x: 10, y: 10)
        if outer {
            c.setStrokeColor(cyan.withAlphaComponent(0.9).cgColor)
            c.setLineWidth(1.1)
            for start in stride(from: 0.0, to: 360.0, by: 120.0) {
                c.addArc(center: center, radius: 8.6, startAngle: (start + 10) * .pi / 180, endAngle: (start + 95) * .pi / 180, clockwise: false)
                c.strokePath()
            }
            c.setLineWidth(0.6)
            c.setStrokeColor(cyan.withAlphaComponent(0.6).cgColor)
            for angle in stride(from: 0.0, to: 360.0, by: 30.0) {
                let a = angle * .pi / 180
                c.move(to: CGPoint(x: 10 + cos(a) * 6.6, y: 10 + sin(a) * 6.6))
                c.addLine(to: CGPoint(x: 10 + cos(a) * 7.4, y: 10 + sin(a) * 7.4))
                c.strokePath()
            }
        } else {
            c.setStrokeColor(cyan.withAlphaComponent(0.75).cgColor)
            c.setLineWidth(0.8)
            c.setLineDash(phase: 0, lengths: [2.2, 1.4])
            c.addArc(center: center, radius: 5, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            c.strokePath()
            c.setLineDash(phase: 0, lengths: [])
            c.setStrokeColor(cyan.withAlphaComponent(0.5).cgColor)
            c.setLineWidth(0.5)
            c.addArc(center: center, radius: 3, startAngle: 0.3, endAngle: 2.6, clockwise: false)
            c.strokePath()
            c.addArc(center: center, radius: 3, startAngle: 3.4, endAngle: 5.7, clockwise: false)
            c.strokePath()
        }
        return p.image
    }

    static func plant(_ p: Pixels, _ x: Double, _ y: Double) {
        p.shadow(x + 1, y + 6, 7, 5, radius: 2)
        p.clay(x + 1, y + 6, 7, 5, radius: 2, top: 0xB07850, bottom: 0x7A4E31)
        p.round(x, y + 1, 9, 6, radius: 3, NSColor(hex: 0x2F7A3E))
        p.round(x + 2, y - 1, 5, 4, radius: 2, NSColor(hex: 0x3E9A50))
    }
}

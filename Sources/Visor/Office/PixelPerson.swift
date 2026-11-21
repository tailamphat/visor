import AppKit
import SwiftUI
import VisorCore

/// The agents as chibi people: big outlined heads, blinking eyes, rosy cheeks.
enum PixelPerson {
    static let width = 11.0
    static let height = 17.0
    /// How far above the feet the top of the head is, for the bubble beside it.
    static let headTop = 15.0

    struct Look: Hashable {
        var shirt: UInt32
        var hair: UInt32
        var skin: UInt32
        /// A film character in place of the usual person, in a film world.
        var figure: Figure? = nil
        var world: OfficeWorld = .studio
    }

    /// The film worlds' characters, drawn in clay by `FilmCast`.
    enum Figure: String, CaseIterable {
        case vader, yoda, r2, threepio, chewie, trooper, luke, leia, han, obiwan
        case kirk, spock, mccoy, scotty, uhura, sulu, picard, data, worf, geordi

        static func cast(_ world: OfficeWorld) -> [Figure] {
            switch world {
            case .studio: return []
            case .galaxy: return [.vader, .yoda, .r2, .threepio, .chewie, .trooper, .luke, .leia, .han, .obiwan]
            case .starfleet: return [.kirk, .spock, .mccoy, .scotty, .uhura, .sulu, .picard, .data, .worf, .geordi]
            }
        }

        /// Shirt, hair and skin.
        var colors: (UInt32, UInt32, UInt32) {
            switch self {
            case .vader: return (0x2A2A30, 0x1C1C22, 0x1C1C22)
            case .yoda: return (0x8C7458, 0x8FBF6E, 0x8FBF6E)
            case .r2: return (0xF0EEE8, 0x3B63B8, 0xD9D6CE)
            case .threepio: return (0xD9B048, 0xE8C25A, 0xE8C25A)
            case .chewie: return (0x8E6440, 0x8E6440, 0x8E6440)
            case .trooper: return (0xF0EEE8, 0xF0EEE8, 0xF0EEE8)
            case .luke: return (0xEAE6DC, 0xD9B46A, 0xF1C7A1)
            case .leia: return (0xF2EFE8, 0x5A3A22, 0xF6D7BC)
            case .han: return (0xEAE6DC, 0x5A3A22, 0xD8A27A)
            case .obiwan: return (0x8C7458, 0xB8A890, 0xF1C7A1)
            case .kirk: return (0xE2B43C, 0x7A4A2A, 0xF1C7A1)
            case .spock: return (0x5A8FD0, 0x1E1E26, 0xF1D9B8)
            case .mccoy: return (0x5A8FD0, 0x4A3020, 0xF1C7A1)
            case .scotty: return (0xC8463C, 0x3A2A22, 0xF1C7A1)
            case .uhura: return (0xC8463C, 0x1E1612, 0x7A4E31)
            case .sulu: return (0xE2B43C, 0x1E1E1E, 0xD8A27A)
            case .picard: return (0x1E1E26, 0xF1C7A1, 0xF1C7A1)
            case .data: return (0x1E1E26, 0x2A2420, 0xEEE3C2)
            case .worf: return (0x1E1E26, 0x2A1E18, 0x7A4E31)
            case .geordi: return (0x1E1E26, 0x1E1612, 0x7A4E31)
            }
        }
    }

    enum Pose: Hashable {
        case typing, still, reading, wave, sitting, dozing, walk
        /// On break in a film world: at the game table, cards in hand on the starship.
        case playing
    }

    static let hairs: [UInt32] = [0x3B2A20, 0xE8D27A, 0x1E1E1E, 0x8B4A2B, 0xC9C9D1, 0x5A3A7A, 0x2E4A2E]
    static let skins: [UInt32] = [0xF1C7A1, 0xD8A27A, 0xA8714D, 0x7A4E31, 0xF6D7BC]

    /// A look that stays the same for a session: its tool's colour, and hair and
    /// skin picked from its id.
    static func look(for agent: OfficeAgent, world: OfficeWorld = .studio, figure: Figure? = nil) -> Look {
        if let figure {
            let (shirt, hair, skin) = figure.colors
            return Look(shirt: shirt, hair: hair, skin: skin, figure: figure, world: world)
        }
        let seed = agent.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return Look(shirt: AgentStyle.mark(agent.agent).hexValue, hair: hairs[seed % hairs.count], skin: skins[(seed / 7) % skins.count], world: world)
    }

    static func pose(for agent: OfficeAgent) -> (Pose, CFTimeInterval) {
        switch agent.activity {
        case .typing, .running, .browsing: return (.typing, 0.32)
        case .thinking, .done: return (agent.sits ? .sitting : .still, 4)
        case .reading: return (.reading, 4)
        case .approval, .question: return (.wave, 1)
        case .idle: return (agent.sits ? .dozing : .still, 4)
        }
    }

    private static var cache: [String: [CGImage]] = [:]

    /// The frames of a pose, facing you (`front`) or facing away. Still poses
    /// that face you blink now and then: a long open frame, a short closed one.
    static func frames(_ look: Look, pose: Pose, front: Bool) -> [CGImage] {
        let key = "\(look.shirt)-\(look.hair)-\(look.skin)-\(look.figure?.rawValue ?? "")-\(pose)-\(front)"
        if let hit = cache[key] { return hit }
        let images: [CGImage]
        switch pose {
        case .typing, .wave, .walk:
            images = (0..<2).compactMap { draw(look, pose: pose, front: front, frame: $0, blink: false) }
        case .still, .reading, .sitting, .playing:
            let open = draw(look, pose: pose, front: front, frame: 0, blink: false)
            let shut = front ? draw(look, pose: pose, front: front, frame: 0, blink: true) : nil
            // 4 seconds: open for 15 of 16 beats, shut for one.
            images = shut.map { shut in (0..<15).compactMap { _ in open } + [shut] } ?? [open].compactMap { $0 }
        case .dozing:
            images = [draw(look, pose: pose, front: front, frame: 0, blink: true)].compactMap { $0 }
        }
        cache[key] = images
        return images
    }

    private static func draw(_ look: Look, pose: Pose, front: Bool, frame: Int, blink: Bool) -> CGImage? {
        guard let p = Pixels(width: Int(width), height: Int(height)) else { return nil }
        if let figure = look.figure {
            return FilmCast.image(figure, .init(front: front, sits: pose == .sitting || pose == .dozing, blink: blink, frame: frame,
                                                typing: pose == .typing, waving: pose == .wave, reading: pose == .reading,
                                                cards: pose == .playing && look.world == .starfleet))
        }
        let shirt = NSColor(hex: look.shirt)
        let hair = NSColor(hex: look.hair), skin = NSColor(hex: look.skin), line = NSColor(hex: 0x141018)
        let x = 5.0, y = height
        let sits = pose == .sitting || pose == .dozing
        let by = sits ? 3.0 : 0
        let walking = pose == .walk, typing = pose == .typing
        let step = frame == 1
        if !sits {
            p.fill(x - 3, y - 3 - (walking && step ? 1 : 0), 3, 3, line)
            p.fill(x + 1, y - 3 - (walking && !step ? 1 : 0), 3, 3, line)
        }
        p.fill(x - 3, y - 6 + by, 7, 4, line)
        p.fill(x - 2, y - 6 + by, 5, 3, shirt)
        p.fill(x - 4, y - 6 + by + (typing && step ? -1 : 0), 1, 2, line)
        if pose == .wave {
            let a = step ? 1.0 : 0
            p.fill(x + 4, y - 13 + a, 1, 7 - a, line)
            p.fill(x + 3 + a, y - 14 + a, 2, 2, skin)
        } else {
            p.fill(x + 4, y - 6 + by + (typing && !step ? -1 : 0), 1, 2, line)
        }
        p.fill(x - 4, y - 15 + by, 9, 9, line)
        if front {
            p.fill(x - 3, y - 13 + by, 7, 6, skin)
            p.fill(x - 3, y - 14 + by, 7, 2, hair)
            p.fill(x - 3, y - 13 + by, 1, 3, hair); p.fill(x + 3, y - 13 + by, 1, 3, hair)
            if blink {
                p.fill(x - 2, y - 10 + by, 2, 1, line); p.fill(x + 1, y - 10 + by, 2, 1, line)
            } else {
                p.fill(x - 2, y - 11 + by, 2, 2, line); p.fill(x + 1, y - 11 + by, 2, 2, line)
                p.fill(x - 2, y - 11 + by, 1, 1, .white); p.fill(x + 1, y - 11 + by, 1, 1, .white)
            }
            p.fill(x - 3, y - 9 + by, 1, 1, 0xF29A9A); p.fill(x + 3, y - 9 + by, 1, 1, 0xF29A9A)
            if pose == .reading { p.fill(x - 2, y - 6, 5, 3, 0xE9E3C8) }
        } else {
            p.fill(x - 3, y - 14 + by, 7, 7, hair)
            if pose == .reading { p.fill(x - 2, y - 8, 5, 2, 0xE9E3C8) }
        }
        return p.image
    }

    /// A screen at a table: 6 x 4 room pixels.
    static func screen(_ look: Look, activity: OfficeActivity?, device: Int = 0) -> [CGImage] {
        let key = "screen-\(look.world)-\(device)-\(look.shirt)-\(String(describing: activity))"
        if let hit = cache[key] { return hit }
        if look.world != .studio { return filmScreen(look.world, activity: activity, device: device, key: key) }
        let shirt = NSColor(hex: look.shirt), dark = shirt.blended(withFraction: 0.35, of: .black) ?? shirt
        var images: [CGImage] = []
        switch activity {
        case .typing:
            for f in 0..<3 {
                guard let p = Pixels(width: 6, height: 4) else { break }
                p.fill(0, 0, 6, 4, dark)
                for k in 0..<2 { p.fill(1, 1 + Double(k) * 2, Double(1 + (f + k * 2) % 4), 1, 0xF2F0FF) }
                if let image = p.image { images.append(image) }
            }
        case .thinking:
            for f in 0..<3 {
                guard let p = Pixels(width: 6, height: 4) else { break }
                p.fill(0, 0, 6, 4, dark)
                p.fill(1 + Double(f) * 2, 2, 1, 1, 0xF2F0FF)
                if let image = p.image { images.append(image) }
            }
        default:
            if let p = Pixels(width: 6, height: 4) {
                p.fill(0, 0, 6, 4, 0x241C1A)
                p.fill(2, 1, 2, 2, dark)
                if let image = p.image { images.append(image) }
            }
        }
        cache[key] = images
        return images
    }
}

extension PixelPerson {
    /// A film world's screen, by the device at the seat (`FilmRoom.device`):
    /// galaxy: a console's blue screen, a hologram figure, a datapad; starship: a
    /// console's pastel bars, a PADD, a tricorder. Lines scroll while it types,
    /// a dot moves while it thinks.
    fileprivate static func filmScreen(_ world: OfficeWorld, activity: OfficeActivity?, device: Int, key: String) -> [CGImage] {
        let galaxy = world == .galaxy
        let pastel: [UInt32] = [0xE2A050, 0x9C8CC9, 0xD98A7A, 0x6F8FCF]
        let (back, ink): (UInt32?, [UInt32]) = switch (galaxy, device) {
        case (true, 1): (nil, [0x9FE0FF, 0x7CD0F5])           // hologram: no screen, just light
        case (true, 2): (0x1E2A34, [0x7CD0F5, 0xE6B04A])      // datapad
        case (true, _): (0x2E7AA6, [0xDFF6FF, 0xBFEFFF])      // console
        case (false, 2): (0x2E6A8A, [0x9FE0FF, 0xDFF6FF])     // tricorder
        case (false, _): (0x0E0F1C, pastel)                   // console, PADD
        }
        var images: [CGImage] = []
        let frames = activity == .typing || activity == .thinking ? 3 : (galaxy && device == 1 ? 2 : 1)
        for f in 0..<frames {
            guard let p = Pixels(width: 6, height: 4, scale: 2) else { break }
            if let back { p.fill(0, 0, 6, 4, back) }
            if galaxy && device == 1 {
                // A little blue figure flickering in a cone of light.
                p.polygon([(1.5, 4), (4.5, 4), (5.5, 0), (0.5, 0)], NSColor(hex: 0x6EC8F5).withAlphaComponent(0.2))
                let alpha = f % 2 == 0 ? 0.85 : 0.6
                p.ellipse(2.4, 0.3, 1.2, 1.2, NSColor(hex: 0x9FE0FF).withAlphaComponent(alpha))
                p.round(2.1, 1.4, 1.8, 2.4, radius: 0.6, NSColor(hex: 0x9FE0FF).withAlphaComponent(alpha))
            } else {
                switch activity {
                case .typing:
                    for k in 0..<2 { p.fill(1, 1 + Double(k) * 1.6, Double(1 + (f + k * 2) % 4), 0.8, ink[(f + k) % ink.count]) }
                case .thinking:
                    p.fill(1 + Double(f) * 1.5, 1.6, 0.9, 0.9, ink[0])
                default:
                    p.fill(1, 1, 2.5, 0.7, ink[0]); p.fill(1, 2.2, 1.6, 0.7, ink[1 % ink.count])
                }
            }
            if let image = p.image { images.append(image) }
        }
        cache[key] = images
        return images
    }
}

private extension NSColor {
    /// The colour as 0xRRGGBB.
    var hexValue: UInt32 {
        guard let rgb = usingColorSpace(.sRGB) else { return 0xD97757 }
        return UInt32(rgb.redComponent * 255) << 16 | UInt32(rgb.greenComponent * 255) << 8 | UInt32(rgb.blueComponent * 255)
    }
}

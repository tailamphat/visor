import AppKit
import VisorCore

/// The break corner's game as Core Animation: the ball, the pieces, the cards
/// and chips, the darts, and a "+1" over each round's winner. Every moving bit
/// is sampled once into one keyframe loop that holds every round, so the window
/// server repeats it with no work from the app.
enum BreakProps {
    static let fps = 12.0

    /// Where a bit is in room pixels (its top-left corner), how visible, and its colour if it changes.
    struct Frame {
        var x: Double, y: Double
        var alpha = 1.0
        var color: UInt32?
    }

    /// The game's layers: one just over the table, one over everyone for the pops.
    static func layers(_ game: BreakGame, players: Int, layout: OfficeLayout, scale s: CGFloat, textScale: CGFloat, begin: CFTimeInterval) -> [CALayer] {
        let table = CALayer(), top = CALayer()
        for root in [table, top] {
            root.frame = CGRect(x: 0, y: 0, width: OfficeLayout.width * s, height: layout.height * s)
            root.anchorPoint = .zero
            root.position = .zero
        }
        // Over the table, under whoever stands at it; the pops over everyone.
        table.zPosition = CGFloat(layout.stationTop + 14.5)
        top.zPosition = 9000
        let kit = Kit(layout: layout, s: s, textScale: textScale, begin: begin, loop: game.loop(players: players), table: table, top: top)
        switch game {
        case .pingPong: pingPong(kit)
        case .holochess: holochess(kit, players: players)
        case .poker: poker(kit, players: players)
        case .darts: darts(kit)
        }
        return [table, top]
    }

    /// The winner's cheer: a few quick hops in each round it wins.
    static func hop(_ game: BreakGame, player: Int, players: Int, scale s: CGFloat, begin: CFTimeInterval) -> CAAnimation? {
        let winners = game.winners(players: players)
        guard winners.contains(player) else { return nil }
        let loop = game.loop(players: players), count = Int(loop * fps)
        let values: [NSNumber] = (0..<count).map { i in
            let t = Double(i) / fps, round = Int(t / game.round), age = t - Double(round) * game.round - game.winAt
            guard winners[round % winners.count] == player, age >= 0, age < BreakGame.cheer else { return 0 }
            return NSNumber(value: abs(sin(age * 9)) * 3 * Double(s))
        }
        return discrete("transform.translation.y", values, loop: loop, begin: begin)
    }

    // MARK: Games

    /// The ball rallies over the net until someone misses; the paddles lift as they hit.
    private static func pingPong(_ kit: Kit) {
        let brk = OfficeLayout.sofaX, t = kit.layout.stationTop, game = BreakGame.pingPong
        let left = brk - 7.5, right = brk + 6, stroke = 0.55
        // The winner's opponent misses: rallies of 6 end on the right, of 7 on the left.
        func rally(_ round: Int) -> Int { game.winners(players: 2)[round % 2] == 0 ? 6 : 7 }
        kit.add(w: 1.5, h: 1.5, color: 0xFFF6E0, on: kit.table) { time in
            let round = Int(time / game.round), rt = time - Double(round) * game.round
            let n = rally(round), k = Int(rt / stroke), f = rt / stroke - Double(k)
            let rightward = k % 2 == 0, span = right - left
            if k < n {
                return Frame(x: rightward ? left + span * f : right - span * f, y: t + 6 - 6 * sin(.pi * f))
            }
            if k == n {
                let x = rightward ? left + (span + 10) * f : right - (span + 10) * f
                return Frame(x: x, y: t + 6 - 6 * sin(.pi * min(f, 0.6)) + max(0, f - 0.6) * 25)
            }
            return Frame(x: brk, y: t + 6, alpha: 0)
        }
        for (side, x, color) in [(0, brk - 9.5, UInt32(0xC8423A)), (1, brk + 6.5, UInt32(0x3A6BC8))] {
            kit.add(w: 3, h: 3, color: color, on: kit.table) { time in
                let round = Int(time / game.round), rt = time - Double(round) * game.round
                let k = Int(rt / stroke), f = rt / stroke - Double(k)
                let hits = k <= rally(round) && k % 2 == side && f < 0.25
                return Frame(x: x + (hits ? (side == 0 ? 1 : -1) : 0), y: t + (hits ? 3.5 : 6))
            }
        }
        kit.pops(game, players: 2) { _ in ("+1", 0x7EE0A0) }
    }

    /// Little monsters hop around the board; one is taken in a flicker and the round's winner cheers.
    private static func holochess(_ kit: Kit, players: Int) {
        let brk = OfficeLayout.sofaX, t = kit.layout.stationTop, game = BreakGame.holochess, hop = 1.1
        let pieces: [(start: Int, color: UInt32)] = [(0, 0x7CD0F5), (2, 0xF2B0D8), (4, 0x9FE0A8), (6, 0xF2C14E)]
        for (i, piece) in pieces.enumerated() {
            let layer = kit.add(w: 2, h: 3, color: piece.color, on: kit.table) { time in
                let round = Int(time / game.round), rt = time - Double(round) * game.round
                let k = Int(rt / hop), f = rt / hop - Double(k)
                let moving = k % 4 == i, step = moving ? min(1, f * 1.5) : 0
                let slot = Double(piece.start + (k + 3 - i) / 4) + step
                let a = slot / 8 * 2 * .pi
                let lift = moving ? sin(.pi * step) * 3 : 0
                var frame = Frame(x: brk + cos(a) * 7 - 1, y: t + 7.2 + sin(a) * 2.4 - 3 - lift, alpha: 0.9)
                if round % 4 == i && rt > 5.5 { frame.alpha = rt > game.winAt ? 0 : (Int(time * fps) % 2 == 0 ? 0.2 : 1) }
                return frame
            }
            layer.cornerRadius = 0.8 * kit.s
            layer.shadowColor = NSColor(hex: piece.color).cgColor
            layer.shadowOpacity = 0.9
            layer.shadowRadius = 2
            layer.shadowOffset = .zero
        }
        kit.pops(game, players: players) { _ in ("+1", 0x9FE0FF) }
    }

    /// Cards dealt, chips into the pot, hands shown, the pot slides to the winner.
    private static func poker(_ kit: Kit, players: Int) {
        let brk = OfficeLayout.sofaX, t = kit.layout.stationTop, game = BreakGame.poker
        let winners = game.winners(players: players)
        let seats = [(brk - 8, t + 4.5), (brk + 4, t + 4.5), (brk - 2, t + 8)].prefix(players)
        let deck = (brk - 1, t + 3.0)
        for (i, seat) in seats.enumerated() {
            for j in 0..<2 {
                let start = Double(i * 2 + j) * 0.3
                kit.add(w: 2, h: 2.6, color: 0x5A8FD0, on: kit.table) { time in
                    let rt = time.truncatingRemainder(dividingBy: game.round)
                    guard rt >= start, rt < game.round - 0.3 else { return Frame(x: deck.0, y: deck.1, alpha: 0) }
                    let f = min(1, (rt - start) / 0.3)
                    return Frame(x: deck.0 + (seat.0 + Double(j) * 2.5 - deck.0) * f, y: deck.1 + (seat.1 - deck.1) * f,
                                 color: rt > 5 ? 0xF4F1EA : 0x5A8FD0)
                }
            }
        }
        let colors: [UInt32] = [0xC8463C, 0xE8C46A, 0x5A8FD0]
        for c in 0..<(seats.count * 2) {
            let from = seats[seats.startIndex + c % seats.count], start = 2 + Double(c) * 0.45
            kit.add(w: 1.6, h: 0.8, color: colors[c % 3], on: kit.table) { time in
                let round = Int(time / game.round), rt = time - Double(round) * game.round
                guard rt >= start, rt < game.round - 0.3 else { return Frame(x: from.0, y: from.1, alpha: 0) }
                var pot = (brk - 2 + Double(c % 3) * 1.6, t + 6 - Double(c / 3) * 0.7)
                if rt > game.winAt {
                    let won = seats[seats.startIndex + winners[round % winners.count]], f = min(1, (rt - game.winAt) / 0.6)
                    pot = (pot.0 + (won.0 + 1 - pot.0) * f, pot.1 + (won.1 + 3 - pot.1) * f)
                }
                let f = min(1, (rt - start) / 0.4), origin = (from.0 + 1, from.1 + 3)
                return Frame(x: origin.0 + (pot.0 - origin.0) * f, y: origin.1 + (pot.1 - origin.1) * f)
            }
        }
        let hands = ["Full house", "Flush", "Two pair"]
        kit.pops(game, players: players) { round in (hands[round % hands.count], 0xE8C46A) }
    }

    /// Three darts at a board behind the table, each score popping, then a cheer.
    private static func darts(_ kit: Kit) {
        let brk = OfficeLayout.sofaX, t = kit.layout.stationTop, game = BreakGame.darts, throwTime = 1.3
        let center = (brk + 15.5, t - 4.5)
        let board = CALayer()
        board.contents = dartBoard()
        board.magnificationFilter = .nearest
        board.anchorPoint = .zero
        board.frame = CGRect(x: (center.0 - 4.5) * kit.s, y: (kit.layout.height - center.1 - 4.5) * kit.s, width: 9 * kit.s, height: 9 * kit.s)
        kit.table.addSublayer(board)
        let hand = (brk - 10, t + 6.0)
        let hits = [(center.0 + 1, center.1 - 2), (center.0 - 2, center.1 + 1), (center.0, center.1)]
        for (k, hit) in hits.enumerated() {
            kit.add(w: 2.5, h: 0.8, color: 0xB0B0B0, on: kit.table) { time in
                let rt = time.truncatingRemainder(dividingBy: game.round), f = rt / throwTime - Double(k)
                guard f >= 0.25, rt < game.round - 0.4 else { return Frame(x: hand.0, y: hand.1, alpha: 0) }
                let g = min(1, (f - 0.25) / 0.3)
                return Frame(x: hand.0 + (hit.0 - 2.5 - hand.0) * g, y: hand.1 + (hit.1 - hand.1) * g - sin(.pi * g) * 6)
            }
        }
        for (k, score) in [("T20", UInt32(0xF2F1EC)), ("5", 0xF2F1EC), ("BULL!", 0x7EE0A0)].enumerated() {
            kit.pop(score.0, color: score.1, x: center.0, y: center.1 - 10, at: (Double(k) + 0.55) * throwTime)
        }
        kit.pop("+1", color: 0x7EE0A0, x: brk - 15, y: t - 6, at: game.winAt)
    }

    private static func dartBoard() -> CGImage? {
        guard let p = Pixels(width: 9, height: 9, scale: 4) else { return nil }
        for (r, color) in [(4.5, UInt32(0x1B1B1F)), (3.8, 0xE9E3C8), (3.1, 0xC8423A), (2.4, 0xE9E3C8), (1.5, 0x2E8B57), (0.7, 0xC8423A)] {
            p.ellipse(4.5 - r, 4.5 - r, 2 * r, 2 * r, NSColor(hex: color))
        }
        return p.image
    }

    // MARK: Kit

    /// What every game draws with: room pixels in, keyframe loops out.
    private struct Kit {
        let layout: OfficeLayout
        let s: CGFloat
        let textScale: CGFloat
        let begin: CFTimeInterval
        let loop: Double
        let table: CALayer
        let top: CALayer

        /// A small coloured bit that moves by `frame`, sampled at `fps`.
        @discardableResult
        func add(w: Double, h: Double, color: UInt32, on root: CALayer, _ frame: (Double) -> Frame) -> CALayer {
            let layer = CALayer()
            layer.backgroundColor = NSColor(hex: color).cgColor
            layer.bounds = CGRect(x: 0, y: 0, width: w * s, height: h * s)
            layer.anchorPoint = .zero
            root.addSublayer(layer)
            animate(layer, h: h, frame)
            return layer
        }

        func animate(_ layer: CALayer, h: Double, _ frame: (Double) -> Frame) {
            let frames = (0..<Int(loop * fps)).map { frame(Double($0) / fps) }
            guard let first = frames.first else { return }
            func point(_ f: Frame) -> NSValue { NSValue(point: CGPoint(x: f.x * s, y: (layout.height - f.y - h) * s)) }
            layer.position = point(first).pointValue
            layer.opacity = Float(first.alpha)
            for anim in [discrete("position", frames.map(point), loop: loop, begin: begin),
                         discrete("opacity", frames.map { NSNumber(value: $0.alpha) }, loop: loop, begin: begin)] {
                layer.add(anim, forKey: anim.keyPath)
            }
            if frames.contains(where: { $0.color != nil }) {
                let colors = frames.map { NSColor(hex: $0.color ?? 0).cgColor }
                layer.add(discrete("backgroundColor", colors, loop: loop, begin: begin), forKey: "color")
            }
        }

        /// Words rising over a spot from `at` seconds into the loop, then fading.
        func pop(_ text: String, color: UInt32, x: Double, y: Double, at start: Double) {
            let layer = CATextLayer()
            layer.string = text
            layer.font = NSFont.systemFont(ofSize: 7.5, weight: .heavy)
            layer.fontSize = 7.5
            layer.alignmentMode = .center
            layer.foregroundColor = NSColor(hex: color).cgColor
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 1
            layer.shadowRadius = 1.2
            layer.shadowOffset = .zero
            layer.contentsScale = textScale
            let w = 60 / Double(s), h = 10 / Double(s)
            layer.bounds = CGRect(x: 0, y: 0, width: 60, height: 10)
            layer.anchorPoint = .zero
            top.addSublayer(layer)
            animate(layer, h: h) { time in
                let age = time - start
                guard age >= 0, age < 1.4 else { return Frame(x: x - w / 2, y: y, alpha: 0) }
                return Frame(x: x - w / 2, y: y - age * 3, alpha: min(1, 2 * (1.4 - age)))
            }
        }

        /// A pop over each round's winner.
        func pops(_ game: BreakGame, players: Int, _ text: (Int) -> (String, UInt32)) {
            let brk = OfficeLayout.sofaX, t = layout.stationTop
            let heads = [(brk - 15, t - 6), (brk + 14, t - 6), (brk, t + 3)]
            for (round, winner) in game.winners(players: players).enumerated() {
                let (words, color) = text(round), head = heads[winner]
                pop(words, color: color, x: head.0, y: head.1, at: Double(round) * game.round + game.winAt)
            }
        }
    }

    private static func discrete(_ keyPath: String, _ values: [Any], loop: Double, begin: CFTimeInterval) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: keyPath)
        anim.values = values
        anim.calculationMode = .discrete
        anim.duration = loop
        anim.repeatCount = .infinity
        anim.beginTime = begin
        anim.fillMode = .backwards
        anim.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 12)
        return anim
    }
}

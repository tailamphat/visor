import AppKit
import SwiftUI
import VisorCore

final class OfficeLayerView: NSView {
    var focus: ((AgentSession) -> Void)?
    private let s = CGFloat(OfficeView.scale)
    private var scene: OfficeScene?
    private var world: OfficeWorld = .studio
    private var sessions: [String: AgentSession] = [:]
    private let room = CALayer()
    /// What the room image was last drawn for.
    private struct RoomKey: Equatable {
        var world: OfficeWorld
        var layout: OfficeLayout
        var waiting: Bool
    }
    private var drawnRoom: RoomKey?
    /// The break corner's game, rebuilt only when who plays (or the room) changes.
    private var game: (key: String, layers: [CALayer])?
    /// The web station's hologram: two rings turning opposite ways.
    private let rings = [CALayer(), CALayer()]
    private var labels: [CALayer] = []
    private var people: [String: Person] = [:]
    private var tip: CALayer?
    private var hovered: String?

    private final class Person {
        /// Walks; holds the shadow, the sprite, the bubble and the name.
        let body = CALayer()
        let sprite = CALayer()
        let shade = CALayer()
        let screen = CALayer()
        let bubble = CALayer()
        let glyph = CATextLayer()
        let tag = CATextLayer()
        /// How long it has waited for you, under its name at your desk.
        let clock = CATextLayer()
        /// How full its context is, a bar over its head like a health bar.
        let health = CALayer()
        let healthFill = CALayer()
        /// Its running subagents: small copies of it at its side, by helper id; and "+n" past three.
        var helpers: [String: CALayer] = [:]
        let moreHelpers = CATextLayer()
        var agent: OfficeAgent
        let look: PixelPerson.Look
        init(_ agent: OfficeAgent, look: PixelPerson.Look) {
            self.agent = agent
            self.look = look
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        for layer in [room] {
            layer.magnificationFilter = .nearest
            layer.anchorPoint = .zero
            self.layer?.addSublayer(layer)
        }
        for (i, ring) in rings.enumerated() {
            ring.contents = OfficeRoom.ring(outer: i == 0)
            ring.bounds = CGRect(x: 0, y: 0, width: 20 * s, height: 20 * s)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.byValue = i == 0 ? -2 * Double.pi : 2 * Double.pi
            spin.duration = i == 0 ? 9 : 5
            spin.repeatCount = .infinity
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
            ring.add(spin, forKey: "spin")
            self.layer?.addSublayer(ring)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Scene

    func show(_ placed: OfficeScene, sessions list: [AgentSession], world nextWorld: OfficeWorld) {
        // Whoever's on break plays at the game table instead of sitting on a sofa.
        let next = placed.aroundTheTable()
        sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if nextWorld != world {
            // Another world: a new room and a new cast, placed at once.
            world = nextWorld
            scene = nil
            for person in people.values { [person.body, person.screen].forEach { $0.removeFromSuperlayer() } }
            people = [:]
        }
        let old = scene
        guard next != old else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            people.values.forEach(showHelpers)
            CATransaction.commit()
            return
        }
        scene = next
        let layout = next.layout
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        room.frame = CGRect(x: 0, y: 0, width: OfficeLayout.width * s, height: layout.height * s)
        // The room is drawn in software; it only changes with the world, the tables and whether anyone waits.
        let roomKey = RoomKey(world: world, layout: layout, waiting: next.waiting > 0)
        if roomKey != drawnRoom {
            room.contents = OfficeRoom.image(next, world: world)
            drawnRoom = roomKey
        }
        for ring in rings {
            // The studio's hologram; the film worlds draw their own web station.
            ring.isHidden = world != .studio
            ring.position = point(OfficePoint(x: OfficeLayout.webX, y: layout.stationTop + 9), in: layout)
            ring.zPosition = CGFloat(layout.stationTop + 9)
        }
        if old?.layout != layout || old?.hidden != next.hidden { buildLabels(next) }
        // A taller or shorter room, or tables moving, moves everyone: place them at once rather than walk.
        let snap = old?.layout != layout
        let ids = Set(next.agents.map(\.id))
        for (id, person) in people where !ids.contains(id) {
            [person.body, person.screen].forEach { $0.removeFromSuperlayer() }
            people[id] = nil
        }
        for agent in next.agents {
            if let person = people[agent.id] {
                let before = person.agent
                person.agent = agent
                if before.feet != agent.feet && !snap { walk(person, from: before.access, to: agent, in: layout) }
                else if before != agent || snap { settle(person, in: layout) }
            } else {
                let person = Person(agent, look: PixelPerson.look(for: agent, world: world, figure: figure(for: agent.id)))
                people[agent.id] = person
                build(person)
                if old == nil || snap { settle(person, in: layout) }
                else {
                    // A new session walks in from the right edge.
                    person.body.position = point(OfficePoint(x: OfficeLayout.width + 6, y: layout.corridor), in: layout)
                    walk(person, from: layout.corridor, to: agent, in: layout)
                }
            }
            placeScreen(people[agent.id]!, in: layout)
        }
        // Who else is at a spot decides whether a name fits.
        for person in people.values {
            person.tag.isHidden = !showsName(person.agent) && hovered != person.agent.id
            showHealth(person)
            showHelpers(person)
        }
        tickClocks()
        showGame(next)
        CATransaction.commit()
        if let hovered, let person = people[hovered] { showTip(person) } else { hideTip() }
    }

    /// Starts the break game for whoever's at the table: darts alone, the world's
    /// game together, with a hop for each round's winner.
    private func showGame(_ scene: OfficeScene) {
        let players = scene.agents.filter { $0.spot == .sofa }.prefix(OfficeLayout.sofaSeats)
        let kind = BreakGame.pick(world: world, players: players.count)
        let key = "\(world)-\(kind?.rawValue ?? "none")-\(players.map(\.id))-\(scene.layout.height)"
        guard key != game?.key else { return }
        game?.layers.forEach { $0.removeFromSuperlayer() }
        people.values.forEach { $0.sprite.removeAnimation(forKey: "hop") }
        game = nil
        guard let kind else { return }
        // A moment for them to walk over before the first round.
        let begin = CACurrentMediaTime() + 1.5
        let layers = BreakProps.layers(kind, players: players.count, layout: scene.layout, scale: s,
                                       textScale: window?.backingScaleFactor ?? 2, begin: begin)
        layers.forEach { layer?.addSublayer($0) }
        for (i, agent) in players.enumerated() {
            if let hop = BreakProps.hop(kind, player: i, players: players.count, scale: s, begin: begin) {
                people[agent.id]?.sprite.add(hop, forKey: "hop")
            }
        }
        game = (key, layers)
    }

    /// A film world's character for a new session: its own, unless someone in
    /// the room already plays it.
    private func figure(for id: String) -> PixelPerson.Figure? {
        let cast = PixelPerson.Figure.cast(world)
        guard !cast.isEmpty else { return nil }
        let taken = Set(people.values.compactMap { $0.look.figure }.compactMap { cast.firstIndex(of: $0) })
        return cast[OfficeCast.pick(id: id, count: cast.count, taken: taken)]
    }

    /// Room pixels (y down) to layer points (y up).
    private func point(_ p: OfficePoint, in layout: OfficeLayout) -> CGPoint {
        CGPoint(x: p.x * s, y: (layout.height - p.y) * s)
    }

    private func build(_ person: Person) {
        let scale = window?.backingScaleFactor ?? 2
        let body = person.body
        body.bounds = CGRect(x: 0, y: 0, width: PixelPerson.width * s, height: PixelPerson.height * s)
        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(body)
        // A soft shadow at the feet, under the sprite.
        person.shade.frame = CGRect(x: body.bounds.midX - 8, y: -2.5, width: 16, height: 5)
        person.shade.cornerRadius = OfficeArt.shadeRadius
        person.shade.backgroundColor = NSColor.black.withAlphaComponent(OfficeArt.shadeStrength).cgColor
        if person.look.figure != nil {
            // Film characters keep their costume, so a ring at their feet says whose session it is.
            let color = AgentStyle.mark(person.agent.agent)
            person.shade.backgroundColor = color.withAlphaComponent(OfficeArt.shadeStrength).cgColor
            person.shade.borderColor = color.cgColor
            person.shade.borderWidth = 1
        }
        body.addSublayer(person.shade)
        person.sprite.frame = body.bounds
        person.sprite.magnificationFilter = .nearest
        body.addSublayer(person.sprite)

        person.screen.magnificationFilter = .nearest
        person.screen.anchorPoint = .zero
        layer?.addSublayer(person.screen)

        person.bubble.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        person.bubble.cornerRadius = OfficeArt.bubbleRadius
        person.bubble.borderColor = NSColor.black.cgColor
        person.glyph.frame = CGRect(x: 0, y: 1, width: 14, height: 12)
        person.glyph.alignmentMode = .center
        person.glyph.contentsScale = scale
        person.bubble.addSublayer(person.glyph)
        body.addSublayer(person.bubble)

        person.tag.string = person.agent.project
        person.tag.font = NSFont.systemFont(ofSize: OfficeArt.tagSize, weight: .semibold)
        person.tag.fontSize = OfficeArt.tagSize
        person.tag.alignmentMode = .center
        person.tag.truncationMode = .end
        person.tag.foregroundColor = OfficeArt.tagInk.cgColor
        person.tag.shadowColor = NSColor.black.cgColor
        person.tag.shadowOpacity = 1
        person.tag.shadowRadius = 1.5
        person.tag.shadowOffset = .zero
        person.tag.contentsScale = scale
        person.tag.frame = CGRect(x: body.bounds.midX - 40, y: -11, width: 80, height: 10)
        body.addSublayer(person.tag)

        person.clock.font = NSFont.monospacedDigitSystemFont(ofSize: OfficeArt.tagSize, weight: .semibold)
        person.clock.fontSize = OfficeArt.tagSize
        person.clock.alignmentMode = .center
        person.clock.foregroundColor = NSColor(Theme.warning).cgColor
        person.clock.shadowColor = NSColor.black.cgColor
        person.clock.shadowOpacity = 1
        person.clock.shadowRadius = 1.5
        person.clock.shadowOffset = .zero
        person.clock.contentsScale = scale
        person.clock.frame = CGRect(x: body.bounds.midX - 40, y: -21, width: 80, height: 10)
        body.addSublayer(person.clock)

        person.health.backgroundColor = OfficeArt.healthTrack.cgColor
        person.health.cornerRadius = OfficeArt.healthRadius
        person.healthFill.anchorPoint = .zero
        person.health.addSublayer(person.healthFill)
        body.addSublayer(person.health)
    }

    /// Helpers shown beside a parent; more running ones show as "+n".
    static let helperSeats = 3
    /// Where each helper stands, in room pixels right of its parent's feet, and their size.
    private static let helperOffsets: [CGFloat] = [8, 13, 18]
    private static let helperScale: CGFloat = 0.6

    /// Small copies of the person for its running subagents, at its side and
    /// moving with it. A helper that finishes hands over a sheet of paper and
    /// walks off to the right as it fades.
    private func showHelpers(_ person: Person) {
        let helpers = sessions[person.agent.id]?.helpers ?? []
        let running = helpers.filter { !$0.done }
        let shown = Array(running.prefix(Self.helperSeats))
        let shownIDs = Set(shown.map(\.id))
        for (id, layer) in person.helpers where !shownIDs.contains(id) {
            person.helpers[id] = nil
            if helpers.contains(where: { $0.id == id && $0.done }) { leave(layer, from: person) } else { layer.removeFromSuperlayer() }
        }
        let body = person.body
        let size = CGSize(width: PixelPerson.width * s * Self.helperScale, height: PixelPerson.height * s * Self.helperScale)
        let frames = PixelPerson.frames(person.look, pose: .typing, front: !person.agent.facesUp)
        for (i, helper) in shown.enumerated() {
            let layer = person.helpers[helper.id] ?? {
                let layer = CALayer()
                layer.magnificationFilter = .nearest
                layer.contents = frames.first
                if frames.count > 1 {
                    let loop = CAKeyframeAnimation(keyPath: "contents")
                    loop.values = frames
                    loop.calculationMode = .discrete
                    loop.duration = 0.4 + Double(i) * 0.05
                    loop.repeatCount = .infinity
                    loop.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 8, preferred: 6)
                    layer.add(loop, forKey: "loop")
                }
                layer.zPosition = -1
                body.insertSublayer(layer, at: 0)
                person.helpers[helper.id] = layer
                return layer
            }()
            layer.frame = CGRect(x: body.bounds.midX + Self.helperOffsets[i] * s - size.width / 2, y: 0, width: size.width, height: size.height)
        }
        let more = running.count - shown.count
        let tag = person.moreHelpers
        if more > 0 {
            if tag.superlayer == nil {
                tag.font = NSFont.systemFont(ofSize: OfficeArt.helperTagSize, weight: .bold)
                tag.fontSize = OfficeArt.helperTagSize
                tag.alignmentMode = .center
                tag.foregroundColor = OfficeArt.helperInk.cgColor
                tag.backgroundColor = NSColor.black.withAlphaComponent(OfficeArt.helperTagBacking).cgColor
                tag.cornerRadius = OfficeArt.helperTagRadius
                tag.contentsScale = window?.backingScaleFactor ?? 2
                body.addSublayer(tag)
            }
            tag.string = "+\(more)"
            tag.frame = CGRect(x: body.bounds.midX + (Self.helperOffsets.last! + 8) * s - 9, y: size.height - 2, width: 18, height: 10)
        } else {
            tag.removeFromSuperlayer()
        }
    }

    /// A finished helper: a sheet of paper flies to its parent, then it walks off and fades.
    private func leave(_ layer: CALayer, from person: Person) {
        let body = person.body
        let paper = CALayer()
        paper.backgroundColor = OfficeArt.paper.cgColor
        paper.cornerRadius = OfficeArt.paperRadius
        paper.bounds = CGRect(x: 0, y: 0, width: 4 * s / 2, height: 3 * s / 2)
        paper.position = CGPoint(x: layer.frame.midX, y: layer.frame.midY)
        paper.zPosition = 2
        body.addSublayer(paper)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            paper.removeFromSuperlayer()
            layer.removeFromSuperlayer()
        }
        let hand = CABasicAnimation(keyPath: "position")
        hand.toValue = NSValue(point: CGPoint(x: body.bounds.midX + 2 * s, y: body.bounds.midY))
        hand.duration = 0.45
        hand.fillMode = .forwards
        hand.isRemovedOnCompletion = false
        paper.add(hand, forKey: "hand")
        let fadePaper = CABasicAnimation(keyPath: "opacity")
        fadePaper.fromValue = 1
        fadePaper.toValue = 0
        fadePaper.beginTime = CACurrentMediaTime() + 0.45
        fadePaper.duration = 0.2
        fadePaper.fillMode = .both
        fadePaper.isRemovedOnCompletion = false
        paper.add(fadePaper, forKey: "fade")
        let away = CABasicAnimation(keyPath: "position.x")
        away.byValue = 20 * s
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [away, fade]
        group.beginTime = CACurrentMediaTime() + 0.35
        group.duration = 0.9
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "leave")
        CATransaction.commit()
    }

    /// Puts a person where it belongs and starts what it does there.
    private func settle(_ person: Person, in layout: OfficeLayout) {
        person.body.removeAnimation(forKey: "walk")
        person.sprite.removeAnimation(forKey: "steps")
        person.body.position = point(person.agent.feet, in: layout)
        person.body.zPosition = CGFloat(person.agent.feet.y)
        startActivity(person, after: 0)
    }

    /// Walks from wherever the person is now, around the tables.
    private func walk(_ person: Person, from line: Double, to agent: OfficeAgent, in layout: OfficeLayout) {
        let body = person.body
        let now = body.presentation()?.position ?? body.position
        let from = OfficePoint(x: now.x / s, y: layout.height - now.y / s)
        let stops = [from] + layout.route(from: from, access: line, to: agent.feet, access: agent.access)
        var distances = [0.0]
        for i in stops.indices.dropFirst() {
            distances.append(distances[i - 1] + hypot(stops[i].x - stops[i - 1].x, stops[i].y - stops[i - 1].y))
        }
        let total = distances.last ?? 0
        guard total > 0.5 else { return settle(person, in: layout) }
        let duration = total / 44
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = stops.map { NSValue(point: point($0, in: layout)) }
        move.keyTimes = distances.map { NSNumber(value: $0 / total) }
        move.duration = duration
        move.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
        body.position = point(agent.feet, in: layout)
        body.zPosition = CGFloat(agent.feet.y)
        body.add(move, forKey: "walk")

        let up = agent.feet.y < from.y - 2
        let steps = CAKeyframeAnimation(keyPath: "contents")
        steps.values = PixelPerson.frames(person.look, pose: .walk, front: !up)
        steps.calculationMode = .discrete
        steps.duration = 0.32
        steps.repeatCount = Float(duration / 0.32)
        steps.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 8, preferred: 6)
        person.sprite.add(steps, forKey: "steps")
        startActivity(person, after: duration)
    }

    /// The person's loop where it is (typing, waving, dozing) and its bubble.
    private func startActivity(_ person: Person, after delay: CFTimeInterval) {
        let agent = person.agent
        var (pose, period) = PixelPerson.pose(for: agent)
        // At the game table: cards or pieces in hand, unless it's darts alone.
        if agent.spot == .sofa && (scene?.agents.filter { $0.spot == .sofa }.count ?? 0) > 1 { (pose, period) = (.playing, 4) }
        let frames = PixelPerson.frames(person.look, pose: pose, front: !agent.facesUp)
        let sprite = person.sprite
        sprite.contents = frames.first
        sprite.removeAnimation(forKey: "loop")
        if frames.count > 1 {
            let loop = CAKeyframeAnimation(keyPath: "contents")
            loop.values = frames
            loop.calculationMode = .discrete
            loop.duration = period
            loop.repeatCount = .infinity
            loop.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
            loop.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 8, preferred: 6)
            sprite.add(loop, forKey: "loop")
        }
        // The agent ring stays under film characters when they sit, as in the mockup.
        person.shade.isHidden = agent.sits && person.look.figure == nil
        person.tag.isHidden = !showsName(agent) && hovered != agent.id
        styleBubble(person, delay: delay)
    }

    /// "!", "?", "✓", "…" or "zZ", beside the head so the screen stays visible.
    private func styleBubble(_ person: Person, delay: CFTimeInterval) {
        let agent = person.agent
        let bubble = person.bubble
        bubble.removeAllAnimations()
        let style: (text: String, fill: NSColor?, ink: NSColor)?
        switch agent.activity {
        case .approval: style = ("!", NSColor(Theme.warning), .black)
        case .question: style = ("?", NSColor(Theme.question), .white)
        case .done: style = ("✓", OfficeArt.doneFill, .white)
        case .thinking: style = ("…", OfficeArt.thinkingFill, OfficeArt.thinkingInk)
        case .idle: style = ("zZ", nil, OfficeArt.idleInk)
        default: style = nil
        }
        guard let style else { bubble.isHidden = true; return }
        bubble.isHidden = false
        if delay > 0 {
            // Hidden while walking, shown once there.
            let wait = CABasicAnimation(keyPath: "hidden")
            wait.fromValue = true
            wait.toValue = true
            wait.duration = delay
            bubble.add(wait, forKey: "wait")
        }
        bubble.backgroundColor = style.fill?.cgColor
        bubble.borderWidth = style.fill == nil ? 0 : 1.5
        person.glyph.string = style.text
        person.glyph.foregroundColor = style.ink.cgColor
        let size = style.fill == nil ? OfficeArt.idleGlyphSize : OfficeArt.glyphSize
        person.glyph.font = NSFont.systemFont(ofSize: size, weight: .bold)
        person.glyph.fontSize = size
        let sink: CGFloat = agent.sits ? 3 * s : 0
        let base = CGPoint(x: person.body.bounds.midX + 5 * s + 7, y: (PixelPerson.headTop - 3) * s - sink)
        bubble.position = base
        if agent.activity == .approval || agent.activity == .question {
            let bob = CAKeyframeAnimation(keyPath: "position.y")
            bob.values = [base.y, base.y + 2]
            bob.calculationMode = .discrete
            bob.duration = 1
            bob.repeatCount = .infinity
            bob.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 4, preferred: 2)
            bubble.add(bob, forKey: "bob")
        }
    }

    /// The person's screen: lines while it types, a moving dot while it thinks, a
    /// dot in its colour while it's away.
    private func placeScreen(_ person: Person, in layout: OfficeLayout) {
        let screen = person.screen
        let at = person.agent.screen
        screen.frame = CGRect(x: at.x * s, y: (layout.height - at.y - 4) * s, width: 6 * s, height: 4 * s)
        screen.zPosition = CGFloat(at.y)
        let atDesk = person.agent.spot == .desk
        let frames = PixelPerson.screen(person.look, activity: atDesk ? person.agent.activity : nil, device: FilmRoom.device(at: at))
        screen.removeAnimation(forKey: "screen")
        screen.contents = frames.first
        guard frames.count > 1 else { return }
        let loop = CAKeyframeAnimation(keyPath: "contents")
        loop.values = frames
        loop.calculationMode = .discrete
        loop.duration = Double(frames.count) * 0.25
        loop.repeatCount = .infinity
        loop.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 6, preferred: 4)
        screen.add(loop, forKey: "screen")
    }

    /// Names show for whoever waits for you, and for anyone alone at a station;
    /// at tables and in a crowd they show on hover, so nothing overlaps.
    /// The bar over the head: how full the context is, amber from 80% when it's about to compact.
    private func showHealth(_ person: Person) {
        guard let percent = person.agent.context else { person.health.isHidden = true; return }
        let sink: CGFloat = person.agent.sits ? 3 * s : 0
        let width: CGFloat = 12 * s
        person.health.isHidden = false
        person.health.frame = CGRect(x: person.body.bounds.midX - width / 2, y: (PixelPerson.headTop + 2) * s - sink, width: width, height: 3 * s)
        person.healthFill.frame = CGRect(x: s, y: s, width: max(1, (width - 2 * s) * CGFloat(min(percent, 100)) / 100), height: s)
        person.healthFill.backgroundColor = NSColor(SessionText.contextHigh(Double(percent)) ? Theme.warning : Theme.question).cgColor
    }

    /// Ticks once a second while anyone waits at your desk, and only then.
    private var ticker: Timer?

    private func tickClocks() {
        let waiting = people.values.filter { $0.agent.spot == .you }
        for person in people.values where person.agent.spot != .you { person.clock.isHidden = true }
        guard !waiting.isEmpty, window != nil else { ticker?.invalidate(); ticker = nil; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for person in waiting {
            person.clock.isHidden = false
            person.clock.string = SessionText.elapsed(since: person.agent.since)
        }
        CATransaction.commit()
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickClocks() }
            }
            ticker?.tolerance = 0.2
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ticker?.invalidate(); ticker = nil } else { tickClocks() }
    }

    private func showsName(_ agent: OfficeAgent) -> Bool {
        switch agent.spot {
        case .you: return true
        case .desk, .sofa: return false
        case .terminal, .docs, .web: return (scene?.agents.filter { $0.spot == agent.spot }.count ?? 0) == 1
        }
    }

    // MARK: Labels

    private func text(_ string: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold) -> CATextLayer {
        let label = CATextLayer()
        label.string = string
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.fontSize = size
        label.foregroundColor = color.cgColor
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.truncationMode = .end
        label.zPosition = 1000
        return label
    }

    /// Each table's tool above it: "CLAUDE CODE · 3", or just the name, or
    /// the tool's mark when the table is too narrow for words.
    private func buildLabels(_ scene: OfficeScene) {
        labels.forEach { $0.removeFromSuperlayer() }
        labels = []
        let layout = scene.layout
        for island in layout.islands {
            let color = AgentStyle.mark(island.agent)
            let width = island.width * s - 4
            let x = (island.x + 1) * s
            // Above the table, clear of the context bars over the top row's heads.
            let top = (layout.height - island.y + 15) * s
            let font = NSFont.systemFont(ofSize: OfficeArt.tableLabelSize, weight: .bold)
            let fits = { (name: String) in NSAttributedString(string: name, attributes: [.font: font]).size().width <= width }
            // More sessions than seats: the rest are counted on the label ("· 28 +20").
            let extra = island.total > island.seats ? " +\(island.total - island.seats)" : ""
            let name = [island.total > 1 ? "\(island.agent.uppercased()) · \(island.total)\(extra)" : nil,
                        island.total > 1 ? "\(island.agent.uppercased()) · \(island.total)" : nil, island.agent.uppercased()]
                .compactMap { $0 }.first(where: fits)
            if let name {
                let label = text(name, size: OfficeArt.tableLabelSize, color: color, weight: .bold)
                label.frame = CGRect(x: x, y: top - 10, width: width, height: 9)
                labels.append(label)
            } else {
                let mark = CAShapeLayer()
                var transform = CGAffineTransform(translationX: x, y: top - 2).scaledBy(x: 8 / 24, y: -8 / 24)
                mark.path = AgentLogo.path(for: island.agent).copy(using: &transform)
                mark.fillColor = color.cgColor
                mark.zPosition = 1000
                labels.append(mark)
            }
        }
        let stations: [(String, Double, Double)] = [
            ("TERMINAL", OfficeLayout.terminalX, layout.corridor + 1), ("DOCS", OfficeLayout.docsX, layout.corridor + 1),
            ("YOU", OfficeLayout.youX, layout.stationTop + 18), ("WEB", OfficeLayout.webX, layout.corridor + 1),
            ("BREAK", OfficeLayout.sofaX, layout.corridor + 1),
        ]
        for (name, x, top) in stations {
            let label = text(name, size: OfficeArt.stationLabelSize, color: OfficeArt.stationInk)
            label.alignmentMode = .center
            label.frame = CGRect(x: CGFloat(x) * s - 30, y: CGFloat(layout.height - top) * s - 8, width: 60, height: 8)
            labels.append(label)
        }
        labels.forEach { layer?.addSublayer($0) }
    }

    // MARK: Pointer

    private func person(at event: NSEvent) -> Person? {
        guard let scene else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let room = OfficePoint(x: p.x / s, y: scene.layout.height - p.y / s)
        var best: Person?
        var distance = 9.0
        for person in people.values {
            let now = person.body.presentation()?.position ?? person.body.position
            let feet = OfficePoint(x: now.x / s, y: scene.layout.height - now.y / s)
            let d = hypot(feet.x - room.x, feet.y - 6 - room.y)
            if d < distance { distance = d; best = person }
        }
        return best
    }

    override func mouseMoved(with event: NSEvent) {
        let found = person(at: event)
        guard found?.agent.id != hovered else { return }
        if let old = hovered.flatMap({ people[$0] }) { old.tag.isHidden = !showsName(old.agent) }
        hovered = found?.agent.id
        if let found { found.tag.isHidden = false; showTip(found) } else { hideTip() }
        if found != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if let old = hovered.flatMap({ people[$0] }) { old.tag.isHidden = !showsName(old.agent) }
        hovered = nil
        hideTip()
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let found = person(at: event), let session = sessions[found.agent.id] else { return }
        focus?(session)
    }

    // MARK: Tooltip

    private func hideTip() {
        tip?.removeFromSuperlayer()
        tip = nil
    }

    /// Project, agent and app, what it's doing, and how full its context is.
    private func showTip(_ person: Person) {
        hideTip()
        guard let session = sessions[person.agent.id] else { return }
        let lines = NSMutableAttributedString()
        func add(_ string: String, _ step: DS.TypeStep, _ weight: NSFont.Weight, _ color: NSColor) {
            lines.append(NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: step.points, weight: weight), .foregroundColor: color]))
        }
        let muted = NSColor(Theme.textMuted), warning = NSColor(Theme.warning)
        add(session.project, .md, .semibold, NSColor(Theme.textPrimary))
        add("  " + [session.agent, session.host].compactMap { $0 }.joined(separator: " · "), .sm, .regular, muted)
        add("\n" + SessionText.detail(session), .base, .regular, NSColor(Theme.textPrimary))
        add("\n" + SessionText.time(session), .sm, .medium, session.state.attention != nil ? warning : muted)
        if let percent = session.contextPercent {
            let high = SessionText.contextHigh(percent)
            add("\n" + (high ? "\(Int(percent))% context · compacts soon" : "\(Int(percent))% context"), .sm, .medium,
                high ? warning : muted)
        }
        if let task = session.task, !SessionText.detail(session).contains(task) {
            add("\nAsked: \"\(task)\"", .sm, .regular, muted)
        }
        let width: CGFloat = 220
        let size = lines.boundingRect(with: CGSize(width: width - 20, height: 200), options: [.usesLineFragmentOrigin]).size
        let box = CALayer()
        box.backgroundColor = NSColor(Theme.raised).cgColor
        box.borderColor = NSColor(DS.Fill.subtle).cgColor
        box.borderWidth = 1
        box.cornerRadius = DS.Radius.md
        box.zPosition = 2000
        let height = ceil(size.height) + 14
        let feet = person.body.position
        let x = min(max(feet.x - width / 2, 4), bounds.width - width - 4)
        var y = feet.y + PixelPerson.height * s + 8
        if y + height > bounds.height - 2 { y = max(2, feet.y - height - 14) }
        box.frame = CGRect(x: x, y: y, width: width, height: height)
        let label = CATextLayer()
        label.string = lines
        label.isWrapped = true
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 10, y: 7, width: width - 20, height: ceil(size.height))
        box.addSublayer(label)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.addSublayer(box)
        CATransaction.commit()
        tip = box
    }
}

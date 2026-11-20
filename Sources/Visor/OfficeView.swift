import AppKit
import SwiftUI
import VisorCore

/// The Agents tab as an office: each tool a table, each session a little
/// person who walks to where its work happens. A bar above the room sums it up
/// and switches back to the list.
struct OfficeView: View {
    let model: AppModel
    /// Points per room pixel.
    static let scale = 2.0
    static let barHeight: CGFloat = 18
    static let barGap: CGFloat = 6

    /// The bar and the room, for the panel's height.
    static func height(for sessions: [AgentSession]) -> CGFloat {
        barHeight + barGap + CGFloat(Office.place(sessions).layout.height * scale)
    }

    var body: some View {
        let scene = Office.place(model.board.sessions)
        VStack(spacing: Self.barGap) {
            HStack(spacing: 0) {
                summary(scene)
                Spacer(minLength: 8)
                worldMenu
                AgentsViewSwitch(model: model)
            }
            .frame(height: Self.barHeight)
            .padding(.horizontal, NotchLayout.inset)
            OfficeCanvas(model: model)
                .frame(width: CGFloat(OfficeLayout.width * Self.scale), height: CGFloat(scene.layout.height * Self.scale))
                .overlay(alignment: .top) {
                    if model.officePicker { OfficeWorldPicker(model: model).transition(.opacity) }
                }
                .animation(.easeOut(duration: 0.12), value: model.officePicker)
        }
    }

    /// Opens the world setting over the room.
    private var worldMenu: some View {
        Button { model.officePicker.toggle() } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.officePicker ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .help("Office world: \(model.officeWorld.title)")
    }

    private func summary(_ scene: OfficeScene) -> some View {
        let sessions = model.board.sessions
        let tools = Set(sessions.map(\.agent)).count
        var text = Text("\(sessions.count) \(sessions.count == 1 ? "agent" : "agents") · \(tools) \(tools == 1 ? "tool" : "tools")")
            .foregroundColor(Theme.textMuted)
        if scene.waiting > 0 { text = text + Text(" · \(scene.waiting) waiting").foregroundColor(Theme.warning) }
        if scene.hidden > 0 { text = text + Text(" · \(scene.hidden) not shown").foregroundColor(Theme.textMuted) }
        return text.font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).tracking(0.6).lineLimit(1)
    }
}

/// The room itself, as Core Animation layers like the notch's pulse: walking,
/// typing and waving loop in the window server at a low frame rate, and the app
/// only does work when a session changes.
struct OfficeCanvas: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> OfficeLayerView { OfficeLayerView() }

    func updateNSView(_ view: OfficeLayerView, context: Context) {
        view.focus = model.focusAgent
        view.show(Office.place(model.board.sessions), sessions: model.board.sessions, world: model.officeWorld)
    }
}

final class OfficeLayerView: NSView {
    var focus: ((AgentSession) -> Void)?
    private let s = CGFloat(OfficeView.scale)
    private var scene: OfficeScene?
    private var world: OfficeWorld = .studio
    private var sessions: [String: AgentSession] = [:]
    private let room = CALayer()
    private let sofaFront = CALayer()
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
        for layer in [room, sofaFront] {
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

    func show(_ next: OfficeScene, sessions list: [AgentSession], world nextWorld: OfficeWorld) {
        sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if nextWorld != world {
            // Another world: a new room and a new cast, placed at once.
            world = nextWorld
            scene = nil
            for person in people.values { [person.body, person.screen].forEach { $0.removeFromSuperlayer() } }
            people = [:]
        }
        let old = scene
        guard next != old else { return }
        scene = next
        let layout = next.layout
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        room.frame = CGRect(x: 0, y: 0, width: OfficeLayout.width * s, height: layout.height * s)
        room.contents = OfficeRoom.image(next, world: world)
        sofaFront.frame = room.frame
        sofaFront.contents = world == .studio ? OfficeRoom.sofaFront(layout) : nil
        sofaFront.zPosition = CGFloat(layout.stationTop + 22.5)
        for ring in rings {
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
        }
        tickClocks()
        CATransaction.commit()
        if let hovered, let person = people[hovered] { showTip(person) } else { hideTip() }
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
        person.shade.cornerRadius = 2.5
        person.shade.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        if person.look.figure != nil {
            // Film characters keep their costume, so a ring at their feet says whose session it is.
            let color = AgentStyle.mark(person.agent.agent)
            person.shade.backgroundColor = color.withAlphaComponent(0.3).cgColor
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
        person.bubble.cornerRadius = 4
        person.bubble.borderColor = NSColor.black.cgColor
        person.glyph.frame = CGRect(x: 0, y: 1, width: 14, height: 12)
        person.glyph.alignmentMode = .center
        person.glyph.contentsScale = scale
        person.bubble.addSublayer(person.glyph)
        body.addSublayer(person.bubble)

        person.tag.string = person.agent.project
        person.tag.font = NSFont.systemFont(ofSize: 8, weight: .semibold)
        person.tag.fontSize = 8
        person.tag.alignmentMode = .center
        person.tag.truncationMode = .end
        person.tag.foregroundColor = NSColor(hex: 0xE9E6F5).cgColor
        person.tag.shadowColor = NSColor.black.cgColor
        person.tag.shadowOpacity = 1
        person.tag.shadowRadius = 1.5
        person.tag.shadowOffset = .zero
        person.tag.contentsScale = scale
        person.tag.frame = CGRect(x: body.bounds.midX - 40, y: -11, width: 80, height: 10)
        body.addSublayer(person.tag)

        person.clock.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        person.clock.fontSize = 8
        person.clock.alignmentMode = .center
        person.clock.foregroundColor = NSColor(hex: 0xFAB219).cgColor
        person.clock.shadowColor = NSColor.black.cgColor
        person.clock.shadowOpacity = 1
        person.clock.shadowRadius = 1.5
        person.clock.shadowOffset = .zero
        person.clock.contentsScale = scale
        person.clock.frame = CGRect(x: body.bounds.midX - 40, y: -21, width: 80, height: 10)
        body.addSublayer(person.clock)

        person.health.backgroundColor = NSColor(hex: 0x141018).cgColor
        person.health.cornerRadius = 1
        person.healthFill.anchorPoint = .zero
        person.health.addSublayer(person.healthFill)
        body.addSublayer(person.health)
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
        let (pose, period) = PixelPerson.pose(for: agent)
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
        person.shade.isHidden = agent.sits
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
        case .approval: style = ("!", NSColor(hex: 0xFAB219), .black)
        case .question: style = ("?", NSColor(hex: 0x5AA2F0), .white)
        case .done: style = ("✓", NSColor(hex: 0x3FBF5F), .white)
        case .thinking: style = ("…", NSColor(hex: 0x2A2838), NSColor(hex: 0xC9C5E0))
        case .idle: style = ("zZ", nil, NSColor(hex: 0xA9A4C8))
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
        let size: CGFloat = style.fill == nil ? 8 : 10
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
        let frames = PixelPerson.screen(person.look, activity: atDesk ? person.agent.activity : nil)
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
        person.healthFill.backgroundColor = NSColor(hex: percent >= 80 ? 0xFAB219 : 0x5AA2F0).cgColor
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
            person.clock.string = Self.elapsed(since: person.agent.since)
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

    /// "0:38", "4:12", "1:05:09".
    static func elapsed(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        let h = seconds / 3600, m = seconds / 60 % 60, sec = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
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
            let font = NSFont.systemFont(ofSize: 7, weight: .bold)
            let fits = { (name: String) in NSAttributedString(string: name, attributes: [.font: font]).size().width <= width }
            let name = [island.total > 1 ? "\(island.agent.uppercased()) · \(island.total)" : nil, island.agent.uppercased()]
                .compactMap { $0 }.first(where: fits)
            if let name {
                let label = text(name, size: 7, color: color, weight: .bold)
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
            let label = text(name, size: 6.5, color: NSColor(hex: 0x8C86B0))
            label.alignmentMode = .center
            label.frame = CGRect(x: x * s - 30, y: (layout.height - top) * s - 8, width: 60, height: 8)
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
        func add(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) {
            lines.append(NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]))
        }
        add(session.project, 12, .semibold, .white)
        add("  " + [session.agent, session.host].compactMap { $0 }.joined(separator: " · "), 10, .regular, NSColor(hex: 0x8A8980))
        add("\n" + Self.detail(session), 11, .regular, NSColor(hex: 0xE9E8E2))
        add("\n" + Self.time(session), 10, .medium, session.state.attention != nil ? NSColor(hex: 0xFAB219) : NSColor(hex: 0x8A8980))
        if let percent = session.contextPercent {
            let high = percent >= 80
            add("\n" + (high ? "\(Int(percent))% context · compacts soon" : "\(Int(percent))% context"), 10, .medium,
                high ? NSColor(hex: 0xFAB219) : NSColor(hex: 0x8A8980))
        }
        if let task = session.task, !Self.detail(session).contains(task) {
            add("\nAsked: \"\(task)\"", 10, .regular, NSColor(hex: 0x8A8980))
        }
        let width: CGFloat = 220
        let size = lines.boundingRect(with: CGSize(width: width - 20, height: 200), options: [.usesLineFragmentOrigin]).size
        let box = CALayer()
        box.backgroundColor = NSColor(hex: 0x1A1A19).cgColor
        box.borderColor = NSColor(hex: 0x2E2D2B).cgColor
        box.borderWidth = 1
        box.cornerRadius = 10
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

    /// How long it has been like this, like the list row's time: a clock while it's busy or
    /// waiting, "5 min ago" once it's done or idle.
    static func time(_ session: AgentSession) -> String {
        let clock = elapsed(since: session.since)
        switch session.state {
        case .needsApproval, .asking, .needsInput: return "Waiting \(clock)"
        case .working: return "Working \(clock)"
        case .done, .idle:
            let ago = RelativeDateTimeFormatter().localizedString(for: session.since, relativeTo: Date())
            return session.state == .done ? "Finished \(ago)" : "Ready since \(ago)"
        }
    }

    static func detail(_ session: AgentSession) -> String {
        switch session.state {
        case .idle: return "Ready"
        case .working(let what): return what == "Thinking" ? session.task.map { "Thinking · \($0)" } ?? what : what
        case .needsApproval(let what): return "Needs approval · \(what)"
        case .asking(let header): return "Asks you · \(header)"
        case .needsInput: return "Waiting for your reply"
        case .done: return "Finished"
        }
    }
}

// MARK: Pixel art

/// Draws in room pixels with y down, like the layout. `scale` draws finer than
/// a room pixel, for soft rounded shapes that stay smooth when shown at 2x.
struct Pixels {
    let context: CGContext
    let height: Int

    init?(width: Int, height: Int, scale: Int = 1) {
        guard let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        self.context = context
        self.height = height
    }

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x, y: Double(height) - y - h, width: w, height: h)
    }

    func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: NSColor) {
        context.setFillColor(color.cgColor)
        context.fill(rect(x, y, w, h))
    }

    func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ hex: UInt32) { fill(x, y, w, h, NSColor(hex: hex)) }

    /// A soft rounded shape, lit from above: `top` fading to `bottom`.
    func clay(_ x: Double, _ y: Double, _ w: Double, _ h: Double, radius: Double, top: UInt32, bottom: UInt32) {
        let path = CGPath(roundedRect: rect(x, y, w, h), cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShouldAntialias(true)
        context.addPath(path)
        context.clip()
        let colors = [NSColor(hex: top).cgColor, NSColor(hex: bottom).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: Double(height) - y), end: CGPoint(x: 0, y: Double(height) - y - h), options: [])
        }
        context.restoreGState()
    }

    func round(_ x: Double, _ y: Double, _ w: Double, _ h: Double, radius: Double, _ color: NSColor) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: rect(x, y, w, h), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    /// A soft shadow under a shape, a little below it.
    func shadow(_ x: Double, _ y: Double, _ w: Double, _ h: Double, radius: Double) {
        round(x + 1, y + 2, w, h, radius: radius, NSColor.black.withAlphaComponent(0.28))
    }

    /// Warm light pooling around a point.
    func glow(_ x: Double, _ y: Double, radius: Double, _ color: NSColor) {
        let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
        let center = CGPoint(x: x, y: Double(height) - y)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 1, endCenter: center, endRadius: radius, options: [])
    }

    func ellipse(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: NSColor) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect(x, y, w, h))
        context.restoreGState()
    }

    /// A filled shape through room-pixel points (y down).
    func polygon(_ points: [(Double, Double)], _ color: NSColor) {
        guard let first = points.first else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        context.setFillColor(color.cgColor)
        context.move(to: CGPoint(x: first.0, y: Double(height) - first.1))
        for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.0, y: Double(height) - point.1)) }
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    /// A ring or arc outline, `width` room pixels thick.
    func ring(_ x: Double, _ y: Double, radius: Double, width: Double, _ color: NSColor) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(x: x - radius, y: Double(height) - y - radius, width: 2 * radius, height: 2 * radius))
        context.restoreGState()
    }

    var image: CGImage? { context.makeImage() }
}

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
        case .still, .reading, .sitting:
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
                                                typing: pose == .typing, waving: pose == .wave, reading: pose == .reading))
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
    static func screen(_ look: Look, activity: OfficeActivity?) -> [CGImage] {
        let key = "screen-\(look.world)-\(look.shirt)-\(String(describing: activity))"
        if let hit = cache[key] { return hit }
        if look.world != .studio { return filmScreen(look.world, activity: activity, key: key) }
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
    /// A film world's screen: a blue holo console in the galaxy, a black panel
    /// of pastel bars on the starship. Lines scroll while it types, a dot moves
    /// while it thinks.
    fileprivate static func filmScreen(_ world: OfficeWorld, activity: OfficeActivity?, key: String) -> [CGImage] {
        let galaxy = world == .galaxy
        let back: UInt32 = galaxy ? 0x1E4A66 : 0x0E0F1C
        let ink: [UInt32] = galaxy ? [0xBFEFFF, 0x7CD0F5] : [0xE2A050, 0x9C8CC9, 0xD98A7A, 0x6F8FCF]
        var images: [CGImage] = []
        let frames = activity == .typing || activity == .thinking ? 3 : 1
        for f in 0..<frames {
            guard let p = Pixels(width: 6, height: 4) else { break }
            p.fill(0, 0, 6, 4, back)
            switch activity {
            case .typing:
                for k in 0..<2 { p.fill(1, 1 + Double(k) * 2, Double(1 + (f + k * 2) % 4), 1, ink[(f + k) % ink.count]) }
            case .thinking:
                p.fill(1 + Double(f) * 2, 2, 1, 1, ink[0])
            default:
                if galaxy { p.fill(2, 1, 2, 2, 0x2E6A8A) } else { p.fill(1, 1, 2, 1, 0x3A2E1C); p.fill(1, 2, 3, 1, 0x2A2440) }
            }
            if let image = p.image { images.append(image) }
        }
        cache[key] = images
        return images
    }
}

/// The room behind the people, a cozy studio at night in soft clay: a warm
/// wooden floor, a lamp pooling light on each table, rounded furniture lit
/// from above with soft shadows. Drawn at 2x so the curves stay smooth.
enum OfficeRoom {
    static let detail = 2

    static func image(_ scene: OfficeScene, world: OfficeWorld) -> CGImage? {
        switch world {
        case .studio: return studio(scene)
        case .galaxy: return FilmRoom.galaxy(scene)
        case .starfleet: return FilmRoom.starfleet(scene)
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
        // Sofa back
        p.shadow(168 + o, t + 6, 40, 9, radius: 4)
        p.clay(168 + o, t + 6, 40, 9, radius: 4, top: 0xB06A54, bottom: 0x7A4436)
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

    /// The sofa's seat and arms, drawn over whoever sits on it.
    static func sofaFront(_ layout: OfficeLayout) -> CGImage? {
        guard let p = Pixels(width: Int(OfficeLayout.width), height: Int(layout.height), scale: detail) else { return nil }
        let t = layout.stationTop, o = (OfficeLayout.width - 212) / 2
        p.clay(166 + o, t + 17, 44, 7, radius: 3, top: 0x9A5A48, bottom: 0x6A3E30)
        p.clay(166 + o, t + 13, 4, 11, radius: 2, top: 0x8A4E3E, bottom: 0x5E3628)
        p.clay(206 + o, t + 13, 4, 11, radius: 2, top: 0x8A4E3E, bottom: 0x5E3628)
        return p.image
    }
}

private extension NSColor {
    /// The colour as 0xRRGGBB.
    var hexValue: UInt32 {
        guard let rgb = usingColorSpace(.sRGB) else { return 0xD97757 }
        return UInt32(rgb.redComponent * 255) << 16 | UInt32(rgb.greenComponent * 255) << 8 | UInt32(rgb.blueComponent * 255)
    }
}

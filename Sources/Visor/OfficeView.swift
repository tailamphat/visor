import AppKit
import SwiftUI
import VisorCore

/// The Agents tab as an office: each session a little person who walks to
/// where its work happens. Drawn as Core Animation layers, like the notch's
/// pulse: walking, typing and waving loop in the window server at a low frame
/// rate, and the app only does work when a session changes.
struct OfficeView: NSViewRepresentable {
    let model: AppModel
    /// Points per room pixel.
    static let scale = 2.0

    func makeNSView(context: Context) -> OfficeLayerView {
        OfficeLayerView()
    }

    func updateNSView(_ view: OfficeLayerView, context: Context) {
        view.focus = model.focusAgent
        view.show(Office.place(model.board.sessions), sessions: model.board.sessions)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OfficeLayerView, context: Context) -> CGSize? {
        CGSize(width: OfficeLayout.width * Self.scale,
               height: OfficeLayout(sessions: model.board.sessions.count).height * Self.scale)
    }
}

final class OfficeLayerView: NSView {
    var focus: ((AgentSession) -> Void)?
    private let s = CGFloat(OfficeView.scale)
    private var scene: OfficeScene?
    private var sessions: [String: AgentSession] = [:]
    private let room = CALayer()
    private let sofaFront = CALayer()
    private var labels: [CALayer] = []
    private var people: [String: Person] = [:]
    private var tip: CALayer?
    private var hovered: String?

    private final class Person {
        let body = CALayer()
        let screen = CALayer()
        let bubble = CALayer()
        let glyph = CATextLayer()
        let tag = CATextLayer()
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
        room.magnificationFilter = .nearest
        room.anchorPoint = .zero
        layer?.addSublayer(room)
        sofaFront.magnificationFilter = .nearest
        sofaFront.anchorPoint = .zero
        layer?.addSublayer(sofaFront)
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

    func show(_ next: OfficeScene, sessions list: [AgentSession]) {
        sessions = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let old = scene
        guard next != old else { return }
        scene = next
        let layout = next.layout
        let height = layout.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        room.frame = CGRect(x: 0, y: 0, width: OfficeLayout.width * s, height: height * s)
        room.contents = OfficeRoom.image(next)
        sofaFront.frame = room.frame
        sofaFront.contents = OfficeRoom.sofaFront(layout)
        sofaFront.zPosition = CGFloat(layout.stationTop + 22.5)
        if old?.layout != layout || old?.segments != next.segments || old?.hidden != next.hidden { buildLabels(next) }
        // A taller or shorter room moves everyone: place them at once rather than walk.
        let snap = old?.layout.height != height
        let ids = Set(next.agents.map(\.id))
        for (id, person) in people where !ids.contains(id) {
            [person.body, person.screen].forEach { $0.removeFromSuperlayer() }
            people[id] = nil
        }
        for agent in next.agents {
            if let person = people[agent.id] {
                let moved = person.agent.feet != agent.feet
                let changed = person.agent != agent
                person.agent = agent
                if moved && !snap { walk(person, to: agent, in: layout) }
                else if changed || snap { settle(person, in: layout) }
            } else {
                let person = Person(agent, look: PixelPerson.look(for: agent))
                people[agent.id] = person
                build(person)
                if old == nil { settle(person, in: layout) }
                else {
                    // A new session walks in through the door on the right.
                    person.body.position = point(OfficePoint(x: OfficeLayout.width + 6, y: layout.corridor), in: layout)
                    walk(person, to: agent, in: layout)
                }
            }
            placeScreen(people[agent.id]!, in: layout)
        }
        // Who else is at a spot decides whether a name fits.
        for person in people.values { person.tag.isHidden = !showsName(person.agent) && hovered != person.agent.id }
        CATransaction.commit()
        if let hovered, let person = people[hovered] { showTip(person) } else { hideTip() }
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
        body.magnificationFilter = .nearest
        layer?.addSublayer(body)

        person.screen.magnificationFilter = .nearest
        person.screen.anchorPoint = .zero
        layer?.addSublayer(person.screen)

        person.bubble.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        person.bubble.cornerRadius = 5
        person.bubble.borderWidth = 2
        person.bubble.borderColor = NSColor.black.cgColor
        person.glyph.frame = CGRect(x: 0, y: 1, width: 16, height: 14)
        person.glyph.alignmentMode = .center
        person.glyph.fontSize = 11
        person.glyph.font = NSFont.systemFont(ofSize: 11, weight: .bold)
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
    }

    /// Puts a person where it belongs and starts what it does there.
    private func settle(_ person: Person, in layout: OfficeLayout) {
        person.body.removeAnimation(forKey: "walk")
        person.body.removeAnimation(forKey: "steps")
        person.body.position = point(person.agent.feet, in: layout)
        person.body.zPosition = CGFloat(person.agent.feet.y)
        startActivity(person, after: 0)
    }

    /// Walks from wherever the person is now, along the room's walkways.
    private func walk(_ person: Person, to agent: OfficeAgent, in layout: OfficeLayout) {
        let body = person.body
        let now = body.presentation()?.position ?? body.position
        let from = OfficePoint(x: now.x / s, y: layout.height - now.y / s)
        let stops = [from] + layout.route(from: from, to: agent.feet)
        var distances = [0.0]
        for i in 1..<stops.count {
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
        let frames = PixelPerson.frames(person.look, pose: up ? .walkBack : .walkFront)
        let steps = CAKeyframeAnimation(keyPath: "contents")
        steps.values = frames
        steps.calculationMode = .discrete
        steps.duration = 0.32
        steps.repeatCount = Float(duration / 0.32)
        steps.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 8, preferred: 6)
        body.add(steps, forKey: "steps")
        person.bubble.isHidden = true
        startActivity(person, after: duration)
    }

    /// The person's loop where it stands (typing, waving, dozing) and its bubble.
    private func startActivity(_ person: Person, after delay: CFTimeInterval) {
        let agent = person.agent
        let (pose, period) = PixelPerson.pose(for: agent)
        let frames = PixelPerson.frames(person.look, pose: pose)
        let body = person.body
        body.contents = frames.first
        body.removeAnimation(forKey: "loop")
        if frames.count > 1 {
            let loop = CAKeyframeAnimation(keyPath: "contents")
            loop.values = frames
            loop.calculationMode = .discrete
            loop.duration = period
            loop.repeatCount = .infinity
            loop.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
            loop.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 8, preferred: 6)
            body.add(loop, forKey: "loop")
        }
        person.tag.isHidden = !showsName(agent) && hovered != agent.id
        styleBubble(person, delay: delay)
    }

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
        bubble.isHidden = delay > 0
        if delay > 0 {
            // Shown once the walk ends.
            let show = CABasicAnimation(keyPath: "hidden")
            show.fromValue = true
            show.toValue = true
            show.duration = delay
            bubble.add(show, forKey: "wait")
            bubble.isHidden = false
        }
        bubble.backgroundColor = style.fill?.cgColor
        bubble.borderWidth = style.fill == nil ? 0 : 2
        person.glyph.string = style.text
        person.glyph.foregroundColor = style.ink.cgColor
        person.glyph.fontSize = style.fill == nil ? 9 : 11
        let sink: CGFloat = agent.sits ? 3 * s : 0
        bubble.position = CGPoint(x: person.body.bounds.midX, y: person.body.bounds.height - sink + 10)
        if agent.activity == .approval || agent.activity == .question {
            let bob = CAKeyframeAnimation(keyPath: "position.y")
            bob.values = [bubble.position.y, bubble.position.y + 2]
            bob.calculationMode = .discrete
            bob.duration = 1
            bob.repeatCount = .infinity
            bob.isAdditive = false
            bob.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 4, preferred: 2)
            bubble.add(bob, forKey: "bob")
        }
    }

    /// The person's monitor: lines while it types, a moving dot while it thinks, a
    /// dot in its colour while it's away.
    private func placeScreen(_ person: Person, in layout: OfficeLayout) {
        let desk = person.agent.desk
        let screen = person.screen
        screen.frame = CGRect(x: (desk.x - 4) * s, y: (layout.height - desk.y - 13) * s, width: 8 * s, height: 6 * s)
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
    /// at desks and in a crowd they show on hover, so nothing overlaps.
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

    private func buildLabels(_ scene: OfficeScene) {
        labels.forEach { $0.removeFromSuperlayer() }
        labels = []
        let layout = scene.layout
        for segment in scene.segments {
            let color = AgentStyle.mark(segment.agent)
            let width = Double(segment.length) * layout.cellWidth * s - 8
            let name = segment.length > 1 ? "\(segment.agent.uppercased()) · \(segment.count)" : segment.agent.uppercased()
            let x = (layout.left + Double(segment.column) * layout.cellWidth + 2) * s
            let top = OfficeLayout.firstRow + Double(segment.row) * OfficeLayout.rowHeight + 1
            let fits = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 7, weight: .bold)]).size().width <= width
            if fits {
                let label = text(name, size: 7, color: color, weight: .bold)
                label.frame = CGRect(x: x, y: (layout.height - top) * s - 9, width: width, height: 9)
                labels.append(label)
            } else {
                // Too narrow for the name: the tool's mark, its name on hover in the tooltip.
                let mark = CAShapeLayer()
                var transform = CGAffineTransform(translationX: x, y: (layout.height - top) * s).scaledBy(x: 8 / 24, y: -8 / 24)
                mark.path = AgentLogo.path(for: segment.agent).copy(using: &transform)
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
        if scene.hidden > 0 {
            let more = text("+\(scene.hidden) more", size: 8, color: NSColor(hex: 0xC3C2B7))
            more.alignmentMode = .right
            more.frame = CGRect(x: OfficeLayout.width * s - 86, y: layout.height * s - 18, width: 80, height: 10)
            labels.append(more)
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
        guard let scene, let session = sessions[person.agent.id] else { return }
        let lines = NSMutableAttributedString()
        func add(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) {
            lines.append(NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]))
        }
        add(session.project, 12, .semibold, .white)
        add("  " + [session.agent, session.host].compactMap { $0 }.joined(separator: " · "), 10, .regular, NSColor(hex: 0x8A8980))
        add("\n" + Self.detail(session), 11, .regular, NSColor(hex: 0xE9E8E2))
        if let percent = session.contextPercent {
            let high = percent >= 80
            add("\n" + (high ? "\(Int(percent))% context · compacts soon" : "\(Int(percent))% context"), 10, .medium,
                high ? NSColor(hex: 0xFAB219) : NSColor(hex: 0x8A8980))
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

/// Draws in room pixels with y down, like the layout.
struct Pixels {
    let context: CGContext
    let height: Int

    init?(width: Int, height: Int) {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        self.context = context
        self.height = height
    }

    func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: NSColor) {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: x, y: Double(height) - y - h, width: w, height: h))
    }

    func fill(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ hex: UInt32) { fill(x, y, w, h, NSColor(hex: hex)) }

    var image: CGImage? { context.makeImage() }
}

enum PixelPerson {
    static let width = 11.0
    static let height = 14.0

    struct Look: Hashable {
        var shirt: UInt32
        var hair: UInt32
        var skin: UInt32
    }

    enum Pose: Hashable {
        case typing, still, reading, wave, sitting, dozing, walkFront, walkBack
    }

    static let hairs: [UInt32] = [0x3B2A20, 0xE8D27A, 0x1E1E1E, 0x8B4A2B, 0xC9C9D1, 0x5A3A7A, 0x2E4A2E]
    static let skins: [UInt32] = [0xF1C7A1, 0xD8A27A, 0xA8714D, 0x7A4E31, 0xF6D7BC]

    /// A look that stays the same for a session: its tool's colour, and hair and
    /// skin picked from its id.
    static func look(for agent: OfficeAgent) -> Look {
        let seed = agent.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return Look(shirt: AgentStyle.mark(agent.agent).hexValue, hair: hairs[seed % hairs.count], skin: skins[(seed / 7) % skins.count])
    }

    static func pose(for agent: OfficeAgent) -> (Pose, CFTimeInterval) {
        switch agent.activity {
        case .typing, .running, .browsing: return (.typing, 0.32)
        case .thinking: return (.still, 1)
        case .reading: return (.reading, 1)
        case .approval, .question: return (.wave, 1)
        case .done: return (agent.sits ? .sitting : .still, 1)
        case .idle: return (agent.sits ? .dozing : .still, 1)
        }
    }

    private static var cache: [String: [CGImage]] = [:]

    static func frames(_ look: Look, pose: Pose) -> [CGImage] {
        let key = "\(look.shirt)-\(look.hair)-\(look.skin)-\(pose)"
        if let hit = cache[key] { return hit }
        let count = [.typing, .wave, .walkFront, .walkBack].contains(pose) ? 2 : 1
        let images = (0..<count).compactMap { draw(look, pose: pose, frame: $0) }
        cache[key] = images
        return images
    }

    private static func draw(_ look: Look, pose: Pose, frame: Int) -> CGImage? {
        guard let p = Pixels(width: Int(width), height: Int(height)) else { return nil }
        let shirt = NSColor(hex: look.shirt), dark = shirt.blended(withFraction: 0.3, of: .black) ?? shirt
        let hair = NSColor(hex: look.hair), skin = NSColor(hex: look.skin), legs = NSColor(hex: 0x2A2A3A)
        let x = 5.0, y = 14.0
        let sits = pose == .sitting || pose == .dozing
        let by = sits ? 3.0 : 0
        let walking = pose == .walkFront || pose == .walkBack
        let back = [.typing, .still, .reading, .walkBack].contains(pose)
        let step = frame == 1
        if sits {
            p.fill(x - 2, y - 1, 2, 1, legs); p.fill(x + 1, y - 1, 2, 1, legs)
        } else {
            p.fill(x - 2, y - 2 - (walking && step ? 1 : 0), 2, 2, legs)
            p.fill(x + 1, y - 2 - (walking && !step ? 1 : 0), 2, 2, legs)
        }
        p.fill(x - 3, y - 6 + by, 7, 4, shirt)
        p.fill(x - 3, y - 3 + by, 7, 1, dark)
        let typing = pose == .typing
        p.fill(x - 4, y - 6 + by + (typing && step ? -1 : 0), 1, 3, dark)
        if pose == .wave {
            if step { p.fill(x + 4, y - 11, 1, 5, dark); p.fill(x + 5, y - 12, 1, 1, skin) }
            else { p.fill(x + 4, y - 12, 1, 6, dark); p.fill(x + 4, y - 13, 1, 1, skin) }
        } else {
            p.fill(x + 4, y - 6 + by + (typing && !step ? -1 : 0), 1, 3, dark)
        }
        if back {
            p.fill(x - 2, y - 11 + by, 5, 5, hair)
            p.fill(x - 2, y - 7 + by, 5, 1, skin)
        } else {
            p.fill(x - 2, y - 10 + by, 5, 4, skin)
            p.fill(x - 2, y - 11 + by, 5, 1, hair)
            p.fill(x - 2, y - 10 + by, 1, 2, hair); p.fill(x + 2, y - 10 + by, 1, 2, hair)
            if pose != .dozing { p.fill(x - 1, y - 8 + by, 1, 1, 0x1A1A22); p.fill(x + 1, y - 8 + by, 1, 1, 0x1A1A22) }
        }
        if pose == .reading { p.fill(x - 2, y - 7, 5, 2, 0xE9E3C8) }
        return p.image
    }

    /// A desk's monitor: 8 x 6 room pixels.
    static func screen(_ look: Look, activity: OfficeActivity?) -> [CGImage] {
        let key = "screen-\(look.shirt)-\(String(describing: activity))"
        if let hit = cache[key] { return hit }
        let shirt = NSColor(hex: look.shirt), dark = shirt.blended(withFraction: 0.35, of: .black) ?? shirt
        var images: [CGImage] = []
        switch activity {
        case .typing:
            for f in 0..<3 {
                guard let p = Pixels(width: 8, height: 6) else { break }
                p.fill(0, 0, 8, 6, dark)
                for k in 0..<3 { p.fill(1, 1 + Double(k) * 2, Double(2 + (f + k * 2) % 5), 1, 0xF2F0FF) }
                if let image = p.image { images.append(image) }
            }
        case .thinking:
            for f in 0..<3 {
                guard let p = Pixels(width: 8, height: 6) else { break }
                p.fill(0, 0, 8, 6, dark)
                p.fill(2 + Double(f) * 2, 3, 1, 1, 0xF2F0FF)
                if let image = p.image { images.append(image) }
            }
        default:
            if let p = Pixels(width: 8, height: 6) {
                p.fill(0, 0, 8, 6, 0x1B2230)
                p.fill(3, 2, 2, 2, dark)
                if let image = p.image { images.append(image) }
            }
        }
        cache[key] = images
        return images
    }
}

/// The room behind the people: wall, floor, rugs, desks and the bottom row.
enum OfficeRoom {
    static func image(_ scene: OfficeScene) -> CGImage? {
        let layout = scene.layout
        guard let p = Pixels(width: Int(OfficeLayout.width), height: Int(layout.height)) else { return nil }
        let w = OfficeLayout.width, h = layout.height
        p.fill(0, 0, w, 12, 0x2B2740); p.fill(0, 11, w, 1, 0x3A3556)
        var wx = 18.0
        while wx < w - 30 { p.fill(wx, 2, 34, 7, 0x162741); p.fill(wx + 16, 2, 2, 7, 0x2B2740); p.fill(wx + 26, 4, 2, 2, 0xF4E7B0); wx += 58 }
        var y = 12.0
        while y < h {
            var x = 0.0
            while x < w { p.fill(x, y, 8, 8, Int((x + y) / 8) % 2 == 1 ? 0x1D1B2A : 0x211E30); x += 8 }
            y += 8
        }
        for segment in scene.segments {
            let color = AgentStyle.mark(segment.agent)
            let x = layout.left + Double(segment.column) * layout.cellWidth, top = OfficeLayout.firstRow + Double(segment.row) * OfficeLayout.rowHeight
            let width = Double(segment.length) * layout.cellWidth
            p.fill(x + 1, top, width - 2, 35, color.withAlphaComponent(0.13))
            p.fill(x + 1, top + 34, width - 2, 1, color.withAlphaComponent(0.45))
        }
        let deskWidth = layout.cellWidth - 6
        for agent in scene.agents {
            let d = agent.desk
            p.fill(d.x - deskWidth / 2, d.y + 14, deskWidth, 6, 0x5B4636); p.fill(d.x - deskWidth / 2, d.y + 20, deskWidth, 2, 0x3F3026)
            p.fill(d.x - 5, d.y + 6, 10, 8, 0x0E0E14); p.fill(d.x - 1, d.y + 14, 2, 1, 0x0E0E14)
            p.fill(d.x - deskWidth / 2 + 2, d.y + 15, 4, 2, 0x7B6250)
        }
        let t = layout.stationTop
        p.fill(0, layout.deskBottom + 2, w, 1, 0x2B2740)
        // Terminal rack
        p.fill(12, t, 18, 20, 0x14161F); p.fill(12, t, 18, 1, 0x3A3F52)
        for i in 0..<4 {
            let row = t + 3 + Double(i) * 4
            p.fill(14, row, 14, 3, 0x20242F); p.fill(15, row + 1, 1, 1, 0x3FBF5F); p.fill(17 + Double(i * 2 % 7), row + 1, 3, 1, 0x59D97A)
        }
        // Bookshelf
        p.fill(44, t, 28, 20, 0x4A3427)
        let books: [UInt32] = [0xC0504D, 0x4F81BD, 0x9BBB59, 0xF2C14E, 0x8064A2, 0x4BACC6]
        for r in 0..<3 {
            p.fill(45, t + 6 + Double(r) * 6, 26, 1, 0x2F2119)
            for i in 0..<8 { p.fill(46 + Double(i) * 3, t + 2 + Double(r) * 6, 2, 4, books[(i + r * 2) % books.count]) }
        }
        // Your desk, its screen amber while someone waits
        p.fill(105, t + 8, 32, 7, 0x6B5240); p.fill(105, t + 15, 32, 2, 0x4A382C)
        p.fill(116, t + 2, 10, 7, 0x0E0E14); p.fill(117, t + 3, 8, 5, scene.waiting > 0 ? 0x5A4410 : 0x1B2230)
        p.fill(131, t + 6, 3, 2, 0xF2C14E); p.fill(132, t + 5, 1, 1, 0xF2C14E)
        // Web kiosk with a globe
        p.fill(163, t + 4, 18, 16, 0x14161F)
        p.context.setFillColor(NSColor(hex: 0x3186FF).cgColor)
        p.context.fillEllipse(in: CGRect(x: 167, y: h - (t + 17), width: 10, height: 10))
        p.fill(167, t + 12, 10, 1, 0x9CC3FF); p.fill(171, t + 7, 1, 10, 0x9CC3FF)
        // Sofa back
        p.fill(193, t + 6, 40, 8, 0x3D4C7A); p.fill(193, t + 6, 40, 1, 0x53649A)
        // The door agents come in by
        p.fill(w - 3, layout.corridor - 12, 3, 16, 0x5B4636)
        return p.image
    }

    /// The sofa's seat and arms, drawn over whoever sits on it.
    static func sofaFront(_ layout: OfficeLayout) -> CGImage? {
        guard let p = Pixels(width: Int(OfficeLayout.width), height: Int(layout.height)) else { return nil }
        let t = layout.stationTop
        p.fill(191, t + 18, 44, 6, 0x34416A); p.fill(191, t + 14, 3, 10, 0x2A3558); p.fill(232, t + 14, 3, 10, 0x2A3558)
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

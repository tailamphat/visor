import AppKit
import SwiftUI
import VisorCore

/// The first-launch intro, "spotlight stage": the screen dims, Visor's icon rises
/// toward you in the middle, a glint flashes across it, it squashes and launches
/// up into the notch on a light trail, the notch catches it with a glow and
/// sparks, and opens to say hello. One click-through window just under the
/// notch's, all Core Animation, gone after about five seconds.
@MainActor
final class IntroController {
    private var window: NSWindow?
    /// About 30% slower than the first cut, so each beat lands.
    /// The beats were timed on a 4.6 s timeline; the flight up to the notch
    /// (0.42 to 0.54 of it) gets 2 s longer, everything else keeps its pace.
    private static let base: CFTimeInterval = 4.6
    private static let flight = (from: 0.42, to: 0.54, extra: 2.0)
    private let duration: CFTimeInterval = base + flight.extra

    /// A moment on the 4.6 s timeline, in seconds on the real one.
    private static func seconds(_ fraction: Double) -> Double {
        let s = fraction * base, a = flight.from * base, b = flight.to * base
        if s <= a { return s }
        if s <= b { return a + (s - a) * (b - a + flight.extra) / (b - a) }
        return s + flight.extra
    }

    /// Key times written on the 4.6 s timeline, for an animation `length` long.
    private func times(_ fractions: [Double], length: Double? = nil) -> [NSNumber] {
        let total = length ?? duration
        return fractions.map { NSNumber(value: min(1, Self.seconds($0 * (length.map { ($0 - Self.flight.extra) / Self.base } ?? 1)) / total)) }
    }

    /// Plays on `screen`; `arrive` runs when the icon reaches the notch, to open it.
    func play(on screen: NSScreen, arrive: @escaping () -> Void) {
        let frame = screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        guard let root = view.layer else { return }

        let w = frame.width, h = frame.height
        let centre = CGPoint(x: w / 2, y: h * 0.55)
        let notch = CGPoint(x: w / 2, y: h - 16)
        let start = CACurrentMediaTime() + 0.05

        // The stage lights go down around the centre, and come back up at the end.
        let dim = CALayer()
        dim.frame = root.bounds
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        dim.opacity = 0
        root.addSublayer(dim)
        animate(dim, "opacity", [0, 1, 1, 0.25, 0], times([0, 0.1, 0.7, 1, 1], length: duration + 0.6), start: start, length: duration + 0.6)

        // A soft halo behind the icon.
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.bounds = CGRect(x: 0, y: 0, width: 220, height: 220)
        halo.position = centre
        halo.colors = [NSColor(hex: 0x96B4FF).withAlphaComponent(0.4).cgColor, NSColor(hex: 0xE8825F).withAlphaComponent(0.12).cgColor,
                       NSColor.clear.cgColor]
        halo.locations = [0, 0.45, 1]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.opacity = 0
        root.addSublayer(halo)
        animate(halo, "opacity", [0, 1, 0.9, 0], times([0, 0.18, 0.4, 0.5]), start: start)
        animate(halo, "transform.scale", [0.3, 1.3, 1.1, 1.6], times([0, 0.18, 0.4, 0.5]), start: start)

        // The light trail from the icon to the notch.
        let trail = CAGradientLayer()
        trail.colors = [NSColor(hex: 0x8CC8FF).cgColor, NSColor(hex: 0xA78BFA).withAlphaComponent(0.85).cgColor,
                        NSColor(hex: 0xE8825F).withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
        trail.locations = [0, 0.35, 0.7, 1]
        trail.startPoint = CGPoint(x: 0.5, y: 1)
        trail.endPoint = CGPoint(x: 0.5, y: 0)
        trail.anchorPoint = CGPoint(x: 0.5, y: 1)
        trail.bounds = CGRect(x: 0, y: 0, width: 8, height: notch.y - centre.y)
        trail.position = notch
        trail.cornerRadius = 4
        trail.opacity = 0
        root.addSublayer(trail)
        animate(trail, "opacity", [0, 0, 1, 0], times([0, 0.42, 0.5, 0.62]), start: start)
        animate(trail, "transform.scale.y", [0.01, 0.01, 1, 0.05], times([0, 0.42, 0.52, 0.62]), start: start)

        // The icon: rises toward you, settles, a little bob, squash, then launch.
        let icon = CALayer()
        icon.bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        icon.position = centre
        icon.contents = NSApp.applicationIconImage
        icon.contentsGravity = .resizeAspect
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.5
        icon.shadowRadius = 14
        icon.shadowOffset = CGSize(width: 0, height: -10)
        icon.opacity = 0
        root.addSublayer(icon)
        let iconTimes = times([0, 0.18, 0.28, 0.36, 0.42, 0.54, 0.58])
        animate(icon, "position.y", [centre.y - 40, centre.y, centre.y, centre.y + 4, centre.y - 6, notch.y, notch.y], iconTimes, start: start)
        animate(icon, "transform.scale.x", [0.8, 1.1, 1, 1, 1.05, 0.3, 0.1], iconTimes, start: start)
        animate(icon, "transform.scale.y", [0.8, 1.1, 1, 1, 0.93, 0.5, 0.1], iconTimes, start: start)
        animate(icon, "opacity", [0, 1, 1, 1, 1, 1, 0], iconTimes, start: start)

        // A glint flashing across it.
        let glint = CAGradientLayer()
        glint.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.9).cgColor, NSColor.clear.cgColor]
        glint.startPoint = CGPoint(x: 0, y: 0.5)
        glint.endPoint = CGPoint(x: 1, y: 0.5)
        glint.bounds = CGRect(x: 0, y: 0, width: 240, height: 2)
        glint.position = centre
        glint.opacity = 0
        root.addSublayer(glint)
        animate(glint, "opacity", [0, 0, 1, 0], times([0, 0.18, 0.22, 0.3]), start: start)
        animate(glint, "transform.scale.x", [0.2, 0.2, 1, 1.4], times([0, 0.18, 0.22, 0.3]), start: start)

        // The notch catches it: a glow around the notch and a burst of sparks.
        let glow = CALayer()
        glow.bounds = CGRect(x: 0, y: 0, width: 220, height: 40)
        glow.position = CGPoint(x: notch.x, y: h - 14)
        glow.cornerRadius = 16
        glow.backgroundColor = NSColor(hex: 0x96B4FF).withAlphaComponent(0.25).cgColor
        glow.shadowColor = NSColor(hex: 0x96B4FF).cgColor
        glow.shadowOpacity = 1
        glow.shadowRadius = 24
        glow.shadowOffset = .zero
        glow.opacity = 0
        root.addSublayer(glow)
        animate(glow, "opacity", [0, 0, 1, 0], times([0, 0.53, 0.57, 0.8]), start: start)
        for i in 0..<14 {
            let a = Double.pi + Double(i) / 13 * Double.pi
            let r = 60 + Double(i % 3) * 26
            let spark = CALayer()
            spark.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            spark.cornerRadius = 2
            spark.backgroundColor = NSColor(hex: 0xCFE6FF).cgColor
            spark.shadowColor = NSColor(hex: 0x9FD0FF).cgColor
            spark.shadowOpacity = 1
            spark.shadowRadius = 4
            spark.shadowOffset = .zero
            spark.position = CGPoint(x: notch.x, y: h - 26)
            spark.opacity = 0
            root.addSublayer(spark)
            let end = CGPoint(x: notch.x + cos(a) * r, y: h - 26 + sin(a) * r * 0.5 - 20)
            animate(spark, "opacity", [0, 0, 1, 0], times([0, 0.52, 0.55, 0.75]), start: start + Double(i % 4) * 0.03)
            animate(spark, "position", [NSValue(point: spark.position), NSValue(point: spark.position), NSValue(point: end)],
                    times([0, 0.52, 0.75]), start: start + Double(i % 4) * 0.03)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds(Self.flight.to)) { arrive() }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.8) { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
        }
    }

    private func animate(_ layer: CALayer, _ keyPath: String, _ values: [Any], _ times: [NSNumber], start: CFTimeInterval,
                         length: CFTimeInterval? = nil) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.duration = length ?? duration
        animation.beginTime = start
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: keyPath)
    }
}

/// What the notch says the first time: hello, what Visor does, and a way in.
struct WelcomeView: View {
    let model: AppModel
    static let height: CGFloat = 112

    var body: some View {
        let settled = model.welcomeSettled
        VStack(spacing: 6) {
            // A focus pull: the letters start wide apart and blurred, then drift
            // together as the blur clears.
            HStack(spacing: settled ? -0.3 : 9) {
                ForEach(Array("Hi, I'm Visor".enumerated()), id: \.offset) { _, letter in
                    Text(String(letter))
                }
            }
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(.white)
            .blur(radius: settled ? 0 : 8)
            .opacity(settled ? 1 : 0)
            .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 1.4), value: settled)
            Group {
                Text("I live up here: your agents, usage, music and clipboard.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            // The Allow button's style and key: mint with dark text, Return presses it.
            Button { model.dismissWelcome() } label: {
                Label { KeyHint(title: "Get started", key: "↩") } icon: { Image(systemName: "checkmark") }
            }
            .buttonStyle(ConsentButton(kind: .allow))
            .padding(.top, 6)
            }
            // The line and the button follow once the title has landed.
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 6)
            .animation(.easeOut(duration: 0.6).delay(1.3), value: settled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { DispatchQueue.main.async { model.welcomeSettled = true } }
    }
}

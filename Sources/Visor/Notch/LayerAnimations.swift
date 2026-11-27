import AppKit
import SwiftUI
import VisorCore

// Looping animations as Core Animation layers. The window server runs them, so
// the app does no work per frame, and each asks for a low frame rate so the
// GPU composites 20-30 frames a second instead of up to 120 on ProMotion. SwiftUI's symbolEffect and repeatForever
// animations re-render the whole notch every frame instead (~10% CPU idle).

/// An SF Symbol that gently pulses while `active`.
struct PulsingSymbol: NSViewRepresentable {
    let name: String
    /// An agent whose own mark to show in place of the symbol.
    var logo: String?
    let color: NSColor
    /// The symbol's inner mark ("?", "!") when it differs from `color`: a bubble's own glyph.
    var glyph: NSColor?
    let size: CGFloat
    var active = true

    /// What the layer's image was last drawn from: SwiftUI updates this view on
    /// every board publish, and redrawing an unchanged image is wasted work.
    final class Coordinator {
        var drawn: [AnyHashable]?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(CALayer())
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer?.sublayers?.first else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let key: [AnyHashable] = [name, logo, color, glyph, size, scale]
        if key != context.coordinator.drawn {
            context.coordinator.drawn = key
            let image: NSImage?
            if let logo {
                image = Self.logoImage(logo, color: color, size: size)
            } else {
                let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                    .applying(.init(paletteColors: glyph.map { [$0, color] } ?? [color]))
                image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            layer.contentsGravity = .resizeAspect
            layer.contentsScale = scale
            layer.frame = CGRect(x: 0, y: 0, width: size + 4, height: size + 4)
            CATransaction.commit()
        }
        if active, layer.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // A slow fade looks the same at 20 fps as at 120: far fewer frames to composite.
            pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 24, preferred: 20)
            layer.add(pulse, forKey: "pulse")
        } else if !active {
            layer.removeAnimation(forKey: "pulse")
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: size + 4, height: size + 4)
    }

    /// An agent's mark as an image, drawn from its vector path at any scale.
    static func logoImage(_ agent: String, color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 24, y: rect.height / 24)
            context.addPath(AgentLogo.path(for: agent))
            context.setFillColor(color.cgColor)
            context.fillPath()
            return true
        }
    }
}

/// A text caret that blinks like the system's, for the clipboard search.
struct BlinkingCaret: NSViewRepresentable {
    /// The accent as an NSColor, made once: the clipboard search makes a caret on every keystroke.
    private static let accent = NSColor(Theme.accent)
    var color = BlinkingCaret.accent
    private static let size = CGSize(width: 1.5, height: 14)

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let caret = CALayer()
        caret.frame = CGRect(origin: .zero, size: Self.size)
        caret.cornerRadius = Self.size.width / 2
        view.layer?.addSublayer(caret)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let caret = view.layer?.sublayers?.first else { return }
        caret.backgroundColor = color.cgColor
        guard caret.animation(forKey: "blink") == nil else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        // On, then off, with a hard switch: a caret doesn't fade.
        blink.values = [1, 0]
        blink.keyTimes = [0, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1.06
        blink.repeatCount = .infinity
        blink.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 10, preferred: 4)
        caret.add(blink, forKey: "blink")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { Self.size }
}

/// Three bouncing bars, like a music equalizer.
struct EqualizerBars: NSViewRepresentable {
    var color: NSColor = .white
    var active = true
    /// Full size by default; `.mini` fits a badge on a 20 pt thumbnail.
    var barWidth: CGFloat = 3
    var gap: CGFloat = 2.5
    var height: CGFloat = 12

    static func mini(color: NSColor, active: Bool) -> EqualizerBars {
        EqualizerBars(color: color, active: active, barWidth: 2, gap: 1, height: 8)
    }

    private var size: CGSize { CGSize(width: 3 * barWidth + 2 * gap, height: height) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        for i in 0..<3 {
            let bar = CALayer()
            bar.backgroundColor = color.cgColor
            bar.cornerRadius = barWidth / 2
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: height)
            bar.position = CGPoint(x: CGFloat(i) * (barWidth + gap) + barWidth / 2, y: 0)
            view.layer?.addSublayer(bar)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        for (i, bar) in (view.layer?.sublayers ?? []).enumerated() {
            bar.backgroundColor = color.cgColor
            if active, bar.animation(forKey: "bounce") == nil {
                let bounce = CABasicAnimation(keyPath: "transform.scale.y")
                bounce.fromValue = 0.25
                bounce.toValue = 1
                bounce.duration = [0.42, 0.55, 0.36][i % 3]
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bounce.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                bar.add(bounce, forKey: "bounce")
            } else if !active {
                bar.removeAnimation(forKey: "bounce")
                bar.transform = CATransform3DMakeScale(1, 0.3, 1)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { size }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The helpers waterfall's bars: one layer per `HelperWaterfall.BarSpec`, coloured by
/// state, outlined on the critical path, and a running bar grows to the axis end with
/// one Core Animation width animation (no timer). Layers are rebuilt only when the
/// specs' keys change, so SwiftUI updating this view a moment later keeps them running.
struct TraceBars: NSViewRepresentable {
    let graph: HelperGraph
    let rowHeight: CGFloat

    func makeNSView(context: Context) -> TraceBarsView {
        let view = TraceBarsView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: TraceBarsView, context: Context) {
        view.rowHeight = rowHeight
        view.graph = graph
    }
}

final class TraceBarsView: NSView {
    var rowHeight: CGFloat = 18
    var graph: HelperGraph? { didSet { if graph != oldValue { needsLayout = true } } }
    private var keys: [String] = []
    static let barHeight: CGFloat = 8
    static let stripe: CGFloat = 2
    static let stripeStep: CGFloat = 8
    private static let colors: [HelperGraph.State: CGColor] = [
        .done: NSColor(Theme.good).cgColor, .running: NSColor(Theme.warning).cgColor,
        .failed: NSColor(Theme.critical).cgColor, .queued: NSColor(Theme.deemphasis).cgColor,
    ]
    private static let mainColor = NSColor(DS.Fill.strong).cgColor
    private static let outline = NSColor(Theme.textPrimary).cgColor
    private static let stripeColor = NSColor(Theme.surface).withAlphaComponent(DS.Fill.Opacity.heavy).cgColor

    /// Rows count down from the top, like the names beside them.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        apply()
    }

    /// Off screen (the waterfall closed): drop the layers so no grow animation keeps running.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            keys = []
        } else {
            needsLayout = true
        }
    }

    private func apply() {
        guard let graph, let host = layer, window != nil, bounds.width > 0 else { return }
        let specs = HelperWaterfall.bars(graph: graph, trackWidth: Double(bounds.width), now: Date())
        let keys = HelperWaterfall.layerKey(bars: specs, height: Double(bounds.height))
        guard keys != self.keys else { return }
        self.keys = keys
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.isGeometryFlipped = true  // top-down, whatever AppKit chose for the backing layer
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        for (i, spec) in specs.enumerated() {
            host.addSublayer(bar(spec, row: i))
        }
        CATransaction.commit()
    }

    private func bar(_ spec: HelperWaterfall.BarSpec, row: Int) -> CALayer {
        let bar = CALayer()
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        let end = CGFloat(spec.growTo ?? spec.width)
        let y = CGFloat(row) * rowHeight + (rowHeight - Self.barHeight) / 2
        bar.frame = CGRect(x: CGFloat(spec.x), y: y, width: end, height: Self.barHeight)
        bar.cornerRadius = DS.Radius.xs
        bar.masksToBounds = true
        bar.backgroundColor = spec.isMain ? Self.mainColor : Self.colors[spec.state]
        if spec.critical {
            bar.borderWidth = 1.5
            bar.borderColor = Self.outline
        }
        if spec.state == .running {
            let stripes = CAReplicatorLayer()
            // As long as the bar will grow, not the whole track.
            stripes.frame = CGRect(x: 0, y: 0, width: end, height: Self.barHeight)
            let stripe = CALayer()
            stripe.frame = CGRect(x: 0, y: 0, width: Self.stripe, height: Self.barHeight)
            stripe.backgroundColor = Self.stripeColor
            stripes.addSublayer(stripe)
            stripes.instanceCount = Int(end / Self.stripeStep) + 1
            stripes.instanceTransform = CATransform3DMakeTranslation(Self.stripeStep, 0, 0)
            bar.addSublayer(stripes)
        }
        if let seconds = spec.growSeconds, seconds > 0, end > CGFloat(spec.width) {
            let grow = CABasicAnimation(keyPath: "bounds.size.width")
            grow.fromValue = CGFloat(spec.width)
            grow.toValue = end
            grow.duration = seconds
            grow.timingFunction = CAMediaTimingFunction(name: .linear)
            // A bar gains well under a point a second on a long turn: a few frames a second is plenty.
            grow.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 8, preferred: 4)
            bar.add(grow, forKey: "grow")
        }
        return bar
    }
}

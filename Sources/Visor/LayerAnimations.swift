import AppKit
import SwiftUI

// Looping animations as Core Animation layers. The window server runs them, so
// the app does no work per frame, and each asks for a low frame rate so the
// GPU composites 20-30 frames a second instead of up to 120 on ProMotion. SwiftUI's symbolEffect and repeatForever
// animations re-render the whole notch every frame instead (~10% CPU idle).

/// An SF Symbol that gently pulses while `active`.
struct PulsingSymbol: NSViewRepresentable {
    let name: String
    let color: NSColor
    let size: CGFloat
    var active = true

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(CALayer())
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer?.sublayers?.first else { return }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = view.window?.backingScaleFactor ?? 2
        layer.frame = CGRect(x: 0, y: 0, width: size + 4, height: size + 4)
        CATransaction.commit()
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

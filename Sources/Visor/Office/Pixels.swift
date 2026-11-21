import AppKit
import SwiftUI
import VisorCore

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

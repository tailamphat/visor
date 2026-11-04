import CoreGraphics
import Foundation

/// Turns SVG path data ("M4.7 15.9l4.7-2.6...") into a CGPath, in SVG's own
/// coordinates (y down). Enough of the spec for icon artwork: every command,
/// including arcs, and the compact number forms icon files use.
public enum SVGPath {
    public static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(Array(data.utf8))
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?   // for S/s and T/t
        var lastWasCubic = false, lastWasQuad = false
        var command: UInt8 = 0

        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek else { break }
            if Self.isCommand(next) {
                command = next
                scanner.advance()
            } else if command == 0 {
                break
            }
            let relative = command >= 97   // lowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            var cubic = false, quad = false
            switch command | 0x20 {   // lowercased
            case UInt8(ascii: "m"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                start = current
                path.move(to: current)
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")   // later pairs are lines
            case UInt8(ascii: "l"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                path.addLine(to: current)
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current.x = relative ? current.x + x : x
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current.y = relative ? current.y + y : y
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = point(x1, y1), c2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
                cubic = true
            case UInt8(ascii: "s"):
                guard let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c1 = lastWasCubic ? reflect(lastControl!, about: current) : current
                let c2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
                cubic = true
            case UInt8(ascii: "q"):
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let c = point(x1, y1), end = point(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
                quad = true
            case UInt8(ascii: "t"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let c = lastWasQuad ? reflect(lastControl!, about: current) : current
                let end = point(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
                quad = true
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = point(x, y)
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                command = 0   // Z takes no numbers; the next thing must be a command
            default:
                return path
            }
            lastWasCubic = cubic
            lastWasQuad = quad
        }
        return path
    }

    private static func isCommand(_ c: UInt8) -> Bool {
        "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c)
    }

    private static func reflect(_ p: CGPoint, about c: CGPoint) -> CGPoint {
        CGPoint(x: 2 * c.x - p.x, y: 2 * c.y - p.y)
    }

    /// An SVG endpoint arc as cubic curves (SVG spec, appendix F.6).
    private static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                               rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        // Radii too small to reach: scale them up just enough.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = sqrt(max(0, num / den))
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // At most a quarter turn per curve keeps the approximation tight.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func onEllipse(_ t: CGFloat) -> (CGPoint, CGPoint) {
            let x = rx * cos(t), y = ry * sin(t)
            let tx = -rx * sin(t), ty = ry * cos(t)   // tangent
            let p = CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
            let d = CGPoint(x: cosPhi * tx - sinPhi * ty, y: sinPhi * tx + cosPhi * ty)
            return (p, d)
        }
        var t = theta
        for i in 0..<segments {
            let (a, da) = onEllipse(t)
            let (b, db) = onEllipse(t + step)
            let end = i == segments - 1 ? p1 : b
            path.addCurve(to: end, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }
}

/// Reads numbers the way SVG writes them: "-.5", "1e-3", ".5.5" (two numbers).
private struct Scanner {
    let bytes: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var peek: UInt8? { i < bytes.count ? bytes[i] : nil }
    mutating func advance() { i += 1 }

    mutating func skipSeparators() {
        while let c = peek, c == 32 || c == 44 || c == 9 || c == 10 || c == 13 { i += 1 }
    }

    /// An arc flag: a single 0 or 1, which may run straight into the next number.
    mutating func flag() -> Bool? {
        skipSeparators()
        guard let c = peek, c == 48 || c == 49 else { return nil }
        i += 1
        return c == 49
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        let begin = i
        if let c = peek, c == 43 || c == 45 { i += 1 }   // + -
        var digits = false, dot = false
        while let c = peek {
            if c >= 48 && c <= 57 { digits = true; i += 1 }
            else if c == 46 && !dot { dot = true; i += 1 }
            else { break }
        }
        if digits, let c = peek, c == 101 || c == 69 {   // exponent
            let save = i
            i += 1
            if let s = peek, s == 43 || s == 45 { i += 1 }
            var expDigits = false
            while let d = peek, d >= 48 && d <= 57 { expDigits = true; i += 1 }
            if !expDigits { i = save }
        }
        guard digits, let value = Double(String(decoding: bytes[begin..<i], as: UTF8.self)) else {
            i = begin
            return nil
        }
        return CGFloat(value)
    }
}

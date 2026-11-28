// Draws Visor's app icon and menu bar icon, release and dev.
//
//   swift scripts/make-icon.swift      # writes Resources/AppIcon.icns, AppIcon-1024.png and MenuIcon.png,
//                                      # plus AppIcon-Dev.icns, AppIcon-Dev-1024.png and MenuIcon-Dev.png
//
// The artwork is a 100-unit design (the same as the naming mockup): a dark
// purple squircle, the notch as a black visor, a glow line in Claude orange,
// Copilot purple and mint, and two small eyes.
//
// The dev variants are the "Blueprint" look that scripts/bundle.sh copies into
// local (non-release) bundles under the release names: the visor drawn in white
// line work on a blueprint-blue grid, and a menu icon with three hatch cuts.
// Drawing is deterministic, so rerunning leaves the release files byte-identical.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A context whose coordinates are the 100-unit design, y pointing down like the SVG.
func designContext(_ ctx: CGContext, rect: CGRect) {
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: rect.width / 100, y: -rect.height / 100)
}

func visorPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 14, y: 40))
    p.addCurve(to: CGPoint(x: 86, y: 40), control1: CGPoint(x: 24, y: 28), control2: CGPoint(x: 76, y: 28))
    p.addLine(to: CGPoint(x: 86, y: 50))
    p.addCurve(to: CGPoint(x: 14, y: 50), control1: CGPoint(x: 76, y: 60), control2: CGPoint(x: 24, y: 60))
    p.closeSubpath()
    return p
}

func appIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let size = CGFloat(pixels)
    // Apple's icon grid: the shape fills 824 of 1024, with a soft shadow below.
    let inset = size * 100 / 1024
    let shape = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = CGPath(roundedRect: shape, cornerWidth: shape.width * 0.225, cornerHeight: shape.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: color(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x14112A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x3A2F6B), color(0x14112A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: shape.maxY), end: CGPoint(x: 0, y: shape.minY), options: [])

    designContext(ctx, rect: shape)
    // The visor.
    ctx.addPath(visorPath())
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    drawGlow(ctx)
    // Two eyes.
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: 34.5, y: 43.5, width: 7, height: 7))
    ctx.fillEllipse(in: CGRect(x: 58.5, y: 43.5, width: 7, height: 7))
    // A quiet line below, like a status row.
    ctx.setStrokeColor(color(0xFFFFFF, 0.25))
    ctx.setLineWidth(4)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 30, y: 70))
    ctx.addLine(to: CGPoint(x: 70, y: 70))
    ctx.strokePath()
    ctx.restoreGState()
    return rep
}

/// The menu bar icon: the visor with its eyes cut out, as a template image.
func menuIcon(scale: Int) -> NSBitmapImageRep {
    let width = 22 * scale, height = 16 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // Map the visor's 72x32 area (x 14...86, y 31...59) into the image.
    ctx.translateBy(x: 0, y: CGFloat(height))
    let s = CGFloat(width) / 76
    ctx.scaleBy(x: s, y: -s)
    ctx.translateBy(x: -12, y: -29 + (CGFloat(height) / s - 32) / 2)
    ctx.addPath(visorPath())
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: CGRect(x: 33.5, y: 41, width: 9, height: 9))
    ctx.fillEllipse(in: CGRect(x: 57.5, y: 41, width: 9, height: 9))
    // Points, set after drawing so the drawing above works in pixels.
    rep.size = NSSize(width: 22, height: 16)
    return rep
}

/// The brand glow line, orange to purple to mint, in design coordinates.
func drawGlow(_ ctx: CGContext) {
    let glow = CGMutablePath()
    glow.move(to: CGPoint(x: 22, y: 45))
    glow.addCurve(to: CGPoint(x: 78, y: 45), control1: CGPoint(x: 30, y: 39), control2: CGPoint(x: 70, y: 39))
    ctx.saveGState()
    ctx.addPath(glow.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    let rainbow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [color(0xD97757), color(0xA78BFA), color(0x7EE0A0)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(rainbow, start: CGPoint(x: 20, y: 0), end: CGPoint(x: 80, y: 0), options: [])
    ctx.restoreGState()
}

/// Strokes straight segments in design coordinates.
func strokeLines(_ ctx: CGContext, _ segments: [(CGPoint, CGPoint)], color c: CGColor, width: CGFloat, dash: [CGFloat] = []) {
    ctx.saveGState()
    ctx.setStrokeColor(c)
    ctx.setLineWidth(width)
    ctx.setLineCap(.butt)
    ctx.setLineDash(phase: 0, lengths: dash)
    for (a, b) in segments {
        ctx.move(to: a)
        ctx.addLine(to: b)
    }
    ctx.strokePath()
    ctx.restoreGState()
}

/// The dev app icon ("Blueprint"): the release silhouette on blueprint blue with a
/// 10-unit grid, the visor as an inked outline with a dimension line and a dashed
/// centre line, the glow kept, the status row dashed. No eyes.
func devAppIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let size = CGFloat(pixels)
    let inset = size * 100 / 1024
    let shape = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = CGPath(roundedRect: shape, cornerWidth: shape.width * 0.225, cornerHeight: shape.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: color(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x0F2E5C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x2A6CC0), color(0x0F2E5C)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: shape.maxY), end: CGPoint(x: 0, y: shape.minY), options: [])

    designContext(ctx, rect: shape)
    // The drafting grid, every 10 units.
    let ticks = stride(from: CGFloat(10), through: 90, by: 10)
    strokeLines(ctx, ticks.map { (CGPoint(x: $0, y: 0), CGPoint(x: $0, y: 100)) } + ticks.map { (CGPoint(x: 0, y: $0), CGPoint(x: 100, y: $0)) },
                color: color(0xFFFFFF, 0.13), width: 0.6)
    // Dashed centre line and the dimension line above the visor.
    strokeLines(ctx, [(CGPoint(x: 6, y: 45), CGPoint(x: 94, y: 45))], color: color(0xFFFFFF, 0.35), width: 0.8, dash: [3, 2])
    strokeLines(ctx, [(CGPoint(x: 14, y: 22), CGPoint(x: 14, y: 27)), (CGPoint(x: 86, y: 22), CGPoint(x: 86, y: 27)),
                      (CGPoint(x: 14, y: 24.5), CGPoint(x: 86, y: 24.5))], color: color(0xFFFFFF, 0.6), width: 1)
    // The visor, inked.
    ctx.addPath(visorPath())
    ctx.setFillColor(color(0x0A1E3C))
    ctx.fillPath()
    ctx.addPath(visorPath())
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(1.8)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    drawGlow(ctx)
    // The status row, dashed.
    strokeLines(ctx, [(CGPoint(x: 30, y: 70), CGPoint(x: 70, y: 70))], color: color(0xFFFFFF, 0.45), width: 4, dash: [5, 4])
    ctx.restoreGState()
    return rep
}

/// The dev menu bar icon: the visor with three slanted hatch cuts instead of the
/// eyes, as a template image (black and clear only, tinted by macOS).
func devMenuIcon(scale: Int) -> NSBitmapImageRep {
    let width = 22 * scale, height = 16 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // The same mapping as menuIcon(scale:).
    ctx.translateBy(x: 0, y: CGFloat(height))
    let s = CGFloat(width) / 76
    ctx.scaleBy(x: s, y: -s)
    ctx.translateBy(x: -12, y: -29 + (CGFloat(height) / s - 32) / 2)
    ctx.addPath(visorPath())
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.setBlendMode(.clear)
    strokeLines(ctx, [(CGPoint(x: 31, y: 56), CGPoint(x: 39, y: 34)), (CGPoint(x: 45, y: 56), CGPoint(x: 53, y: 34)),
                      (CGPoint(x: 59, y: 56), CGPoint(x: 67, y: 34))], color: color(0x000000), width: 5.6)
    rep.size = NSSize(width: 22, height: 16)
    return rep
}

/// Writes an .icns from an .iconset of every size iconutil wants; true when iconutil succeeded.
func writeIcns(_ name: String, _ draw: (Int) -> NSBitmapImageRep) throws -> Bool {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Visor-\(UUID().uuidString).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let file = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try draw(points * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(file))
        }
    }
    // A standalone script can't reach the app's Shell.run, so it starts iconutil itself.
    let iconutil = try Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"),
                                   arguments: ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent(name).path])
    iconutil.waitUntilExit()
    try? FileManager.default.removeItem(at: iconset)
    return iconutil.terminationStatus == 0
}

// App icons: an .iconset folder each, then iconutil turns it into an .icns.
let releaseOK = try writeIcns("AppIcon.icns", appIcon(pixels:))
try appIcon(pixels: 1024).representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent("AppIcon-1024.png"))
let devOK = try writeIcns("AppIcon-Dev.icns", devAppIcon(pixels:))
try devAppIcon(pixels: 1024).representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent("AppIcon-Dev-1024.png"))

// Menu bar icons at 2x (template images are tinted by macOS).
try menuIcon(scale: 2).representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent("MenuIcon.png"))
try devMenuIcon(scale: 2).representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent("MenuIcon-Dev.png"))
guard releaseOK && devOK else {
    FileHandle.standardError.write("iconutil failed (release \(releaseOK ? "ok" : "failed"), dev \(devOK ? "ok" : "failed"))\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote Resources/AppIcon.icns, AppIcon-1024.png, MenuIcon.png and their -Dev variants")

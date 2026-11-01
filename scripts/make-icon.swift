// Draws Visor's app icon and menu bar icon.
//
//   swift scripts/make-icon.swift      # writes Resources/AppIcon.icns and Resources/MenuIcon.png
//
// The artwork is a 100-unit design (the same as the naming mockup): a dark
// purple squircle, the notch as a black visor, a glow line in Claude orange,
// Copilot purple and mint, and two small eyes.
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
    // The glow line, orange to purple to mint.
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

// App icon: an .iconset folder, then iconutil turns it into AppIcon.icns.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Visor-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try appIcon(pixels: points * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
try appIcon(pixels: 1024).representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent("AppIcon-1024.png"))

// Menu bar icon at 2x (template images are tinted by macOS).
try menuIcon(scale: 2).representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent("MenuIcon.png"))
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns, AppIcon-1024.png and MenuIcon.png" : "iconutil failed")

import AppKit

/// The office room's own palette and room-scale sizes: the pixel world's
/// purples and tiny labels drawn over the 2x room, apart from the app's design
/// system by the epic (scripts/design-literals.txt skips this file, like the
/// sprite files). Status that the rest of Visor also shows (approval, question,
/// context, the hover card) takes its colours and type from Theme and DS in
/// OfficeLayerView instead.
enum OfficeArt {
    /// Name tags under the sprites, and the "+n" tag of more helpers.
    static let tagInk = NSColor(hex: 0xE9E6F5)
    static let helperInk = NSColor(hex: 0xF2B49C)
    /// The sheet of paper a finished helper hands back.
    static let paper = NSColor(hex: 0xF2EBD6)
    /// The track of the context bar over a head.
    static let healthTrack = NSColor(hex: 0x141018)
    /// Bubbles drawn in the room's colours: thinking, idle and done.
    static let thinkingFill = NSColor(hex: 0x2A2838)
    static let thinkingInk = NSColor(hex: 0xC9C5E0)
    static let idleInk = NSColor(hex: 0xA9A4C8)
    static let doneFill = NSColor(hex: 0x3FBF5F)
    /// The stations' names (TERMINAL, DOCS, YOU, WEB, BREAK).
    static let stationInk = NSColor(hex: 0x8C86B0)

    /// Room-scale type, below the app's type scale so it fits the pixel room.
    static let tagSize: CGFloat = 8
    static let helperTagSize: CGFloat = 7.5
    static let tableLabelSize: CGFloat = 7
    static let stationLabelSize: CGFloat = 6.5
    static let glyphSize: CGFloat = 10
    static let idleGlyphSize: CGFloat = 8

    /// Corners and strengths of the room's small shapes.
    static let shadeRadius: CGFloat = 2.5
    static let shadeStrength: CGFloat = 0.3
    static let bubbleRadius: CGFloat = 4
    static let healthRadius: CGFloat = 1
    static let helperTagRadius: CGFloat = 4
    static let helperTagBacking: CGFloat = 0.45
    static let paperRadius: CGFloat = 1
}

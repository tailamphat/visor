import Foundation
import Testing
@testable import VisorCore

/// A grid of sRGB colours: 17 steps per channel (0, 16, ... 240, 255).
private let hexGrid: [UInt32] = {
    let steps: [UInt32] = (0..<16).map { $0 * 16 } + [255]
    return steps.flatMap { r in steps.flatMap { g in steps.map { b in (r << 16) | (g << 8) | b } } }
}()

@Suite("Design contrast")
struct DesignContrastTests {
    private typealias C = DesignContrast
    private typealias P = DesignTokens.Palette

    /// `--v-on-accent: var(--v-surface);` in the tokens block.
    static let siteOnColour = try! NSRegularExpression(pattern: #"--v-on-([a-z0-9-]+): var\(--v-(surface|text-primary)\);"#)
    /// `--v-k-accent: var(--v-accent) var(--v-on-accent) 5.77;` in the contrast block.
    static let pageContrastRow = try! NSRegularExpression(pattern: #"--v-k-([a-z0-9-]+): var\(--v-[a-z0-9-]+\) var\(--v-on-[a-z0-9-]+\) ([0-9.]+);"#)

    /// WCAG 2 relative luminance and contrast ratio.
    @Test func luminanceMatchesWCAG() {
        #expect(C.luminance(0xFFFFFF) == 1)
        #expect(C.luminance(0x000000) == 0)
        #expect(abs(C.ratio(0xFFFFFF, 0x000000) - 21) < 1e-9)
        #expect(abs(C.ratio(0x000000, 0xFFFFFF) - 21) < 1e-9)
        // WCAG's reference grey: #777777 on white is just under 4.5.
        #expect(abs(C.ratio(0x777777, 0xFFFFFF) - 4.48) < 0.01)
        #expect(C.composite(0xFFFFFF, opacity: 0.5, over: 0x000000) == 0x808080)
    }

    /// Text from TypeScale.xl up counts as large; everything smaller is body text.
    @Test func largeTextStartsAtXL() {
        #expect(C.use(forType: DesignTokens.TypeScale.lg) == .text)
        #expect(C.use(forType: DesignTokens.TypeScale.xl) == .largeText)
        #expect(C.use(forType: DesignTokens.TypeScale.display) == .largeText)
        #expect(C.Use.text.minimum == 4.5)
        #expect(C.Use.largeText.minimum == 3)
        #expect(C.Use.icon.minimum == 3)
    }

    /// Every colour a component or a plugin can use as a solid fill has a row.
    @Test func pairingTableCoversEveryFill() {
        let names = Set(C.fills.map(\.name))
        for name in ["surface", "raised", "deemphasis", "accentTrack", "accent", "warning", "awake", "good", "clash",
                     "question", "critical", "stuck", "claude", "localBuild", "onPace", "violet", "mint", "rose"] {
            #expect(names.contains(name), "\(name) missing from DesignContrast.fills")
        }
        for colour in PluginColor.allCases {
            #expect(C.fills.contains { $0.hex == colour.hex }, "plugin colour \(colour.rawValue) missing")
        }
        for fill in C.fills {
            #expect(fill.on == P.surface || fill.on == P.textPrimary, "\(fill.name)")
        }
    }

    /// Light fills get dark text, dark fills light text: the better of the two.
    @Test func onColourIsTheBetterOfBlackAndWhite() {
        for fill in C.fills {
            let other = fill.on == P.surface ? P.textPrimary : P.surface
            #expect(C.ratio(fill.on, fill.hex) >= C.ratio(other, fill.hex), "\(fill.name)")
        }
        for light in [P.accent, P.warning, P.critical, P.stuck, P.mint] { #expect(C.on(light) == P.surface) }
        for dark in [P.surface, P.raised, P.deemphasis, P.accentTrack] { #expect(C.on(dark) == P.textPrimary) }
    }

    /// Any hex (a plugin's accent) gets text that reads at 4.5:1 or better.
    @Test func anyHexGetsAtLeastAAText() {
        let worst = hexGrid.map { C.ratio(C.on($0), $0) }.min() ?? 0
        #expect(worst >= 4.5)
    }

    /// Every text and icon a shared component can draw meets its minimum.
    @Test func everyComponentPairMeetsItsMinimum() {
        #expect(C.pairs.count > 250)
        let failing = C.pairs.filter { !$0.passes }
        for pair in failing {
            Issue.record("\(pair.name): \(String(format: "%.2f", pair.ratio)) < \(pair.use.minimum)")
        }
        #expect(failing.isEmpty)
    }

    /// Holding a button moves its fill away from its text: the ratio never drops.
    @Test func heldFillKeepsTheContrast() {
        for hex in hexGrid {
            #expect(C.ratio(C.on(hex), C.pressed(hex)) >= C.ratio(C.on(hex), hex) - 1e-9, "\(String(format: "%06X", hex))")
        }
        #expect(C.pairs.contains { $0.name.contains("held") })
        #expect(C.pairs.contains { $0.name.contains("on the accentTrack") })
    }

    /// The pairs cover the components the request names.
    @Test func pairsNameEveryComponent() {
        for part in ["CardButton.primary", "CardButton.secondary", "Badge.solid", "Badge.neutral", "bannerCard",
                     "compactBanner", "ConsentButton.allow", "ConsentButton.always", "ConsentButton.deny", "PillButton",
                     "SectionHeader", "meter", "textMuted on raised", "textSecondary on surface", "plugin text"] {
            #expect(C.pairs.contains { $0.name.contains(part) }, "no pair for \(part)")
        }
    }

    /// A plugin's manifest accent is drawn as text, icons and meter fills on the
    /// black notch and inside banners: once made readable, it reads everywhere.
    @Test func anyPluginAccentReadsOnSurface() {
        let track = C.composite(P.textPrimary, opacity: PluginPieces.trackFill, over: P.surface)
        let named = PluginColor.allCases.filter { $0 != .accent }.map(\.hex)
        var failures: [String] = []
        for hex in hexGrid {
            let accent = C.readableAccent(hex)
            let grounds = C.pluginGrounds(accent: accent)
            let text = grounds.map { C.ratio(accent, $0) }.min() ?? 0
            // Every named colour also reads inside a banner tinted with this accent.
            let banner = C.composite(accent, opacity: DesignComponents.Banner.fill, over: P.surface)
            let namedInBanner = named.map { C.ratio($0, banner) }.min() ?? 0
            if text < 4.5 || C.ratio(accent, track) < 3 || namedInBanner < 4.5 {
                failures.append(String(format: "%06X -> %06X", hex, accent))
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        // A readable accent is kept as it is; a dark one is lightened.
        #expect(C.readableAccent(P.accent) == P.accent)
        #expect(C.readableAccent(0x2DD4BF) == 0x2DD4BF)
        #expect(C.readableAccent(0x202020) != 0x202020)
        #expect(C.luminance(C.readableAccent(0x202020)) > C.luminance(0x202020))
    }

    /// The website's on-colours (generated by scripts/site-tokens.sh) match the table.
    @Test func siteOnColoursMatchTheTable() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../docs/index.html").standardized
        let text = try String(contentsOf: url, encoding: .utf8)
        var found: [String: UInt32] = [:]
        for m in Self.siteOnColour.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let n = Range(m.range(at: 1), in: text), let h = Range(m.range(at: 2), in: text) else { continue }
            found[String(text[n])] = text[h] == "surface" ? P.surface : P.textPrimary
        }
        for step in DesignScale.palette {
            let kebab = step.name.reduce(into: "") { out, c in out += c.isUppercase ? "-" + c.lowercased() : String(c) }
            let expected = C.on(UInt32(step.value))
            #expect(found[kebab] == expected, "--v-on-\(kebab)")
        }
    }

    /// The design system page's Contrast table (its generated contrast block) has
    /// one row per fill of the pairing table, with the same ratio.
    @Test func pageContrastRowsMatchTheTable() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../docs/design-system.html").standardized
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [String: Double] = [:]
        for m in Self.pageContrastRow.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let n = Range(m.range(at: 1), in: text), let r = Range(m.range(at: 2), in: text) else { continue }
            rows[String(text[n])] = Double(text[r])
        }
        #expect(rows.count == C.fills.count)
        for fill in C.fills {
            let kebab = fill.name.reduce(into: "") { out, c in out += c.isUppercase ? "-" + c.lowercased() : String(c) }
            let ratio = try #require(rows[kebab], "no row for \(fill.name)")
            #expect(abs(ratio - C.ratio(fill.on, fill.hex)) < 0.006, "\(fill.name)")
        }
    }
}

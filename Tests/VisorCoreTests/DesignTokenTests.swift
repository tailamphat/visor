import Foundation
import Testing
@testable import VisorCore

private func name(_ value: Double, _ steps: [DesignScale.Step]) -> String {
    DesignScale.snap(value, to: steps).name
}

@Suite("Design tokens")
struct DesignTokenTests {
    static let groupLine = try? NSRegularExpression(pattern: #"^\s*public enum (\w+) \{"#)
    static let valueLine = try? NSRegularExpression(
        pattern: #"^\s*public static let (\w+): (UInt32|Double) = (0x[0-9A-Fa-f]+|[0-9.]+)$"#)

    @Test func everyScaleIsStrictlyIncreasing() {
        for steps in [DesignScale.typeScale, DesignScale.radius, DesignScale.fill, DesignScale.space] {
            #expect(!steps.isEmpty)
            for (a, b) in zip(steps, steps.dropFirst()) {
                #expect(a.value < b.value, "\(a.name) before \(b.name)")
            }
        }
    }

    @Test func tokenNamesAreUnique() {
        var seen = Set<String>()
        for entry in DesignScale.all {
            let key = entry.group + "." + entry.name
            #expect(!seen.contains(key), "\(key) twice")
            seen.insert(key)
        }
    }

    @Test(arguments: [
        (8.0, "xs"), (8.5, "xs"), (9, "xs"), (9.5, "xs"),
        (10, "sm"), (10.5, "sm"),
        (11, "base"), (11.5, "base"),
        (12, "md"), (12.5, "md"),
        (13, "lg"), (14, "lg"),
        (15, "xl"), (16, "xl"), (17, "xl"), (18, "xl"), (20, "xl"),
        (26, "display"), (28, "display"),
    ])
    func everyFontLiteralSnapsToTheScale(value: Double, expected: String) {
        #expect(name(value, DesignScale.typeScale) == expected)
    }

    @Test(arguments: [
        (2.0, "xs"), (3, "xs"), (4, "xs"),
        (4.5, "sm"), (5, "sm"), (6, "sm"), (7, "sm"),
        (8, "md"), (9, "md"), (10, "md"),
        (12, "lg"), (14, "lg"),
    ])
    func radiiSnap(value: Double, expected: String) {
        #expect(name(value, DesignScale.radius) == expected)
    }

    @Test(arguments: [
        (0.05, "faint"), (0.06, "faint"),
        (0.07, "subtle"), (0.08, "subtle"), (0.09, "subtle"), (0.1, "subtle"),
        (0.12, "medium"), (0.14, "medium"),
        (0.15, "strong"), (0.16, "strong"),
        (0.22, "heavy"), (0.25, "heavy"),
    ])
    func fillsSnap(value: Double, expected: String) {
        #expect(name(value, DesignScale.fill) == expected)
    }

    @Test(arguments: [
        (0.0, "none"), (1, "hair"), (2, "xxs"), (3, "xxs"), (4, "xs"), (5, "xs"),
        (6, "sm"), (7, "sm"), (8, "md"), (9, "md"), (10, "lg"), (11, "lg"),
        (12, "xl"), (14, "xl"), (16, "xxl"), (18, "xxl"), (20, "xxxl"), (22, "xxxl"), (30, "xxxl"),
    ])
    func spacingSnaps(value: Double, expected: String) {
        #expect(name(value, DesignScale.space) == expected)
    }

    @Test func tiesGoToTheSmallerStep() {
        #expect(name(10.5, DesignScale.typeScale) == "sm")
        #expect(name(12.5, DesignScale.typeScale) == "md")
        #expect(name(9, DesignScale.space) == "md")
        #expect(name(4, DesignScale.radius) == "xs")
        #expect(name(0.1, DesignScale.fill) == "subtle")
        #expect(name(0.14, DesignScale.fill) == "medium")
        #expect(name(14, DesignScale.radius) == "lg", "above the top step clamps")
        #expect(name(1, DesignScale.radius) == "xs", "below the bottom step clamps")
    }

    @Test func onScaleValuesStayPut() {
        for steps in [DesignScale.typeScale, DesignScale.radius, DesignScale.fill, DesignScale.space] {
            for step in steps {
                #expect(DesignScale.snap(step.value, to: steps) == step)
            }
        }
    }

    @Test func themeColoursKeepTheirValues() {
        typealias P = DesignTokens.Palette
        #expect(P.surface == 0x000000)
        #expect(P.raised == 0x1A1A19)
        #expect(P.textPrimary == 0xFFFFFF)
        #expect(P.textSecondary == 0xC3C2B7)
        #expect(P.textMuted == 0x8A8980)
        #expect(P.accent == 0x3987E5)
        #expect(P.accentTrack == 0x184F95)
        #expect(P.deemphasis == 0x4A4A46)
        #expect(P.claude == 0xD97757)
        #expect(P.good == 0x0CA30C)
        #expect(P.onPace == 0x5FC95F)
        #expect(P.clash == 0xFF8A3D)
        #expect(P.warning == 0xFAB219)
        #expect(P.question == 0x5AA2F0)
        #expect(P.critical == 0xD03B3B)
        #expect(P.stuck == 0xFF6B6B)
        #expect(DesignTokens.Size.bar == 4)
        #expect(DesignTokens.Size.cardInset == 10)
    }

    @Test func paletteCoversSharedHexes() {
        typealias P = DesignTokens.Palette
        #expect(P.mint == 0x7EE0A0)
        #expect(P.rose == 0xFF8F86)
        #expect(P.allowText == 0x06260F)
        #expect(P.alwaysText == 0xC9F3D6)
        #expect(P.denyText == 0xFF9D95)
        #expect(P.stuck == 0xFF6B6B)
    }

    /// The keep-awake cup has its own amber: the closed notch shows the approval
    /// amber only for an approval.
    @Test func paletteHasAwakeApartFromWarning() {
        let awake = DesignScale.palette.first { $0.name == "awake" }
        #expect(awake?.value == Double(0xFFC46B))
        #expect(awake?.value != Double(DesignTokens.Palette.warning))
    }

    /// The site generator (DS3) reads `DesignTokens.swift` as text: one
    /// `static let name: Type = literal` per value, inside `enum Group`.
    @Test func sourceLinesParse() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VisorCore/DesignTokens.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let group = try #require(Self.groupLine)
        let line = try #require(Self.valueLine)
        var current = ""
        var parsed: [String: Double] = [:]
        for raw in text.components(separatedBy: "\n") {
            let range = NSRange(raw.startIndex..., in: raw)
            if let m = group.firstMatch(in: raw, range: range), let r = Range(m.range(at: 1), in: raw) {
                current = String(raw[r])
            } else if let m = line.firstMatch(in: raw, range: range),
                      let n = Range(m.range(at: 1), in: raw), let v = Range(m.range(at: 3), in: raw) {
                let literal = String(raw[v])
                let value = literal.hasPrefix("0x") ? Double(UInt32(literal.dropFirst(2), radix: 16) ?? 0) : Double(literal) ?? -1
                parsed[current + "." + raw[n]] = value
            }
        }
        #expect(parsed.count == DesignScale.all.count)
        for entry in DesignScale.all {
            #expect(parsed[entry.group + "." + entry.name] == entry.value, "\(entry.group).\(entry.name)")
        }
    }
}

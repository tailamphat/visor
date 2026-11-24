import Foundation
import Testing

/// Views that have moved onto the design system keep no literal colours, type
/// sizes, radii or white fills: each value comes from `DS`, `Theme` or a shared
/// component. Add a folder (or a single `.swift` file) under `Sources/Visor/`
/// once its views are migrated.
@Suite("Design adoption")
struct DesignAdoptionTests {
    static let migrated = ["Usage", "Music", "Clipboard", "Agents", "Notch", "Bar", "App/Intro.swift"]

    /// Files the scan skips, by path under `Sources/Visor/`. Theme.swift is the
    /// token entry point (it turns `DesignTokens.Palette` into SwiftUI colours) and
    /// holds the agents' brand marks; `themeHexesAreOnlyBrandMarks` guards it.
    static let exempt: Set<String> = ["Notch/Theme.swift"]

    /// What a literal looks like in SwiftUI code, with a name for the failure message.
    static let literals: [(name: String, pattern: String)] = [
        ("hex colour", #"Color\(hex:"#),
        // Any size that isn't a token or a shared component's measurement.
        ("font size", #"\.system\(size:(?! *(DS\.|CGFloat\(Spec))"#),
        ("corner radius", #"cornerRadius:(?! *(DS\.|CGFloat\(Spec))"#),
        // A fractional strength; opacity(0) and a ternary (whole-view dimming) are fine.
        ("opacity fill", #"opacity\(0?\.[0-9]"#),
        ("white", #"Color\.white"#),
        ("named colour", #"(\(|\?\?) *\.(white|black|gray)\b"#),
        ("rgb colour", #"(?<!NS)Color\((red|white|hue):"#),
    ]

    /// A six-digit hex colour literal, for `themeHexesAreOnlyBrandMarks`.
    static let hexLiteral = try! NSRegularExpression(pattern: #"0x[0-9A-Fa-f]{6}\b"#)

    /// The patterns, compiled once.
    static let regexes: [(name: String, regex: NSRegularExpression)] = literals.map { ($0.name, try! NSRegularExpression(pattern: $0.pattern)) }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Sources/Visor").standardized

    /// The Swift files of a folder, or the one file, under `Sources/Visor/`, minus `exempt`.
    private static func sources(_ path: String) throws -> [URL] {
        let url = root.appendingPathComponent(path)
        if path.hasSuffix(".swift") {
            return FileManager.default.fileExists(atPath: url.path) ? [url] : []
        }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !exempt.contains("\(path)/\($0.lastPathComponent)") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every `file:line (kind)` with a literal in `folder`.
    static func hits(in folder: String) throws -> [String] {
        var out: [String] = []
        for file in try sources(folder) {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                for (name, regex) in regexes where matches(regex, line) {
                    out.append("\(file.lastPathComponent):\(index + 1) (\(name))")
                }
            }
        }
        return out
    }

    @Test(arguments: migrated)
    func viewsUseOnlyTokens(folder: String) throws {
        #expect(!(try Self.sources(folder)).isEmpty, "no Swift files in Sources/Visor/\(folder)")
        let found = try Self.hits(in: folder)
        #expect(found.isEmpty, "\(found.count) literal(s) in \(folder): \(found.joined(separator: ", "))")
    }

    /// Theme.swift is exempt from the scan, so it must not collect one-off
    /// colours: its only hex literals are the agents' brand marks in `AgentStyle`.
    @Test func themeHexesAreOnlyBrandMarks() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("Notch/Theme.swift"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("enum AgentStyle") }, "AgentStyle not found")
        let early = lines[..<start].enumerated().filter { Self.matches(Self.hexLiteral, $0.element) }.map { "Theme.swift:\($0.offset + 1)" }
        #expect(early.isEmpty, "hex colours outside AgentStyle: \(early.joined(separator: ", "))")
    }

    /// The scan itself finds each kind of literal.
    @Test func patternsCatchLiterals() {
        // Each kind of literal, in every spelling Usage had before it moved.
        let samples: [String: [String]] = [
            "hex colour": ["Color(hex: 0x1A1A19)"],
            "font size": [".font(.system(size: 11))", ".font(.system(size: large ? 18 : 13, weight: .semibold))"],
            "corner radius": ["RoundedRectangle(cornerRadius: 9)", "RoundedRectangle(cornerRadius: big ? 9 : 6)"],
            "opacity fill": ["Color.white.opacity(0.08)", "Theme.accent.opacity(.5)"],
            "white": ["Color.white"],
            "named colour": ["colors[name] ?? .gray", "Circle().fill(.white)", ".fill(.gray)", ".foregroundStyle(.black)"],
            "rgb colour": ["Color(red: 1, green: 0.4, blue: 0.3)", "Color(white: 0.2)"],
        ]
        #expect(Set(samples.keys) == Set(Self.regexes.map(\.name)))
        for literal in Self.regexes {
            for sample in samples[literal.name] ?? [] {
                #expect(Self.matches(literal.regex, sample), "\(literal.name) misses \(sample)")
            }
        }
        let clean = ".font(DS.font(.sm)) .fill(DS.Fill.subtle) cornerRadius: DS.Radius.md .opacity(shown ? 1 : 0.5)"
            + " .shadow(color: .black.opacity(dragged ? 0.5 : 0)) .fill(on ? DS.Fill.strong : .clear) .opacity(0)"
        for literal in Self.regexes {
            #expect(!Self.matches(literal.regex, clean), "\(literal.name)")
        }
    }
}

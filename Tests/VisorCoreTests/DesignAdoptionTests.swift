import Foundation
import Testing

/// Every view under `Sources/Visor/` (Plugins included) keeps no literal colours,
/// type sizes, radii or white fills: each value comes from `DS`, `Theme` or a
/// shared component. The patterns and the skipped paths live in
/// `scripts/design-literals.txt`, which `scripts/check.sh` reads too, so the
/// test and the check always agree.
@Suite("Design adoption")
struct DesignAdoptionTests {
    struct Rules {
        var literals: [(name: String, regex: NSRegularExpression)] = []
        /// Paths under the repo: a file, or a folder ending in "/".
        var skips: [String] = []
    }

    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../..").standardized
    private static let root = repo.appendingPathComponent("Sources/Visor")

    /// Compiles a pattern from the list (each one once, in `rules`).
    private static let compile: (String) -> NSRegularExpression = { try! NSRegularExpression(pattern: $0) }

    /// The shared list, parsed once: `literal<TAB>name<TAB>regex` and `skip<TAB>path<TAB>why`.
    static let rules: Rules = {
        var rules = Rules()
        let url = repo.appendingPathComponent("scripts/design-literals.txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for line in text.components(separatedBy: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3, !line.hasPrefix("#") else { continue }
            switch fields[0] {
            case "literal": rules.literals.append((fields[1], compile(fields[2])))
            case "skip": rules.skips.append(fields[1])
            default: continue
            }
        }
        return rules
    }()

    /// A six-digit hex colour literal, for `themeHexesAreOnlyBrandMarks`.
    static let hexLiteral = try! NSRegularExpression(pattern: #"0x[0-9A-Fa-f]{6}\b"#)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func skipped(_ path: String) -> Bool {
        rules.skips.contains { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 }
    }

    /// Every Swift file under `Sources/Visor/`, as a repo path, minus the skips.
    static func sources() -> [String] {
        let prefix = repo.path + "/"
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.standardized.path }
            .filter { $0.hasSuffix(".swift") }
            .map { String($0.dropFirst(prefix.count)) } ?? []
        return files.filter { !skipped($0) }.sorted()
    }

    /// Every `file:line (kind)` with a literal in `text`; comment lines are skipped.
    static func hits(_ path: String, _ text: String) -> [String] {
        var out: [String] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            for (name, regex) in rules.literals where matches(regex, line) {
                out.append("\(path):\(index + 1) (\(name))")
            }
        }
        return out
    }

    @Test func viewsUseOnlyTokens() throws {
        let files = Self.sources()
        #expect(files.count > 50, "found only \(files.count) Swift files under Sources/Visor")
        #expect(files.contains("Sources/Visor/Plugins/PluginsView.swift"))
        var found: [String] = []
        for path in files {
            found += Self.hits(path, try String(contentsOf: Self.repo.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(found.isEmpty, "\(found.count) literal(s): \(found.joined(separator: ", "))")
    }

    /// A bare `.white`/`.black` (not `DS.Fill.white(...)`, not the shadow's black).
    static let bareBlackOrWhite = try! NSRegularExpression(pattern: #"(?<![A-Za-z])\.(white|black)\b(?!\.opacity\(shown)"#)
    /// A stored text colour a caller could set (`var foreground: Color = .white`).
    static let storedTextColour = try! NSRegularExpression(pattern: #"\bvar (foreground|text|textColor): Color\s*(=|$)"#)

    /// Components that fill with a tint draw their text in the tint's on-colour
    /// (`DesignContrast.on`), never a fixed white or black, and take no text
    /// colour from the caller.
    @Test func tintedFillsUseTheOnColour() throws {
        let banned = [Self.bareBlackOrWhite, Self.storedTextColour]
        for path in ["DesignSystem/SharedComponents.swift", "Shared/Components.swift"] {
            let text = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            let code = text.components(separatedBy: "\n").enumerated()
                .filter { !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for (index, line) in code {
                for regex in banned where Self.matches(regex, line) {
                    Issue.record("\(path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
            #expect(text.contains("onColour"), "\(path) doesn't use the on-colour")
        }
    }

    /// Each skip names a real file or folder, so a stale entry can't hide a new file later.
    @Test func skipsExist() {
        #expect(!Self.rules.skips.isEmpty)
        for skip in Self.rules.skips {
            var folder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: Self.repo.appendingPathComponent(skip).path, isDirectory: &folder)
            #expect(exists && folder.boolValue == skip.hasSuffix("/"), "stale skip \(skip)")
        }
    }

    /// Theme.swift is skipped, so it must not collect one-off colours: its only
    /// hex literals are the agents' brand marks in `AgentStyle`.
    @Test func themeHexesAreOnlyBrandMarks() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("Notch/Theme.swift"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("enum AgentStyle") }, "AgentStyle not found")
        let early = lines[..<start].enumerated().filter { Self.matches(Self.hexLiteral, $0.element) }.map { "Theme.swift:\($0.offset + 1)" }
        #expect(early.isEmpty, "hex colours outside AgentStyle: \(early.joined(separator: ", "))")
    }

    /// The scan itself finds each kind of literal.
    @Test func patternsCatchLiterals() {
        // Each kind of literal, in every spelling the views had before they moved.
        let samples: [String: [String]] = [
            "hex colour": ["Color(hex: 0x1A1A19)", "NSColor(hex: 0xA78BFA)"],
            "font size": [".font(.system(size: 11))", ".font(.system(size: large ? 18 : 13, weight: .semibold))"],
            "corner radius": ["RoundedRectangle(cornerRadius: 9)", "RoundedRectangle(cornerRadius: big ? 9 : 6)",
                              "Path(roundedRect: rect, cornerRadius: size.height / 2)"],
            "opacity fill": ["Color.white.opacity(0.08)", "Theme.accent.opacity(.5)", ".foreground.opacity(0.16)"],
            "white": ["Color.white"],
            "named colour": ["colors[name] ?? .gray", "Circle().fill(.white)", ".fill(.gray)", ".foregroundStyle(.black)"],
            "rgb colour": ["Color(red: 1, green: 0.4, blue: 0.3)", "Color(white: 0.2)"],
            "AppKit rgb colour": ["NSColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)", "NSColor(srgbRed: 0.2, green: 0, blue: 0, alpha: 1)"],
            "AppKit font size": ["NSFont.systemFont(ofSize: 8, weight: .bold)", "NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .bold)"],
            "layer corner radius": ["glow.cornerRadius = 16", "caret.cornerRadius = 0.75"],
            "alpha component": ["Light.glow.withAlphaComponent(0.4)", "NSColor.black.withAlphaComponent(.3)"],
            "fill strength": ["DS.Fill.white(0.3)", "DS.Fill.white(.07)"],
        ]
        #expect(Set(samples.keys) == Set(Self.rules.literals.map(\.name)))
        for literal in Self.rules.literals {
            for sample in samples[literal.name] ?? [] {
                #expect(Self.hits("x.swift", sample).count >= 1, "\(literal.name) misses \(sample)")
            }
        }
        let clean = ".font(DS.font(.sm)) .fill(DS.Fill.subtle) cornerRadius: DS.Radius.md .opacity(shown ? 1 : 0.5)"
            + " .shadow(color: .black.opacity(dragged ? 0.5 : 0)) .fill(on ? DS.Fill.strong : .clear) .opacity(0)"
            + " cornerRadius: CGFloat(Spec.Banner.radius) cornerRadius: CGFloat(Piece.rowRadius)"
            + " Color(hex: P.surface) NSColor(hex: UInt32(accent)) NSColor(srgbRed: CGFloat(pixel[0]) / 255"
            + " NSFont.systemFont(ofSize: step.points) caret.cornerRadius = Self.size.width / 2"
            + " color.withAlphaComponent(Glow.halo) DS.Fill.white(Piece.trackFill)"
        #expect(Self.hits("x.swift", clean).isEmpty, "\(Self.hits("x.swift", clean))")
        #expect(Self.hits("x.swift", "    // .font(.system(size: 11))").isEmpty, "comment lines are skipped")
    }
}

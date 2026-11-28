import Foundation
import Testing
@testable import VisorCore

/// Every check in the key tests goes through here: the macro sees only a
/// Bool, so a failure can never print a generated key. Notes carry indices,
/// never key text.
func expectTrue(_ ok: Bool, _ note: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(ok, note, sourceLocation: sourceLocation)
}

/// Key-shaped test text, built only at run time from parts and a seeded
/// generator, so no key-shaped literal exists in the repo.
enum KeyFixture {
    static let digits = Array("0123456789")
    static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    static let hexDigits = Array("0123456789abcdef")
    static let base32 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// A small LCG: the same seed always gives the same text.
    struct Generator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
        mutating func next(_ count: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(count))
        }
        mutating func pick(_ set: [Character]) -> Character { set[next(set.count)] }
    }

    /// Digit, upper and lower in turn, so every body holds all three classes.
    static func mixed(_ count: Int, seed: UInt64 = 1) -> String {
        var generator = Generator(seed)
        return String((0..<count).map { generator.pick([digits, upper, lower][$0 % 3]) })
    }

    static func from(_ set: [Character], _ count: Int, seed: UInt64 = 1) -> String {
        var generator = Generator(seed)
        return String((0..<count).map { _ in generator.pick(set) })
    }

    static func join(_ parts: String...) -> String { parts.joined() }
    static let dashes = String(repeating: "-", count: 5)

    static func githubClassic(_ letter: String = "p", body: Int = 36, seed: UInt64 = 1) -> String {
        join("g", "h", letter, "_", mixed(body, seed: seed))
    }
    static func githubFine(seed: UInt64 = 2) -> String {
        join("git", "hub", "_pat_", mixed(22, seed: seed), "_", mixed(59, seed: seed + 1))
    }
    static func anthropic(body: Int = 93, seed: UInt64 = 3) -> String {
        join("s", "k-", "an", "t-", "api", "03-", mixed(body, seed: seed))
    }
    /// An Anthropic key whose middle part is not a word plus two digits.
    static func anthropicPlain(body: Int = 95, seed: UInt64 = 4) -> String {
        join("s", "k-", "an", "t-", mixed(body, seed: seed))
    }
    static func openAILegacy(body: Int = 48, seed: UInt64 = 5) -> String {
        join("s", "k-", mixed(body, seed: seed))
    }
    static func openAIProject(body: Int = 120, seed: UInt64 = 6) -> String {
        join("s", "k-", "pr", "oj-", mixed(body / 2, seed: seed), "_", mixed(body - body / 2 - 1, seed: seed + 1))
    }
    static func openAIService(seed: UInt64 = 7) -> String {
        join("s", "k-", "svc", "acct-", mixed(80, seed: seed))
    }
    static func slackBot(seed: UInt64 = 8) -> String {
        join("xo", "xb-", from(digits, 11, seed: seed), "-", from(digits, 13, seed: seed + 1), "-", mixed(24, seed: seed + 2))
    }
    static func slackUser(seed: UInt64 = 9) -> String {
        join("xo", "xp-", from(digits, 11, seed: seed), "-", from(digits, 12, seed: seed + 1), "-",
             from(digits, 12, seed: seed + 2), "-", from(hexDigits, 32, seed: seed + 3))
    }
    /// A rotating bot or user token: one-digit first group.
    static func slackRotating(seed: UInt64 = 10) -> String {
        join("xo", "xp-", "1", "-", mixed(60, seed: seed))
    }
    /// A refresh token of the e type, after a dot-separated lead-in.
    static func slackRefresh(seed: UInt64 = 11) -> String {
        join("xo", "xe", ".", "xo", "xe-", "1", "-", mixed(60, seed: seed))
    }
    /// A client token of the c type: three digit groups and a 64-character hex tail.
    static func slackClient(seed: UInt64 = 12) -> String {
        join("xo", "xc-", from(digits, 12, seed: seed), "-", from(digits, 12, seed: seed + 1), "-",
             from(digits, 12, seed: seed + 2), "-", from(hexDigits, 64, seed: seed + 3))
    }
    static func slackApp(seed: UInt64 = 13) -> String {
        join("xa", "pp-", "1", "-", from(upper + digits, 11, seed: seed), "-", from(digits, 13, seed: seed + 1), "-",
             from(hexDigits, 64, seed: seed + 2))
    }
    static func aws(_ lead: String = "KIA", body: Int = 16, seed: UInt64 = 14) -> String {
        join("A", lead, from(base32, body, seed: seed))
    }
    static let base64Chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    static func privateKeyHeader(_ type: String = "RSA ", block: String = "") -> String {
        join(dashes, "BEGIN ", type, "PRIVATE", " KEY", block, dashes)
    }
    /// A header line, then base64 lines of 64; `shared` leading characters
    /// are the same for every seed, like the fixed start of a key format.
    static func privateKey(_ type: String = "RSA ", block: String = "", newline: String = "\n", armor: String = "",
                           shared: Int = 0, seed: UInt64 = 15) -> String {
        let body = from(base64Chars, shared, seed: 1) + from(base64Chars, 256 - shared, seed: seed)
        var lines: [String] = []
        var rest = Substring(body)
        while !rest.isEmpty { lines.append(String(rest.prefix(64))); rest = rest.dropFirst(64) }
        return privateKeyHeader(type, block: block) + newline + armor + lines.joined(separator: newline)
    }
}

@Suite("Key shapes")
struct KeyShapesTests {
    typealias F = KeyFixture

    static let samples: [(String, KeyKind)] = [
        (F.githubClassic("p"), .github), (F.githubClassic("o"), .github), (F.githubClassic("u"), .github),
        (F.githubClassic("s"), .github), (F.githubClassic("r"), .github), (F.githubClassic(body: 76), .github),
        (F.githubFine(), .github),
        (F.anthropic(), .anthropic), (F.anthropicPlain(), .anthropic),
        (F.openAILegacy(), .openai), (F.openAIProject(), .openai), (F.openAIService(), .openai),
        (F.slackBot(), .slack), (F.slackUser(), .slack), (F.slackRotating(), .slack), (F.slackRefresh(), .slack),
        (F.slackClient(), .slack), (F.slackApp(), .slack),
        (F.aws("KIA"), .aws), (F.aws("SIA"), .aws),
        (F.privateKey(), .privateKey), (F.privateKey(""), .privateKey), (F.privateKey("OPENSSH "), .privateKey),
        (F.privateKey("PGP ", block: " BLOCK", newline: "\n\n"), .privateKey),
        (F.privateKey("EC ", newline: "\r\n"), .privateKey),
        (F.privateKey(newline: "\\n"), .privateKey),
        // Indented: a YAML block scalar, a tab-indented heredoc, an escaped indented string.
        ("data:\n  id_rsa: |\n    " + F.privateKey(newline: "\n    "), .privateKey),
        ("\t\t" + F.privateKey("OPENSSH ", newline: "\n\t\t"), .privateKey),
        ("key = \"" + F.privateKey(newline: "\\n  ") + "\"", .privateKey),
        // Armor headers before the body: a legacy encrypted PEM, a GnuPG export.
        (F.privateKey(armor: "Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC," + F.from(F.hexDigits, 32, seed: 16).uppercased() + "\n\n"), .privateKey),
        (F.privateKey("PGP ", block: " BLOCK", armor: "Version: GnuPG v2\nComment: exported\n\n"), .privateKey),
        ("    " + F.privateKey(newline: "\n    ", armor: "Proc-Type: 4,ENCRYPTED\n    DEK-Info: DES-EDE3-CBC,0A1B\n\n    "), .privateKey),
    ]

    @Test(arguments: samples.indices)
    func findsEachKind(_ index: Int) {
        let (key, kind) = Self.samples[index]
        expectTrue(KeyShapes.kinds(in: key) == [kind], "sample \(index)")
        expectTrue(KeyShapes.kinds(in: "export TOKEN=\(key) && run") == [kind], "sample \(index) in a command")
        expectTrue(KeyShapes.kinds(in: "please use \"\(key)\".\nthanks") == [kind], "sample \(index) in a prompt")
    }

    @Test func namesEachKindOnceInFirstSeenOrder() {
        let text = [F.slackBot(), F.githubClassic(), F.slackBot(seed: 30), F.aws()].joined(separator: " ")
        expectTrue(KeyShapes.kinds(in: text) == [.slack, .github, .aws])
    }

    @Test func anthropicIsNotOpenAI() {
        expectTrue(KeyShapes.kinds(in: F.anthropic()) == [.anthropic])
        expectTrue(KeyShapes.kinds(in: F.anthropicPlain()) == [.anthropic])
        // Under the Anthropic floor, and never read as OpenAI.
        expectTrue(KeyShapes.kinds(in: F.anthropicPlain(body: 79)) == [])
    }

    @Test func belowFloorIsNotAKey() {
        expectTrue(KeyShapes.kinds(in: F.githubClassic(body: 35)) == [])
        expectTrue(KeyShapes.kinds(in: F.join("git", "hub", "_pat_", F.mixed(22), "_", F.mixed(58))) == [])
        expectTrue(KeyShapes.kinds(in: F.anthropicPlain(body: 79)) == [])
        expectTrue(KeyShapes.kinds(in: F.openAILegacy(body: 39)) == [])
        expectTrue(KeyShapes.kinds(in: F.join("xo", "xb-", "123", "-", F.mixed(9))) == [])
        expectTrue(KeyShapes.kinds(in: F.join("xa", "pp-", "1", "-", F.mixed(19))) == [])
        expectTrue(KeyShapes.kinds(in: F.aws(body: 15)) == [])
    }

    static let falseAlarms: [String] = {
        var generator = KeyFixture.Generator(99)
        let bytes = Data((0..<300).map { _ in UInt8(generator.next(256)) })
        return [
            F.from(F.hexDigits, 40, seed: 20),                      // git SHA
            "commit " + F.from(F.hexDigits, 40, seed: 21),
            UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)).uuidString,
            UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)).uuidString.lowercased(),
            F.from(F.hexDigits, 32, seed: 22),                      // md5
            F.from(F.hexDigits, 64, seed: 23),                      // sha256
            "sha512:" + F.from(F.hexDigits, 128, seed: 24),
            Array(repeating: "really-long-branch-name", count: 5).joined(separator: "-"),
            F.join("s", "k-", "learn-tutorial-for-beginners-and-advanced-readers-part-two"),
            F.join("s", "k-", "an", "t-", "docs-readme-section-about-the-api-and-other-things-that-go-on-for-long-enough-to-pass"),
            F.join("g", "hp_", F.from(F.lower, 36, seed: 25)),     // lowercase only
            F.join("x", "ox", "b-"), F.join("g", "hp_"), F.join("s", "k-"), F.join("A", "KIA"),
            bytes.base64EncodedString(),
            F.join(F.dashes, "BEGIN PUBLIC", " KEY", F.dashes),
            F.join(F.dashes, "BEGIN CERTIFICATE", F.dashes),
            F.privateKeyHeader(),                                   // a header alone is no key
            F.privateKeyHeader() + "\n" + F.from(F.base64Chars, 39, seed: 27),
            "if line == \"" + F.privateKeyHeader("") + "\" {\n    inKey = true\n}",
            "/Users/me/Projects/" + F.from(F.lower, 80, seed: 26),
        ]
    }()

    @Test(arguments: falseAlarms.indices)
    func noFalseAlarms(_ index: Int) {
        expectTrue(KeyShapes.kinds(in: Self.falseAlarms[index]) == [], "sample \(index)")
    }

    /// Keys right after an escaped newline or tab, or a percent-encoded separator.
    @Test func findsKeysAfterEscapes() {
        let key = F.githubClassic()
        for lead in ["a\\n", "a\\t", "a\\r", "token%3D", "x%20"] {
            expectTrue(KeyShapes.kinds(in: lead + key) == [.github], "\(lead)")
        }
        expectTrue(KeyShapes.kinds(in: "{\"pem\":\"\\n" + F.privateKey(newline: "\\n") + "\"}") == [.privateKey])
        // A plain letter or digit before the prefix still blocks it.
        expectTrue(KeyShapes.kinds(in: "x" + key) == [])
    }

    /// The identity of a match is its kind plus a fixed start of its body, so
    /// trailing text a greedy body absorbs doesn't make it a new key.
    @Test func identityIgnoresTrailingText() {
        var seen: [String] = []
        for text in [F.openAILegacy(), F.openAILegacy() + "-and_more-text", F.anthropic() + "-x"] {
            KeyShapes.scan(text) { _, identity in seen.append(identity) }
        }
        expectTrue(seen.count == 3)
        expectTrue(seen[0] == seen[1])
        // Two private keys of one format differ past their shared start.
        var keys: [String] = []
        for seed in [40, 41] as [UInt64] {
            KeyShapes.scan(F.privateKey("OPENSSH ", shared: 70, seed: seed)) { _, identity in keys.append(identity) }
        }
        expectTrue(keys.count == 2)
        expectTrue(keys[0] != keys[1])
        // The same key with real or escaped newlines is the same key.
        var forms: [String] = []
        for newline in ["\n", "\\n"] { KeyShapes.scan(F.privateKey(newline: newline)) { _, identity in forms.append(identity) } }
        expectTrue(forms.count == 2)
        expectTrue(forms[0] == forms[1])
    }

    @Test func prefilterSkipsTextWithoutPrefixes() {
        let dense = F.from(F.base64Chars, 16_000, seed: 50)
        expectTrue(!KeyShapes.mayHoldKey(dense))
        for (key, _) in Self.samples { expectTrue(KeyShapes.mayHoldKey("x " + key)) }
    }

    /// A candidate that fails its class check doesn't swallow a key glued onto it.
    @Test func gluedJunkDoesNotHideKey() {
        let junk = F.join("s", "k-", F.from(F.lower, 30, seed: 52))
        expectTrue(KeyShapes.kinds(in: junk + "-" + F.slackUser()) == [.slack])
        expectTrue(KeyShapes.kinds(in: junk + "_" + F.join("s", "k-", "an", "t-") + F.from(F.lower, 90, seed: 53) + "-" + F.slackUser()) == [.slack])
    }

    @Test func manyFailedCandidatesAreCheap() {
        let text = (0..<400).map { F.join("s", "k-", F.from(F.lower, 37, seed: UInt64($0))) }.joined(separator: "-")
        let start = Date()
        for _ in 0..<10 { _ = KeyShapes.kinds(in: text) }
        let each = Date().timeIntervalSince(start) / 10
        expectTrue(each < 0.05, "took \(each) s")
    }

    @Test func denseTextIsCheap() {
        // Minified or base64 text in several fields: about 16 KB of dense
        // alphanumerics each, with a prefix in it so the regex runs.
        let dense = F.from(F.base64Chars, 16_000, seed: 51) + " sk-"
        let start = Date()
        for _ in 0..<20 { _ = KeyShapes.kinds(in: dense) }
        let each = Date().timeIntervalSince(start) / 20
        expectTrue(each < 0.02, "took \(each) s")
    }

    @Test func scansHeadAndTailOnly() {
        let filler = String(repeating: "lorem ipsum dolor ", count: 60_000)
        let key = F.githubClassic()
        expectTrue(KeyShapes.kinds(in: key + " " + filler) == [.github])
        expectTrue(KeyShapes.kinds(in: filler + " " + key) == [.github])
        let half = filler.count / 2
        let middle = String(filler.prefix(half)) + " " + key + " " + String(filler.suffix(half))
        expectTrue(KeyShapes.kinds(in: middle) == [])
        let windows = KeyShapes.windows(filler)
        expectTrue(windows.count == 2)
        expectTrue(windows.allSatisfy { $0.utf8.count <= KeyShapes.window })
        expectTrue(KeyShapes.windows("short") == ["short"])
    }

    @Test func largeInputIsCheap() {
        let text = String(repeating: "abc def 0123 ", count: 80_000) + F.githubClassic()
        let start = Date()
        for _ in 0..<10 { _ = KeyShapes.kinds(in: text) }
        let each = Date().timeIntervalSince(start) / 10
        expectTrue(each < 0.05, "took \(each) s")
    }

    /// A filter-free check: any kind prefix with a long run after it, or a header line.
    static let prefixCheck = try! NSRegularExpression(pattern:
        "(^|[^A-Za-z0-9_])(gh[pousr]_|github_pat_|sk-|xox[a-z]-|xapp-|AKIA|ASIA)[A-Za-z0-9_-]{16,}|-{5}BEGIN .*PRIVATE KEY")

    static func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func holdsNoKeyShapedLiteral(_ path: String) throws -> Bool {
        let text = try repoFile(path)
        var found = 0
        KeyShapes.scanAll(text) { _, _ in found += 1 }
        let hits = prefixCheck.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        return found == 0 && hits == 0
    }

    /// The literal check is not vacuous: it catches every generated fixture.
    @Test(arguments: samples.indices)
    func prefixCheckCatchesFixtures(_ index: Int) {
        let text = "x " + Self.samples[index].0
        expectTrue(Self.prefixCheck.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) > 0, "sample \(index)")
    }

    @Test(arguments: ["Sources/VisorCore/KeyShapes.swift", "Tests/VisorCoreTests/KeyShapesTests.swift"])
    func newFilesHoldNoKeyShapedLiteral(_ path: String) throws {
        let clean = try Self.holdsNoKeyShapedLiteral(path)
        expectTrue(clean)
    }

    /// A forced failure: its issue text names the note, never the key.
    @Test func failureTextHoldsNoKey() {
        let key = F.githubClassic()
        withKnownIssue {
            expectTrue(KeyShapes.kinds(in: key) == [.aws], "forced")
        } matching: { issue in
            let text = String(describing: issue) + " " + String(reflecting: issue)
            let hits = Self.prefixCheck.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            return hits == 0 && text.contains("forced")
        }
    }

    /// The key tests use only `expectTrue`, so no check can print key text.
    @Test(arguments: ["Tests/VisorCoreTests/KeyShapesTests.swift", "Tests/VisorCoreTests/KeyWatchTests.swift"])
    func keyTestsCheckOnlyThroughTheHelper(_ path: String) throws {
        let text = try Self.repoFile(path)
        let direct = text.components(separatedBy: "#exp" + "ect(").count - 1
        expectTrue(direct == (path.hasSuffix("KeyShapesTests.swift") ? 1 : 0), "\(direct) direct checks")
    }

    static let keepingAPIs = ["print(", "NSLog", "os_log", "Logger", "FileManager", "write(to", "UserDefaults", "Timer", "Dispatch"]

    @Test func detectorKeepsNothing() throws {
        let source = try Self.repoFile("Sources/VisorCore/KeyShapes.swift")
        for api in Self.keepingAPIs { expectTrue(!source.contains(api), "\(api)") }
    }
}

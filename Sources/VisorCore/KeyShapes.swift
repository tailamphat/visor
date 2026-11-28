import Foundation

/// The kinds of key `KeyShapes` can name. Only the kind is ever shown.
public enum KeyKind: String, Sendable, CaseIterable {
    case github, anthropic, openai, slack, aws, privateKey

    public var label: String {
        switch self {
        case .github: return "GitHub token"
        case .anthropic: return "Anthropic key"
        case .openai: return "OpenAI key"
        case .slack: return "Slack token"
        case .aws: return "AWS access key"
        case .privateKey: return "private key"
        }
    }
}

/// Finds text shaped like a key: each rule starts at a fixed prefix and has a
/// length floor and bounded quantifiers. There is no generic "random string"
/// rule, so git hashes, UUIDs, hex digests and slugs never match. Only the
/// first and last 8 KB of a text are read, and the regex runs only when a
/// prefix is there at all. Matches go to a closure and are never stored.
public enum KeyShapes {
    /// Bytes read from each end of a text.
    static let window = 8192
    /// Characters of a body that tell two keys apart: about the rule's length
    /// floor, so trailing text a greedy body takes is left out, and past any
    /// digit groups every token of one Slack workspace shares.
    static func identityLength(_ kind: KeyKind) -> Int {
        switch kind {
        case .github: return 36
        case .anthropic: return 80
        case .openai: return 40
        case .slack: return 50
        case .aws: return 16
        case .privateKey: return privateKeyIdentityLength
        }
    }
    /// Base64 characters of a private key that tell two keys apart; past the
    /// fixed start every key of one format shares.
    static let privateKeyIdentityLength = 400

    /// Every rule's literal start: a text with none of them is not scanned.
    static let prefixes = ["gh" + "p_", "gh" + "o_", "gh" + "u_", "gh" + "s_", "gh" + "r_", "github_pat_",
                           "sk-", "xox", "xapp-", "AKIA", "ASIA", "PRIVATE KEY"]

    /// Which characters a key's body must hold besides its shape.
    enum Classes: Sendable { case none, digitOrUpper, all3, digitAndLetter }

    struct Rule: Sendable {
        let kind: KeyKind
        /// One capture group around the body; other groups are non-capturing.
        let pattern: String
        let classes: Classes
    }

    /// Anthropic comes before OpenAI; the OpenAI rule also refuses the Anthropic prefix.
    static let rules: [Rule] = [
        Rule(kind: .github, pattern: "gh[pousr]_([A-Za-z0-9]{36,251})", classes: .digitOrUpper),
        Rule(kind: .github, pattern: "github_pat_([A-Za-z0-9]{22}_[A-Za-z0-9]{59})(?![A-Za-z0-9])", classes: .digitOrUpper),
        Rule(kind: .anthropic, pattern: "sk-ant-([A-Za-z0-9_-]{80,200})", classes: .all3),
        Rule(kind: .openai, pattern: "sk-(?!ant-)(?:proj-|svcacct-|admin-)?([A-Za-z0-9_-]{40,250})", classes: .all3),
        Rule(kind: .slack, pattern: "xox[abceoprs]-([0-9]{1,20}-[A-Za-z0-9-]{10,200})", classes: .digitAndLetter),
        Rule(kind: .slack, pattern: "xapp-([0-9]-[A-Za-z0-9-]{20,200})", classes: .digitAndLetter),
        Rule(kind: .aws, pattern: "(?:AKIA|ASIA)([A-Z2-7]{16})(?![A-Za-z0-9])", classes: .none),
        // The header, then at least 40 base64 characters: code that only
        // mentions the header is no key.
        Rule(kind: .privateKey, pattern: privateKeyPattern, classes: .none),
    ]

    /// A newline, real or escaped, and the indent after it (YAML, heredocs, strings).
    static let newline: String = "(?:\\r?\\n|\\\\[rn])[ \\t]{0,40}"
    /// Up to six armor lines ("Proc-Type: ...", "Version: ...") and a blank line.
    static let armor: String = "(?:[A-Za-z][A-Za-z-]{1,30}: [^\\r\\n\\\\]{1,200}(?:" + newline + "){1,2}){0,6}"
    static let privateKeyPattern: String = "-{5}BEGIN (?:[A-Z]{2,10} ){0,2}PRIVATE KEY(?: BLOCK)?-{5}(?:" + newline + "){1,4}"
        + armor + "((?:[A-Za-z0-9+/=]|" + newline + "){40,600})"

    /// All rules in one pass: rule i's body is capture group i + 1. A rule
    /// starts after a non-word character, or right after an escaped newline,
    /// tab or return, or a percent-encoded byte.
    static let pattern = try! NSRegularExpression(pattern: "(?:(?<![A-Za-z0-9_])|(?<=\\\\[nrt])|(?<=%[0-9A-Fa-f]{2}))(?:" + rules.map(\.pattern).joined(separator: "|") + ")")

    /// The kinds found, each once, in first-seen order.
    public static func kinds(in text: String) -> [KeyKind] {
        var found: [KeyKind] = []
        scan(text) { kind, _ in if !found.contains(kind) { found.append(kind) } }
        return found
    }

    /// Hands each match in the text's windows to `body` as its kind and
    /// identity (a fixed start of its body); `body` must not keep it.
    static func scan(_ text: String, _ body: (KeyKind, String) -> Void) {
        for part in windows(text) where mayHoldKey(part) { scanAll(part, body) }
    }

    /// Whether any rule's literal start is in the text.
    static func mayHoldKey(_ text: String) -> Bool {
        prefixes.contains { text.contains($0) }
    }

    /// The first and last `window` bytes, or the whole text when it is short.
    /// The two ends are scanned apart, so no match spans the cut.
    static func windows(_ text: String) -> [String] {
        let bytes = text.utf8
        guard bytes.count > 2 * window else { return [text] }
        return [String(decoding: bytes.prefix(window), as: UTF8.self),
                String(decoding: bytes.suffix(window), as: UTF8.self)]
    }

    /// Every match in the whole text, without the window.
    /// A candidate that fails its class check is dropped and the search goes
    /// on from its next character, so it never swallows a key glued onto it.
    /// Matches start only at a prefix, so a retry costs at most one candidate.
    static func scanAll(_ text: String, _ body: (KeyKind, String) -> Void) {
        matches(text) { kind, _, inner in body(kind, identity(kind, inner)) }
    }

    /// The one match loop: each key's kind, its whole match (UTF-16 range) and
    /// its body. `scanAll` and `redacted` both read it.
    static func matches(_ text: String, _ body: (KeyKind, NSRange, Substring) -> Void) {
        let length = (text as NSString).length
        var start = 0
        while start < length,
              let result = pattern.firstMatch(in: text, options: [.withTransparentBounds, .withoutAnchoringBounds],
                                              range: NSRange(location: start, length: length - start)) {
            start = result.range.location + 1
            guard let index = rules.indices.first(where: { result.range(at: $0 + 1).location != NSNotFound }),
                  let inner = Range(result.range(at: index + 1), in: text) else { continue }
            let rule = rules[index]
            guard holds(rule.classes, text[inner]) else { continue }
            body(rule.kind, result.range, text[inner])
            start = max(start, NSMaxRange(result.range))
        }
    }

    /// What tells one key from another: the body's start, or for a private
    /// key its base64 characters with newlines (real or escaped) taken out.
    static func identity(_ kind: KeyKind, _ body: Substring) -> String {
        guard kind == .privateKey else { return String(body.prefix(identityLength(kind))) }
        let plain = body.replacingOccurrences(of: "\\n", with: "").replacingOccurrences(of: "\\r", with: "")
        return String(plain.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "+" || $0 == "/") }
            .prefix(privateKeyIdentityLength).map(Character.init))
    }

    static func holds(_ classes: Classes, _ body: Substring) -> Bool {
        guard classes != .none else { return true }
        var digit = false, upperCase = false, lowerCase = false
        for byte in body.utf8 {
            switch byte {
            case 0x30...0x39: digit = true
            case 0x41...0x5A: upperCase = true
            case 0x61...0x7A: lowerCase = true
            default: break
            }
        }
        switch classes {
        case .none: return true
        case .digitOrUpper: return digit || upperCase
        case .all3: return digit && upperCase && lowerCase
        case .digitAndLetter: return digit && (upperCase || lowerCase)
        }
    }
}

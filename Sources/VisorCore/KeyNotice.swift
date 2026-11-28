import Foundation

/// The words Visor shows for a key alert, built only from kind labels,
/// project, agent and source, never from the text that raised it; where Show
/// transcript may point; and how the key peek ranks against other peeks.
public enum KeyNotice {
    /// The closed notch's right side, by where the key was.
    public static func peekWords(_ source: KeyAlert.Source) -> String {
        switch source {
        case .prompt: return "key in a prompt"
        case .command: return "key in a command"
        case .file: return "key in a file"
        }
    }

    /// "A GitHub token", "A Slack token and an AWS access key", "A, b and c".
    public static func kindsPhrase(_ kinds: [KeyKind]) -> String {
        let named = kinds.map { article($0.label) + " " + $0.label }
        guard let first = named.first else { return "A key" }
        let phrase: String
        switch named.count {
        case 1: phrase = first
        case 2: phrase = named[0] + " and " + named[1]
        default: phrase = named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
        }
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    /// The card's second and third rows.
    public static func body(_ kinds: [KeyKind]) -> (sentence: String, advice: String) {
        let several = kinds.count > 1
        return (kindsPhrase(kinds) + (several ? " are" : " is") + " now in this session's transcript and "
                    + (several ? "were" : "was") + " sent to the model.",
                "Rotating " + (several ? "them" : "it") + " is the safe move.")
    }

    /// Hover text for the peek and the card: who, what kind, where.
    public static func hover(_ alert: KeyAlert) -> String {
        "\(alert.agent): \(kindsPhrase(alert.kinds)) in a " + ["prompt", "command", "file"][index(alert.source)]
    }

    /// The project the card names: the last part of the session's folder.
    public static func project(_ alert: KeyAlert) -> String? {
        guard let cwd = alert.cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Whether Show transcript may reveal `path`: a `.jsonl` file right inside
    /// one project folder right inside one of `roots` (Claude Code's transcript
    /// folders), compared after standardizing and resolving symlinks, so a hook
    /// payload can't point Finder anywhere else. Looks only at the path.
    public static func revealable(_ path: String?, roots: [String]) -> Bool {
        guard let path, !path.isEmpty, path.hasPrefix("/") else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension == "jsonl" else { return false }
        let root = resolved.deletingLastPathComponent().deletingLastPathComponent().path
        return roots.contains { !$0.isEmpty && URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == root }
    }

    /// Whether a new peek may replace the one showing: nothing but another key
    /// peek replaces a key peek; a key peek replaces anything.
    public static func replaces(showingKey: Bool, incomingIsKey: Bool) -> Bool {
        incomingIsKey || !showingKey
    }

    /// At unlock: the newest alert held while locked that still stands
    /// (`standing` is newest first).
    public static func heldAtUnlock(held: Set<Int>, standing: [KeyAlert]) -> KeyAlert? {
        standing.first { held.contains($0.id) }
    }

    /// A key peek a card covered (the "limit is back" card opens the notch):
    /// shown again when the card goes, if its alert still stands.
    public static func comesBack(_ id: Int?, standing: [KeyAlert]) -> KeyAlert? {
        guard let id else { return nil }
        return standing.first { $0.id == id }
    }

    /// Whether a finished turn's summary waits behind its peek: only when that
    /// peek took the notch (a key peek may have kept it), the notch is closed
    /// and the turn changed something.
    public static func takesSummary(peekShown: Bool, expanded: Bool, hasStats: Bool) -> Bool {
        peekShown && !expanded && hasStats
    }

    private static func article(_ label: String) -> String {
        guard let first = label.first else { return "a" }
        return "AEIOUaeiou".contains(first) ? "an" : "a"
    }

    private static func index(_ source: KeyAlert.Source) -> Int {
        switch source {
        case .prompt: return 0
        case .command: return 1
        case .file: return 2
        }
    }
}

extension KeyShapes {
    /// What may follow a match and still be the same key: the rest of a token
    /// past its rule's length ceiling.
    static let tokenTail = try! NSRegularExpression(pattern: "[A-Za-z0-9_-]+")
    /// The rest of a private key past the rule's 600 characters: base64 and
    /// newlines (real or escaped, indented), then its END line.
    static let privateKeyTail = try! NSRegularExpression(pattern:
        "(?:[A-Za-z0-9+/=]|" + newline + ")*(?:-{5}END (?:[A-Z]{2,10} ){0,2}PRIVATE KEY(?: BLOCK)?-{5})?")

    /// The first `cap` bytes of `text` with each key, its whole length, replaced
    /// by its kind ("[GitHub token]"), for text Visor shows: run before any cut,
    /// so a key across a cut never shows in part. Only the shown start is
    /// scanned, and text without any rule's start is returned as it is.
    public static func redacted(_ text: String, cap: Int = 4096) -> String {
        let head = text.utf8.count <= cap ? text : String(decoding: text.utf8.prefix(cap), as: UTF8.self)
        guard mayHoldKey(head) else { return head }
        let length = (head as NSString).length
        var found: [(NSRange, KeyKind)] = []
        matches(head) { kind, range, _ in
            // Already inside the previous key's tail.
            if let last = found.last, range.location < NSMaxRange(last.0) { return }
            let tail = kind == .privateKey ? privateKeyTail : tokenTail
            let end = NSMaxRange(range)
            let extra = tail.firstMatch(in: head, options: [.anchored, .withTransparentBounds],
                                        range: NSRange(location: end, length: length - end))?.range.length ?? 0
            found.append((NSRange(location: range.location, length: range.length + extra), kind))
        }
        guard !found.isEmpty else { return head }
        let out = NSMutableString(string: head)
        for (range, kind) in found.reversed() { out.replaceCharacters(in: range, with: "[" + kind.label + "]") }
        return out as String
    }
}

extension TurnStats {
    /// `shortFiles` as the turn summary shows them: a key in a file or folder
    /// name as its kind. `files` itself stays whole for View diff.
    public func shownFiles(in cwd: String, limit: Int) -> ([String], Int) {
        let (files, more) = shortFiles(in: cwd, limit: limit)
        return (files.map { KeyShapes.redacted($0) }, more)
    }
}

extension ApprovalRequest {
    /// The approval card's preview with any key shown as its kind. Display
    /// only: `preview`, which the reply and rules read, is unchanged.
    /// Slashes JSON escaped (the preview of a tool with no known field) are
    /// unescaped first, so a private key's base64 still reads as one.
    public var shownPreview: String { KeyShapes.redacted(preview.replacingOccurrences(of: "\\/", with: "/")) }

    /// "Always allow: ..." as shown: when the command or the suggested rule
    /// holds a key and the label carries a key's start, the kind instead.
    public var shownAlwaysAllowLabel: String? {
        guard let label = alwaysAllowLabel else { return nil }
        guard KeyShapes.mayHoldKey(label) else { return label }
        var source = preview
        for case let suggestion as [String: Any] in suggestions {
            for case let rule as [String: Any] in suggestion["rules"] as? [Any] ?? [] {
                if let content = rule["ruleContent"] as? String { source += "\n" + content }
            }
        }
        guard let kind = KeyShapes.kinds(in: source).first else { return label }
        return "[" + kind.label + "]"
    }
}

extension KeyShapes {
    /// `redacted`, worked out once per text for views that redraw (a clash's
    /// path): the cache holds only shown text, keyed by the original's hash,
    /// never the original; at most 64 entries.
    public static func redactedOnce(_ text: String) -> String {
        RedactionMemo.shared.shown(text)
    }
}

final class RedactionMemo: @unchecked Sendable {
    static let shared = RedactionMemo()
    static let limit = 64
    private let lock = NSLock()
    private var cache: [Int: String] = [:]

    func shown(_ text: String) -> String {
        let key = text.hashValue
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let made = KeyShapes.redacted(text)
        lock.lock()
        if cache.count >= Self.limit { cache.removeAll() }
        cache[key] = made
        lock.unlock()
        return made
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return cache.count }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return Array(cache.values) }
}

#if DEBUG
extension KeyAlert {
    /// The debug socket's `_key`: an alert made from a kind alone, never a key.
    public static func sample(id: Int, kinds: [KeyKind], source: Source, session: String, agent: String,
                              cwd: String?, transcript: String?, at: Date) -> KeyAlert {
        KeyAlert(id: id, kinds: kinds, session: session, agent: agent, source: source, at: at, cwd: cwd, transcript: transcript)
    }
}
#endif

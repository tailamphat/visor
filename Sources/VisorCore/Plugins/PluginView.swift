import Foundation

/// A plugin's custom view: a tree of Visor's own pieces, built in Lua with
/// `visor.ui.*` and checked here. Plugins never choose fonts, sizes or
/// colours beyond the five states and their accent; Visor draws each piece.
public indirect enum PluginNode: Equatable, Sendable {
    case stack([PluginNode])
    case columns([PluginNode])
    case divider
    case text(String, style: TextStyle, state: PluginState?)
    case stats([PluginNode])
    case stat(value: String, label: String, state: PluginState?, large: Bool, pending: Bool)
    /// `value` is 0...1.
    case meter(title: String, value: Double, text: String, caption: String, state: PluginState?, pending: Bool)
    case bars(values: [Double], states: [PluginState?], labels: [String], pending: Bool)
    case chips([PluginChip])
    case list([PluginRow])
    case table(columns: [String], rows: [[String]])
    /// Counts down to `until` or up from `since`; Visor ticks it, not the plugin.
    case clock(until: Date?, since: Date?, large: Bool)
    /// 0...1, or nil while it can't be measured.
    case progress(value: Double?)
    case buttons([PluginButton])
    case picker(options: [String], selected: String?, action: String)
    case toggle(label: String, on: Bool, action: String)
    /// A piece this version of Visor doesn't know.
    case unsupported(String)

    public enum TextStyle: String, Sendable { case title, body, caption, mono }

    public static let maxNodes = 300
    public static let maxDepth = 8

    /// Reads one piece from what Lua sent; nil for things that aren't pieces.
    public static func decode(_ any: Any) -> PluginNode? {
        var budget = maxNodes
        return decode(any, budget: &budget, depth: 0)
    }

    public static func count(_ node: PluginNode) -> Int {
        switch node {
        case .stack(let children), .columns(let children), .stats(let children): return 1 + children.reduce(0) { $0 + count($1) }
        default: return 1
        }
    }

    private static func decode(_ any: Any, budget: inout Int, depth: Int) -> PluginNode? {
        guard budget > 0, depth < maxDepth, let fields = any as? [String: Any], let kind = fields["kind"] as? String else { return nil }
        budget -= 1
        let pending = fields["pending"] as? Bool ?? false
        func children() -> [PluginNode] {
            var out: [PluginNode] = []
            for item in positional(fields) {
                guard budget > 0 else { break }
                if let node = decode(item, budget: &budget, depth: depth + 1) { out.append(node) }
            }
            return out
        }
        func string(_ key: String) -> String? { text(fields[key]) }
        switch kind {
        case "stack": return .stack(children())
        case "columns": return .columns(Array(children().prefix(3)))
        case "stats": return .stats(children().filter { if case .stat = $0 { return true }; return false })
        case "divider": return .divider
        case "text":
            return .text(text(positional(fields).first) ?? string("text") ?? "", style: TextStyle(rawValue: string("style") ?? "") ?? .body,
                         state: optionalState(fields["state"]))
        case "stat":
            return .stat(value: string("value") ?? "", label: string("label") ?? "", state: optionalState(fields["state"]),
                         large: string("size") == "large", pending: pending)
        case "meter":
            let value = min(1, max(0, number(fields["value"]) ?? 0))
            return .meter(title: string("title") ?? "", value: value, text: string("text") ?? "\(Int((value * 100).rounded()))%",
                          caption: string("caption") ?? "", state: optionalState(fields["state"]), pending: pending)
        case "bars":
            let items = (fields["values"] as? [Any] ?? []).prefix(60)
            // A bar is a number, { number, state = ... }, or { number } (which Lua hands over as a list).
            let values = items.map { item -> Double in
                if let fields = item as? [String: Any] { return max(0, number(positional(fields).first) ?? number(fields["value"]) ?? 0) }
                if let list = item as? [Any] { return max(0, number(list.first) ?? 0) }
                return max(0, number(item) ?? 0)
            }
            let states = items.map { item -> PluginState? in (item as? [String: Any]).flatMap { optionalState($0["state"]) } }
            return .bars(values: values, states: states, labels: (fields["labels"] as? [Any] ?? []).prefix(2).compactMap(text), pending: pending)
        case "chips":
            return .chips(positional(fields).prefix(12).compactMap { item in
                if let label = text(item) { return PluginChip(text: label, state: nil) }
                if let list = item as? [Any], let label = text(list.first) { return PluginChip(text: label, state: nil) }
                guard let chip = item as? [String: Any], let label = text(positional(chip).first) ?? text(chip["text"]) else { return nil }
                return PluginChip(text: label, state: optionalState(chip["state"]))
            })
        case "list":
            return .list(positional(fields).prefix(50).compactMap { ($0 as? [String: Any]).flatMap(PluginRow.decode) })
        case "table":
            let columns = (fields["columns"] as? [Any] ?? []).prefix(6).compactMap(text)
            let rows = (fields["rows"] as? [Any] ?? []).prefix(30).compactMap { row -> [String]? in
                (row as? [Any]).map { $0.prefix(columns.count).map { text($0) ?? "" } }
            }
            return .table(columns: columns, rows: rows)
        case "clock":
            return .clock(until: date(fields["until"]), since: date(fields["since"]), large: string("style") == "large")
        case "progress":
            return .progress(value: number(fields["value"]).map { min(1, max(0, $0)) })
        case "buttons":
            return .buttons(positional(fields).prefix(4).compactMap { ($0 as? [String: Any]).flatMap(PluginButton.decode) })
        case "button":
            return PluginButton.decode(fields).map { .buttons([$0]) }
        case "picker":
            guard let action = string("action") else { return nil }
            return .picker(options: (fields["options"] as? [Any] ?? []).prefix(6).compactMap(text), selected: string("selected"), action: action)
        case "toggle":
            guard let action = string("action") else { return nil }
            return .toggle(label: text(positional(fields).first) ?? string("label") ?? "", on: fields["on"] as? Bool ?? false, action: action)
        default:
            return .unsupported(kind)
        }
    }

    /// The array part of a Lua table: keys "1", "2", ... in order.
    static func positional(_ fields: [String: Any]) -> [Any] {
        var out: [Any] = []
        var i = 1
        while let item = fields[String(i)] {
            out.append(item)
            i += 1
        }
        return out
    }

    private static func text(_ any: Any?) -> String? {
        if let string = any as? String { return String(string.prefix(300)) }
        if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    private static func number(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func date(_ any: Any?) -> Date? {
        if let seconds = number(any) { return Date(timeIntervalSince1970: seconds) }
        if let text = any as? String { return PluginRow.parseDate(text) }
        return nil
    }

    static func optionalState(_ any: Any?) -> PluginState? { (any as? String).map { PluginState(loose: $0) } }
}

public struct PluginChip: Equatable, Sendable {
    public var text: String
    public var state: PluginState?

    public init(text: String, state: PluginState?) {
        self.text = text
        self.state = state
    }
}

/// A button: opens a link, or calls the plugin's `visor.on` handler. Read-only:
/// plugins can't change anything outside Visor, so neither can a button.
public struct PluginButton: Equatable, Sendable {
    public var title: String
    public var action: String?
    public var url: URL?
    public var primary: Bool

    public init(title: String, action: String?, url: URL?, primary: Bool) {
        self.title = title
        self.action = action
        self.url = url
        self.primary = primary
    }

    static func decode(_ fields: [String: Any]) -> PluginButton? {
        guard let title = (PluginNode.positional(fields).first as? String) ?? (fields["title"] as? String) else { return nil }
        let url = (fields["url"] as? String).flatMap(PluginRow.safeURL)
        let action = fields["action"] as? String
        guard url != nil || action != nil else { return nil }
        return PluginButton(title: String(title.prefix(40)), action: action, url: url, primary: fields["style"] as? String == "primary")
    }
}

extension PluginRow {
    /// A row from Lua: `title` required; `detail`, `status`, `url`, `time`.
    public static func decode(_ row: [String: Any]) -> PluginRow? {
        guard let title = row["title"] as? String else { return nil }
        var time: Date?
        if let seconds = row["time"] as? NSNumber { time = Date(timeIntervalSince1970: seconds.doubleValue) }
        if let text = row["time"] as? String { time = parseDate(text) }
        return PluginRow(title: String(title.prefix(300)), detail: String((row["detail"] as? String ?? "").prefix(80)),
                         status: PluginState(loose: row["status"] as? String), url: (row["url"] as? String).flatMap(safeURL), time: time)
    }

    /// Only web links open from a plugin: no file:, app or custom schemes.
    static func safeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    static func parseDate(_ text: String) -> Date? { ISODate.parse(text) }
}

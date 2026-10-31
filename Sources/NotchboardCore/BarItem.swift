import Foundation

/// Something the user keeps in their Notchboard bar.
public struct BarItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case app, file, folder, link, shortcut, widget }
    public enum Widget: String, Codable, CaseIterable, Sendable {
        case clock, cpu, battery, timer
        public var title: String {
            switch self {
            case .clock: return "Clock"
            case .cpu: return "CPU"
            case .battery: return "Battery"
            case .timer: return "Timer"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    /// A file path (app, file, folder), a web address (link), a Shortcut's
    /// name (shortcut), or a widget's raw value (widget).
    public var target: String

    public init(id: UUID = UUID(), kind: Kind, name: String, target: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.target = target
    }

    /// An item for something dropped on the bar: an app, a file or folder, or a web link.
    public static func dropped(_ url: URL, isDirectory: Bool) -> BarItem? {
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            if url.pathExtension.lowercased() == "app" {
                return BarItem(kind: .app, name: url.deletingPathExtension().lastPathComponent, target: path)
            }
            return BarItem(kind: isDirectory ? .folder : .file, name: url.lastPathComponent, target: path)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return BarItem(kind: .link, name: name, target: url.absoluteString)
    }

    /// A link from dropped text, when the text is a web address. Browsers like
    /// Dia drag their address bar as text, sometimes without "https://".
    public static func link(fromText text: String) -> BarItem? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty, !line.contains(" ") else { return nil }
        let lower = line.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: line).flatMap { dropped($0, isDirectory: false) }
        }
        // A bare address: a host with a dot and a real-looking ending, then an optional path.
        let host = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let ending = parts.last, ending.count >= 2, ending.allSatisfy(\.isLetter),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) else { return nil }
        return URL(string: "https://" + line).flatMap { dropped($0, isDirectory: false) }
    }

    public static func widget(_ widget: Widget) -> BarItem {
        BarItem(kind: .widget, name: widget.title, target: widget.rawValue)
    }

    public static func shortcut(_ name: String) -> BarItem {
        BarItem(kind: .shortcut, name: name, target: name)
    }

    public var widget: Widget? { kind == .widget ? Widget(rawValue: target) : nil }

    /// Two items for the same thing (the same app twice, say) count as one.
    public func isSame(as other: BarItem) -> Bool { kind == other.kind && target == other.target }
}

/// The bar's contents and their order.
public struct BarLayout: Codable, Equatable, Sendable {
    public var items: [BarItem]

    public init(items: [BarItem] = []) { self.items = items }

    public static let starter = BarLayout(items: [.widget(.clock), .widget(.cpu)])

    /// Adds an item at `index` (the end when nil). Returns false for a duplicate.
    @discardableResult
    public mutating func add(_ item: BarItem, at index: Int? = nil) -> Bool {
        guard !items.contains(where: { $0.isSame(as: item) }) else { return false }
        items.insert(item, at: min(index ?? items.count, items.count))
        return true
    }

    /// Moves an item so it ends up at `index` in the final order.
    public mutating func move(_ id: UUID, to index: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: max(0, min(index, items.count)))
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}

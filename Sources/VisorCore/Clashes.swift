import Foundation

/// Two sessions changing the same file at about the same time: one can
/// quietly overwrite the other's work.
public struct Clash: Equatable, Sendable, Identifiable {
    public var path: String
    /// The two sessions, first editor first, and their agents.
    public var sessions: [String]
    public var agents: [String]
    /// The latest edit to the file by either session.
    public var lastEdit: Date
    public var id: String { path + "|" + sessions.joined(separator: "|") }

    /// The other session's agent, for the card of `session`.
    public func other(than session: String) -> String? {
        guard let i = sessions.firstIndex(of: session) else { return nil }
        return agents[1 - i]
    }
}

/// Watches edits for clashes: different sessions changing the same file within
/// `window` of each other. A clash is reported once, lasts until neither has
/// touched the file for `window`, and stays quiet once dismissed.
public struct ClashWatch: Sendable {
    public static let window: TimeInterval = 600

    private struct Edit { var session: String; var agent: String; var at: Date }
    private var edits: [String: [Edit]] = [:]
    private var clashes: [String: Clash] = [:]
    private var dismissed: Set<String> = []

    public init() {}

    /// Records an edit; returns a clash when this edit starts one.
    public mutating func record(session: String, agent: String, path: String, at now: Date) -> Clash? {
        var list = (edits[path] ?? []).filter { now.timeIntervalSince($0.at) <= Self.window && $0.session != session }
        let other = list.max { $0.at < $1.at }
        list.append(Edit(session: session, agent: agent, at: now))
        edits[path] = list
        // Already a clash on this file for this session: keep it current.
        if let key = clashes.keys.first(where: { clashes[$0]?.path == path && clashes[$0]?.sessions.contains(session) == true }) {
            clashes[key]?.lastEdit = now
            return nil
        }
        guard let other else { return nil }
        let clash = Clash(path: path, sessions: [other.session, session], agents: [other.agent, agent], lastEdit: now)
        guard !dismissed.contains(clash.id) else { return nil }
        clashes[clash.id] = clash
        return clash
    }

    /// Clashes still going: either session touched the file within the window.
    public func active(at now: Date) -> [Clash] {
        clashes.values.filter { !dismissed.contains($0.id) && now.timeIntervalSince($0.lastEdit) <= Self.window }
            .sorted { $0.lastEdit > $1.lastEdit }
    }

    /// When the next clash goes quiet, to update the notch then (no polling).
    public func nextChange(after now: Date) -> Date? {
        active(at: now).map { $0.lastEdit.addingTimeInterval(Self.window) }.min()
    }

    public mutating func dismiss(_ clash: Clash) {
        dismissed.insert(clash.id)
    }
}

import Foundation

/// How the Agents office looks: the cozy night studio, or a room dressed for a
/// space film with its characters in place of the usual people.
public enum OfficeWorld: String, CaseIterable, Sendable {
    case studio, galaxy, starfleet

    /// From the saved setting; anything missing or unknown is the studio.
    public init(saved: String?) {
        self = saved.flatMap(OfficeWorld.init(rawValue:)) ?? .studio
    }

    public var title: String {
        switch self {
        case .studio: return "Night Studio"
        case .galaxy: return "Galaxy"
        case .starfleet: return "Starfleet"
        }
    }
}

/// Who plays a session in a film world.
public enum OfficeCast {
    /// One of `count` characters for a session: the same one every time, unless
    /// another session already has it, then the next free one. With everyone
    /// cast, characters repeat.
    public static func pick(id: String, count: Int, taken: Set<Int>) -> Int {
        guard count > 0 else { return 0 }
        let seed = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        let start = seed % count
        return (0..<count).map { (start + $0) % count }.first { !taken.contains($0) } ?? start
    }
}

extension OfficeScene {
    /// The break corner is a game table (ping-pong, holochess, poker), not a
    /// sofa: whoever's resting stands around it, left, right, then in front,
    /// facing you. Past three they share the front spot. Everyone else stays put.
    public func aroundTheTable() -> OfficeScene {
        let x = OfficeLayout.sofaX, t = layout.stationTop
        let spots = [OfficePoint(x: x - 15, y: t + 15), OfficePoint(x: x + 14, y: t + 15), OfficePoint(x: x, y: t + 24)]
        var next = self, n = 0
        for i in next.agents.indices where next.agents[i].spot == .sofa {
            next.agents[i].feet = spots[min(n, spots.count - 1)]
            next.agents[i].access = next.agents[i].feet.y
            next.agents[i].sits = false
            next.agents[i].facesUp = false
            n += 1
        }
        return next
    }
}

/// The Agents list when many sessions run: the few that matter as cards, the
/// rest counted. Up to `limit` sessions, everything shows as usual.
public struct AgentsDigest: Equatable, Sendable {
    /// More sessions than the limit: show `top` and a "more" row instead of everything.
    public let capped: Bool
    /// Whoever needs you, then the busy ones, then the most recent.
    public let top: [AgentSession]
    /// Sessions not in `top`.
    public let more: Int
    /// Every session per tool, the busiest tool first.
    public let byTool: [(agent: String, count: Int)]
    /// Idle and finished sessions not in `top`, per tool: folded into one line each.
    public let idle: [(agent: String, count: Int)]

    /// The full list's groups (`AgentBoard.groups`), made once for the panel's size and the list.
    public let groups: [(agent: String, sessions: [AgentSession])]

    /// `room` is the content height left for the cards once everything above and below them
    /// (banners, helpers, MCP and Harness lines) is counted, and `gridRoom` the same for the
    /// full grid (which also draws the Connect button): a list that would pass it folds whole
    /// rows even with `limit` sessions or fewer, but only into a list shorter than the grid.
    /// `keep` (the session whose helpers list is open) always stays among the cards.
    public init(sessions: [AgentSession], limit: Int = 8, room: Double = .infinity, gridRoom: Double? = nil, keep: String? = nil) {
        groups = AgentBoard.groups(sessions)
        let gridRoom = gridRoom ?? room
        let byCount = sessions.count > limit
        let gridHeight = gridRoom.isFinite || room.isFinite ? NotchEars.agentsList(groups: groups) : 0
        var capped = byCount || (gridRoom.isFinite && gridHeight > gridRoom)
        var top = sessions
        if capped {
            // Folded by count: whoever needs you first. By room alone: the grid's own order, so cards don't jump.
            let order = byCount ? sessions.enumerated().sorted { a, b in
                let ra = Office.rank(a.element), rb = Office.rank(b.element)
                if ra != rb { return ra < rb }
                if a.element.since != b.element.since { return a.element.since > b.element.since }
                return a.offset < b.offset
            }.map(\.element) : groups.flatMap(\.sessions)
            top = Array(order.prefix(limit))
            let inactive = sessions.filter { !$0.isActive }
            func idleLines(_ shown: [AgentSession]) -> Int {
                let ids = Set(shown.map(\.id))
                return Set(inactive.lazy.filter { !ids.contains($0.id) }.map(\.agent)).count
            }
            func height(_ shown: [AgentSession]) -> Double {
                NotchEars.agentsDigest(cards: shown.count, idleLines: idleLines(shown), cacheRows: AgentBoard.cacheRows(shown))
            }
            let kept = keep.flatMap { id in sessions.first { $0.id == id } }
            func pin() {
                if let kept, !top.isEmpty, !top.contains(where: { $0.id == kept.id }) { top[top.count - 1] = kept }
            }
            func dropRow() { top.removeLast(top.count % 2 == 0 ? 2 : 1); pin() }
            pin()
            // Cards with the cache line are taller: keep whole rows while they fit where `limit` plain cards would,
            // and within the room the panel has left (at most limit / 2 rounds).
            let plain = NotchEars.cardRows(cards: limit, cacheRows: 0)
            while top.count > 2, NotchEars.cardRows(cards: top.count, cacheRows: AgentBoard.cacheRows(top)) > plain { dropRow() }
            while top.count > 2, height(top) > room { dropRow() }
            // Folded by room alone into a list no shorter than the grid (or hiding nothing): keep the grid; it scrolls.
            if !byCount && (top.count == sessions.count || height(top) >= gridHeight + (room - gridRoom)) {
                capped = false
                top = sessions
            }
        }
        self.capped = capped
        self.top = top
        more = sessions.count - top.count
        func counts(_ list: [AgentSession]) -> [(agent: String, count: Int)] {
            var out: [(agent: String, count: Int)] = []
            for s in list {
                if let i = out.firstIndex(where: { $0.agent == s.agent }) { out[i].count += 1 } else { out.append((s.agent, 1)) }
            }
            return out
        }
        byTool = counts(sessions).enumerated().sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }.map(\.element)
        let shown = Set(top.map(\.id))
        idle = capped ? counts(sessions.filter { !shown.contains($0.id) && !$0.isActive }) : []
    }

    public static func == (a: AgentsDigest, b: AgentsDigest) -> Bool {
        a.capped == b.capped && a.top == b.top && a.more == b.more
            && a.byTool.map(\.agent) == b.byTool.map(\.agent) && a.byTool.map(\.count) == b.byTool.map(\.count)
            && a.idle.map(\.agent) == b.idle.map(\.agent) && a.idle.map(\.count) == b.idle.map(\.count)
    }
}

/// What the Agents panel holds besides the cards: banners above them (away, handoff,
/// Stuck, clash) and the MCP and Harness lines with their open lists (`banners`), the
/// Connect button under the grid, and an open helpers list (its height with its gap).
public struct AgentsPanelExtras: Equatable, Sendable {
    public var banners: Double
    public var connect: Bool
    public var helpers: String?
    public var helpersHeight: Double

    public init(banners: Double = 0, connect: Bool = false, helpers: String? = nil, helpersHeight: Double = 0) {
        self.banners = banners; self.connect = connect; self.helpers = helpers; self.helpersHeight = helpersHeight
    }

    var helpersRoom: Double { helpers == nil ? 0 : helpersHeight }
}

/// The Agents panel's fold and height, from one set of extras, so the list and the
/// panel's size always agree.
public enum AgentsPanel {
    /// The Connect button under the grid: 6 pt spacing, 4 pt top padding and a 28 pt pill.
    public static let connectButton = 6.0 + 4 + 28
    /// The "Show fewer" row under the full list when it was folded.
    public static let showFewer = 6.0 + 26

    /// The digest for content at most `maxContent` tall.
    public static func digest(sessions: [AgentSession], maxContent: Double, extras: AgentsPanelExtras) -> AgentsDigest {
        let room = maxContent - extras.banners - extras.helpersRoom
        return AgentsDigest(sessions: sessions, room: room, gridRoom: room - (extras.connect ? connectButton : 0), keep: extras.helpers)
    }

    /// The content height: the folded list or the full one (with "Show fewer" when unfolded
    /// by the user, and the Connect button), plus the extras.
    public static func contentHeight(digest: AgentsDigest, extras: AgentsPanelExtras, showAll: Bool) -> Double {
        let list: Double
        if digest.capped && !showAll {
            list = NotchEars.agentsDigest(cards: digest.top.count, idleLines: digest.idle.count, cacheRows: AgentBoard.cacheRows(digest.top))
        } else {
            list = NotchEars.agentsList(groups: digest.groups) + (digest.capped ? showFewer : 0) + (extras.connect ? connectButton : 0)
        }
        return list + extras.banners + extras.helpersRoom
    }

    /// The last digest, made again only when its inputs change: the panel's size and the
    /// list ask for it on every render.
    public final class Memo: @unchecked Sendable {
        private var key: (sessions: [AgentSession], maxContent: Double, extras: AgentsPanelExtras)?
        private var value: AgentsDigest?
        /// Digests made, for tests.
        public private(set) var builds = 0

        public init() {}

        public func digest(sessions: [AgentSession], maxContent: Double, extras: AgentsPanelExtras) -> AgentsDigest {
            if let key, let value, key.maxContent == maxContent, key.extras == extras, key.sessions == sessions { return value }
            let made = AgentsPanel.digest(sessions: sessions, maxContent: maxContent, extras: extras)
            key = (sessions, maxContent, extras)
            value = made
            builds += 1
            return made
        }
    }
}

/// What a launch shows: the intro with the full welcome the first time, the
/// intro with a short hello every time after. VISOR_INTRO forces the full
/// welcome ("1") or nothing ("0").
public enum IntroKind: Equatable, Sendable { case off, welcome, hello }

public enum IntroGate {
    public static func kind(seen: Bool, environment: [String: String]) -> IntroKind {
        switch environment["VISOR_INTRO"] {
        case "1": return .welcome
        case "0": return .off
        default: return seen ? .hello : .welcome
        }
    }
}

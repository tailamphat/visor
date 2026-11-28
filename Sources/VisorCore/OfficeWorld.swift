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

    public init(sessions: [AgentSession], limit: Int = 8) {
        capped = sessions.count > limit
        let ranked = sessions.enumerated().sorted { a, b in
            let ra = Office.rank(a.element), rb = Office.rank(b.element)
            if ra != rb { return ra < rb }
            if a.element.since != b.element.since { return a.element.since > b.element.since }
            return a.offset < b.offset
        }.map(\.element)
        var top = capped ? Array(ranked.prefix(limit)) : sessions
        // Cards with the cache line are taller: keep whole rows while they fit where `limit` plain cards would.
        if capped {
            let room = NotchEars.cardRows(cards: limit, cacheRows: 0)
            while top.count > 2, NotchEars.cardRows(cards: top.count, cacheRows: AgentBoard.cacheRows(top)) > room {
                top.removeLast(top.count % 2 == 0 ? 2 : 1)
            }
        }
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

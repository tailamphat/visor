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
    /// The film worlds' break is a game table (holochess, poker), not a sofa:
    /// whoever's resting stands around it, left, right, then in front, facing
    /// you. Past three they share the front spot. Everyone else stays put.
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

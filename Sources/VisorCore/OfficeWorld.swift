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

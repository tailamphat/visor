import Foundation

/// What whoever's on break plays in the office: darts alone, the world's table
/// game together (ping-pong in the studio, holochess in the galaxy, poker on the
/// starship). It plays in rounds: play, someone wins and cheers, reset.
public enum BreakGame: String, Equatable, Sendable {
    case darts, pingPong, holochess, poker

    /// Nothing for an empty break corner; darts for one; the world's game for more.
    public static func pick(world: OfficeWorld, players: Int) -> BreakGame? {
        guard players > 0 else { return nil }
        if players == 1 { return .darts }
        switch world {
        case .studio: return .pingPong
        case .galaxy: return .holochess
        case .starfleet: return .poker
        }
    }

    /// One round, in seconds.
    public var round: Double {
        switch self {
        case .darts: return 5.4
        case .pingPong: return 6
        case .holochess: return 8
        case .poker: return 9
        }
    }

    /// When in a round the winner cheers; the cheer lasts `cheer`.
    public var winAt: Double {
        switch self {
        case .darts: return 3.9
        case .pingPong: return 4.4
        case .holochess: return 6.1
        case .poker: return 6.5
        }
    }

    public static let cheer = 1.2

    /// Who wins each round of one loop, by player index: everyone once, in turn.
    /// Ping-pong is two at the table; a third only watches.
    public func winners(players: Int) -> [Int] {
        switch self {
        case .darts: return [0]
        case .pingPong: return [0, 1]
        case .holochess, .poker: return Array(0..<max(1, min(players, OfficeLayout.sofaSeats)))
        }
    }

    /// One loop: every round, so it repeats with the same animation.
    public func loop(players: Int) -> Double { round * Double(winners(players: players).count) }
}

import Testing
@testable import VisorCore

@Suite("Break games")
struct BreakGameTests {
    /// Alone it's darts; together, the world's own game; nobody, nothing.
    @Test func gameFitsTheWorldAndTheCrowd() {
        #expect(BreakGame.pick(world: .studio, players: 0) == nil)
        for world in OfficeWorld.allCases { #expect(BreakGame.pick(world: world, players: 1) == .darts) }
        #expect(BreakGame.pick(world: .studio, players: 2) == .pingPong)
        #expect(BreakGame.pick(world: .galaxy, players: 3) == .holochess)
        #expect(BreakGame.pick(world: .starfleet, players: 2) == .poker)
    }

    /// Everyone at the table wins a round in turn; ping-pong's third player only watches.
    @Test func winnersTakeTurns() {
        #expect(BreakGame.poker.winners(players: 3) == [0, 1, 2])
        #expect(BreakGame.holochess.winners(players: 2) == [0, 1])
        #expect(BreakGame.pingPong.winners(players: 3) == [0, 1])
        #expect(BreakGame.darts.winners(players: 1) == [0])
        #expect(BreakGame.poker.loop(players: 3) == 27)
    }

    /// The cheer fits inside its round.
    @Test func cheerFitsTheRound() {
        for game in [BreakGame.darts, .pingPong, .holochess, .poker] {
            #expect(game.winAt + BreakGame.cheer < game.round)
        }
    }
}

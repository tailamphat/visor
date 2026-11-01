import Foundation
import Testing
@testable import VisorCore

@Suite("Play and pause from the notch")
struct PlaybackIntentTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    @Test func withoutAPressTheObservedStateWins() {
        var intent = PlaybackIntent()
        let playing = intent.resolve(observed: true, now: t0)
        let paused = intent.resolve(observed: false, now: t0)
        #expect(playing && !paused)
    }

    @Test func aPauseIsTrustedWhileTheBrowserStillSoundsPlaying() {
        var intent = PlaybackIntent()
        intent.pressed(playing: false, at: t0)
        // Dia keeps its audio stream open for a few seconds after pausing.
        let soon = intent.resolve(observed: true, now: t0.addingTimeInterval(0.6))
        let later = intent.resolve(observed: true, now: t0.addingTimeInterval(4))
        #expect(!soon && !later)
    }

    @Test func onceConfirmedTheObservedStateWinsAgain() {
        var intent = PlaybackIntent()
        intent.pressed(playing: false, at: t0)
        let confirmed = intent.resolve(observed: false, now: t0.addingTimeInterval(1))
        // Confirmed, so a later real play (say, from the page) shows straight away.
        let playedFromPage = intent.resolve(observed: true, now: t0.addingTimeInterval(2))
        #expect(!confirmed && playedFromPage)
    }

    @Test func aPressThatNeverTookEffectExpires() {
        var intent = PlaybackIntent()
        intent.pressed(playing: false, at: t0)
        let expired = intent.resolve(observed: true, now: t0.addingTimeInterval(PlaybackIntent.window + 1))
        #expect(expired)
    }
}

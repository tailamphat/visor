import Foundation
import Testing
@testable import VisorCore

private let stop = Date(timeIntervalSince1970: 1_800_000_000)

private func usage(model: String = "claude-opus-4-5", input: Int = 0, read: Int = 0,
                   w5: Int = 0, w1: Int = 0) -> TokenUsage {
    TokenUsage(model: model, timestamp: stop, input: input, cacheWrite5m: w5, cacheWrite1h: w1, cacheRead: read)
}

@Suite("Cache clock")
struct CacheClockTests {
    @Test func windowIsFiveMinutesOrOneHour() {
        #expect(CacheClock.window(for: usage(w5: 100)) == 300)
        #expect(CacheClock.window(for: usage(w5: 100, w1: 1)) == 3600)
        let at = stop.addingTimeInterval(299)
        #expect(CacheClock.state(last: usage(w5: 100), stoppedAt: stop, now: at) == .warm(secondsLeft: 1))
        #expect(CacheClock.state(last: usage(w1: 100), stoppedAt: stop, now: at) == .warm(secondsLeft: 3301))
        let later = stop.addingTimeInterval(300)
        if case .cold = CacheClock.state(last: usage(w5: 100), stoppedAt: stop, now: later) {} else { Issue.record("not cold") }
    }

    @Test func warmText() {
        let text = CacheClock.text(last: usage(w5: 1), stoppedAt: stop, now: stop.addingTimeInterval(120))
        #expect(text == "Cache warm · about 3m left")
        let hour = CacheClock.text(last: usage(w1: 1), stoppedAt: stop, now: stop.addingTimeInterval(60))
        #expect(hour == "Cache warm · about 59m left")
    }

    @Test func warmUnderAMinute() {
        let text = CacheClock.text(last: usage(w5: 1), stoppedAt: stop, now: stop.addingTimeInterval(290))
        #expect(text == "Cache warm · about 1m left")
    }

    @Test func coldText() {
        // 142,000 tokens at opus-4-5: 5m writes at $6.25 per million.
        let last = usage(input: 2000, read: 100_000, w5: 40_000)
        let text = CacheClock.text(last: last, stoppedAt: stop, now: stop.addingTimeInterval(600))
        #expect(text == "Cache cold · next reply re-reads 142k · about $0.89")
    }

    @Test func coldPricedAtOneHourRate() {
        let last = usage(read: 100_000, w5: 20_000, w1: 20_000)
        guard case .cold(let tokens, let dollars) = CacheClock.state(last: last, stoppedAt: stop, now: stop.addingTimeInterval(4000)) else {
            Issue.record("not cold"); return
        }
        #expect(tokens == 140_000)
        // 1 h window: everything at $10 per million.
        #expect(abs(dollars - 1.4) < 1e-9)
    }

    @Test func formats() {
        #expect(CacheClock.tokens(999) == "999")
        #expect(CacheClock.tokens(142_400) == "142k")
        #expect(CacheClock.tokens(1_260_000) == "1.3M")
        #expect(CacheClock.dollars(0.001) == "$0.01")
        #expect(CacheClock.dollars(0.534) == "$0.53")
        #expect(CacheClock.dollars(123.4) == "$123")
    }

    @Test func missingOrUnpriced() {
        #expect(CacheClock.state(last: nil, stoppedAt: stop, now: stop) == nil)
        #expect(CacheClock.text(last: usage(model: "gpt-x", w5: 5), stoppedAt: stop, now: stop) == nil)
    }

    @Test func neverPercent() {
        let cold = CacheClock.text(last: usage(read: 1000), stoppedAt: stop, now: stop.addingTimeInterval(9000)) ?? ""
        let warm = CacheClock.text(last: usage(w5: 1), stoppedAt: stop, now: stop) ?? ""
        for text in [cold, warm] { #expect(!text.contains("%") && !text.contains("limit")) }
        #expect(cold.contains("about $"))
        #expect(warm.contains("about "))
    }
}

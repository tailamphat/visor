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

    @Test func cardTextWarm() {
        let five = CacheClock.line(last: usage(w5: 1), stoppedAt: stop, now: stop.addingTimeInterval(180))
        #expect(five?.text == "Cache warm · about 2m left" && five?.warm == true)
        let hour = CacheClock.line(last: usage(w1: 1), stoppedAt: stop, now: stop)
        #expect(hour?.text == "Cache warm · about 60m left")
    }

    @Test func cardTextCold() {
        // 142,000 tokens re-read at the 5 min write rate of opus-4-5.
        let last = usage(input: 2000, read: 100_000, w5: 40_000)
        let line = CacheClock.line(last: last, stoppedAt: stop, now: stop.addingTimeInterval(600))
        #expect(line?.text == "Cache cold · 142k · about $0.89" && line?.warm == false)
        // The price is its own piece, so the card can keep it whole while the rest gives way.
        // Three pieces: the label stays, the number gives way first, the price stays whole.
        #expect(line?.label == "Cache cold" && line?.detail == " · 142k" && line?.price == " · about $0.89")
        let warm = CacheClock.line(last: last, stoppedAt: stop, now: stop)
        #expect(warm?.label == warm?.text && warm?.detail == "" && warm?.price == "")
    }

    @Test func cardTextFitsHugeCounts() {
        // 980M tokens: still short enough for a half-width card, the price in full.
        let last = usage(read: 980_000_000, w5: 100_000)
        let line = CacheClock.line(last: last, stoppedAt: stop, now: stop.addingTimeInterval(600))
        #expect(line?.text == "Cache cold · 980.1M · about $6,126")
        let billions = usage(read: 2_500_000_000)
        let huge = CacheClock.line(last: billions, stoppedAt: stop, now: stop.addingTimeInterval(600))
        #expect(huge?.text == "Cache cold · 2.5B · about $15,625")
    }

    // QA case 10: the last seconds of the window still read a whole minute.
    @Test func warmNeverZeroMinutes() {
        for seconds in [299.0, 299.5, 299.99] {
            let line = CacheClock.line(last: usage(w5: 1), stoppedAt: stop, now: stop.addingTimeInterval(seconds))
            #expect(line?.text == "Cache warm · about 1m left")
        }
        #expect(CacheClock.line(last: usage(w5: 1), stoppedAt: stop, now: stop.addingTimeInterval(300))?.warm == false)
    }

    // QA case 28 (epic QA case 9): prices from under a cent to thousands, always whole.
    @Test func pricesFromCentsToThousands() {
        #expect(CacheClock.dollars(0.0004) == "$0.01")
        #expect(CacheClock.dollars(0.5) == "$0.50")
        #expect(CacheClock.dollars(50.25) == "$50.25")
        #expect(CacheClock.dollars(999.6) == "$1,000")
        #expect(CacheClock.dollars(1875) == "$1,875")
        #expect(CacheClock.dollars(15_625) == "$15,625")
        #expect(CacheClock.dollars(1_234_567) == "$1,234,567")
    }

    // QA case 29 (epic QA case 10): token counts stay compact up to billions.
    @Test func tokenCountsCompact() {
        #expect(CacheClock.tokens(640) == "640")
        #expect(CacheClock.tokens(142_400) == "142k")
        #expect(CacheClock.tokens(999_600) == "1.0M", "never 1000k")
        #expect(CacheClock.tokens(1_200_000) == "1.2M")
        #expect(CacheClock.tokens(250_000_000) == "250.0M")
        #expect(CacheClock.tokens(999_940_000) == "999.9M")
        #expect(CacheClock.tokens(999_960_000) == "1.0B")
        #expect(CacheClock.tokens(2_500_000_000) == "2.5B")
    }

    @Test func cardTextNeverPercent() {
        #expect(CacheClock.line(last: nil, stoppedAt: stop, now: stop) == nil)
        for seconds in [0.0, 200, 299, 300, 4000] {
            for last in [usage(w5: 1), usage(read: 90_000, w1: 5000)] {
                let line = CacheClock.line(last: last, stoppedAt: stop, now: stop.addingTimeInterval(seconds))
                let all = (line?.text ?? "") + (line?.help ?? "")
                #expect(line != nil && !all.contains("%") && !all.lowercased().contains("limit"))
            }
        }
    }

    @Test func cardHelpIsFullSentence() {
        for seconds in [60.0, 900] {
            let last = usage(input: 2000, read: 100_000, w5: 40_000)
            let now = stop.addingTimeInterval(seconds)
            #expect(CacheClock.line(last: last, stoppedAt: stop, now: now)?.help
                    == CacheClock.text(last: last, stoppedAt: stop, now: now))
        }
    }

}

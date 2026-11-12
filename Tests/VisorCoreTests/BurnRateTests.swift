import Foundation
import Testing
@testable import VisorCore

@Suite("Burn rate")
struct BurnRateTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    @Test func fastSessionRunsOutBeforeReset() {
        // 64% used, 2 h 50 m into a 5 h window, nothing recorded yet: the average.
        let forecast = BurnForecast.make(used: 64, resetsAt: now + 2 * hour + 600, window: 5 * hour, history: [], now: now)
        guard case .runsOut(let at) = forecast else { Issue.record("\(String(describing: forecast))"); return }
        // 64% in 170 min is 0.376%/min; 36% lasts about 96 min.
        #expect(abs(at.timeIntervalSince(now) - 95.6 * 60) < 60)
    }

    @Test func slowWeekLastsUntilReset() {
        // 41% three days into the week: about 96% by the reset.
        let forecast = BurnForecast.make(used: 41, resetsAt: now + 4 * 86_400, window: 7 * 86_400, history: [], now: now)
        guard case .lasts(let left) = forecast else { Issue.record("\(String(describing: forecast))"); return }
        #expect(abs(left - 4.3) < 0.5)
    }

    @Test func recentReadingsBeatTheAverage() {
        // Quiet morning, then 20% in the last 30 minutes.
        var history = UsageHistory()
        history.record("claude.five_hour", used: 30, at: now - 1800)
        history.record("claude.five_hour", used: 40, at: now - 900)
        let forecast = BurnForecast.make(used: 50, resetsAt: now + 3 * hour, window: 5 * hour,
                                         history: history.samples("claude.five_hour"), now: now)
        guard case .runsOut(let at) = forecast else { Issue.record("\(String(describing: forecast))"); return }
        #expect(abs(at.timeIntervalSince(now) - 75 * 60) < 60, "50% left at 40%/h")
    }

    @Test func idleHasNoForecast() {
        var history = UsageHistory()
        history.record("x", used: 50, at: now - 1800)
        #expect(BurnForecast.make(used: 50, resetsAt: now + hour, window: 5 * hour, history: history.samples("x"), now: now) == nil)
    }

    @Test func tooEarlyToTell() {
        // Five minutes into the window, one reading: no rate yet.
        #expect(BurnForecast.make(used: 4, resetsAt: now + 5 * hour - 300, window: 5 * hour, history: [], now: now) == nil)
        // Recent readings only a couple of minutes apart fall back to the average.
        var history = UsageHistory()
        history.record("x", used: 49, at: now - 120)
        #expect(BurnForecast.make(used: 50, resetsAt: now + hour, window: nil, history: history.samples("x"), now: now) == nil)
    }

    @Test func spentOrUnknownHasNoForecast() {
        #expect(BurnForecast.make(used: 100, resetsAt: now + hour, window: 5 * hour, history: [], now: now) == nil)
        #expect(BurnForecast.make(used: 50, resetsAt: nil, window: nil, history: [], now: now) == nil)
    }

    @Test func historyKeepsOneReadingBeforeTheLastHalfHour() {
        var history = UsageHistory()
        for minutes in [90, 60, 40, 20, 5] { history.record("x", used: Double(100 - minutes), at: now - Double(minutes) * 60) }
        #expect(history.samples("x").map(\.used) == [60, 80, 95], "the newest one older than 30 min stays as the baseline")
    }

    @Test func aResetStartsTheHistoryOver() {
        var history = UsageHistory()
        history.record("x", used: 90, at: now - 600)
        history.record("x", used: 2, at: now)
        #expect(history.samples("x").map(\.used) == [2])
    }

    @Test func windows() {
        #expect(BurnForecast.window(claude: "five_hour") == 5 * hour)
        #expect(BurnForecast.window(claude: "seven_day_opus") == 7 * 24 * hour)
        #expect(BurnForecast.window(claude: "something_new") == nil)
        #expect(BurnForecast.window(openCode: "rolling") == 5 * hour)
        let reset = Date(timeIntervalSince1970: 1_796_083_200) // 1 Dec 2026, UTC
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(BurnForecast.monthWindow(endingAt: reset, calendar: calendar) == 30 * 24 * hour)
    }

    @Test func durationText() {
        #expect(BurnForecast.duration(20) == "1m")
        #expect(BurnForecast.duration(42 * 60 + 10) == "42m")
        #expect(BurnForecast.duration(75 * 60) == "1h 15m")
        #expect(BurnForecast.duration(2 * 86_400) == nil, "a date reads better")
    }

    @Test func notchShowsTimeOnlyWhenItRunsOutWithinTheHour() {
        var quota = NotchQuota(agent: "Claude Code", percentLeft: 36, label: "")
        #expect(quota.text == "36%")
        quota.runsOutIn = 42 * 60
        #expect(quota.text == "42m")
        #expect(quota.level == .warning)
        quota.runsOutIn = 10 * 60
        #expect(quota.level == .critical)
        quota.runsOutIn = 2 * 3600
        #expect(quota.text == "36%", "more than an hour away: the percent")
    }
}

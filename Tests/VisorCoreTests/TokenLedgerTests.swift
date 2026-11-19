import Foundation
import Testing
@testable import VisorCore

@Suite("Token ledger")
struct TokenLedgerTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func date(_ day: String, _ hour: Int = 12) -> Date {
        ISO8601DateFormatter().date(from: "\(day)T\(String(format: "%02d", hour)):00:00Z")!
    }

    @Test func countsAddUpWithAndWithoutCacheReads() {
        let count = TokenCount(input: 10, output: 20, cacheRead: 1000, cacheWrite: 5)
        #expect(count.total == 1035)
        #expect(count.withoutCacheRead == 35)
        #expect(count + count == TokenCount(input: 20, output: 40, cacheRead: 2000, cacheWrite: 10))
    }

    /// A day's count only grows: when Claude Code deletes old transcripts the
    /// ledger keeps what it saw, and new tokens on a day replace the old count.
    @Test func historySurvivesDeletedLogs() {
        var ledger = TokenLedger()
        let first = ["2026-11-01": ["Claude Code|claude-opus-5-5": TokenCount(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)]]
        let added = ledger.merge(first), again = ledger.merge(first), deleted = ledger.merge([:])
        #expect(added)
        #expect(!again, "nothing new")
        #expect(!deleted, "logs deleted: history stays")
        #expect(ledger.days["2026-11-01"]?["Claude Code|claude-opus-5-5"]?.total == 10)
        let more = ["2026-11-01": ["Claude Code|claude-opus-5-5": TokenCount(input: 5, output: 2, cacheRead: 3, cacheWrite: 4)]]
        let grew = ledger.merge(more)
        #expect(grew)
        #expect(ledger.days["2026-11-01"]?["Claude Code|claude-opus-5-5"]?.input == 5)
    }

    @Test func savesAndLoads() throws {
        var ledger = TokenLedger()
        ledger.merge(["2026-11-01": ["OpenCode|big-pickle": TokenCount(input: 7)]])
        let loaded = try JSONDecoder().decode(TokenLedger.self, from: JSONEncoder().encode(ledger))
        #expect(loaded == ledger)
    }

    /// Claude Code transcripts: one entry per day, tool and model; cache writes of both lifetimes.
    @Test func claudeRecordsByDayAndModel() {
        let records = [
            TokenUsage(model: "claude-opus-5-5", timestamp: date("2026-11-01", 9), input: 1, output: 2, cacheWrite5m: 3, cacheWrite1h: 4, cacheRead: 5),
            TokenUsage(model: "claude-opus-5-5", timestamp: date("2026-11-01", 20), input: 1),
            TokenUsage(model: "claude-haiku-5-5", timestamp: date("2026-11-02"), output: 9),
            TokenUsage(model: "<synthetic>", timestamp: date("2026-11-02"), output: 99),
        ]
        let days = TokenLedger.daily(claude: records, calendar: calendar)
        #expect(days["2026-11-01"]?["Claude Code|claude-opus-5-5"] == TokenCount(input: 2, output: 2, cacheRead: 5, cacheWrite: 7))
        #expect(days["2026-11-02"]?["Claude Code|claude-haiku-5-5"]?.output == 9)
        #expect(days["2026-11-02"]?.count == 1, "Claude Code's own placeholder replies aren't a model")
    }

    /// Copilot CLI's session store, summed by day and model in sqlite; dotted
    /// model names read like Claude Code's.
    @Test func copilotRowsFromSQLite() {
        #expect(TokenLedger.copilotQuery.contains("assistant_usage_events"))
        let json = Data(#"[{"day":"2026-11-03","model":"claude-sonnet-5.5","input":100,"output":20,"cache_read":300,"cache_write":40}]"#.utf8)
        let days = TokenLedger.daily(copilot: json)
        #expect(days?["2026-11-03"]?["Copilot CLI|claude-sonnet-5-5"] == TokenCount(input: 100, output: 20, cacheRead: 300, cacheWrite: 40))
        #expect(TokenLedger.daily(copilot: Data("nope".utf8)) == nil)
    }

    /// OpenCode, all time, by day and model, from whichever message table it has.
    @Test func openCodeRowsFromSQLite() {
        let query = TokenLedger.openCodeQuery(tables: ["message"])
        #expect(query?.contains("modelID") == true && query?.contains("GROUP BY") == true)
        #expect(TokenLedger.openCodeQuery(tables: []) == nil)
        let json = Data(#"[{"day":"2026-11-04","model":"big-pickle","input":5,"output":6,"cache_read":7,"cache_write":0}]"#.utf8)
        #expect(TokenLedger.daily(openCode: json)?["2026-11-04"]?["OpenCode|big-pickle"]?.total == 18)
    }

    /// The Tokens view: a range's totals, models and tools by size, busiest day,
    /// and a chart series with a slot for every day.
    @Test func summaryForARange() {
        var ledger = TokenLedger()
        ledger.merge([
            "2026-11-01": ["Claude Code|claude-opus-5-5": TokenCount(input: 100, cacheRead: 900)],
            "2026-11-05": ["Claude Code|claude-opus-5-5": TokenCount(output: 10),
                           "Copilot CLI|claude-sonnet-5-5": TokenCount(input: 40)],
        ])
        let all = ledger.summary(days: nil, now: date("2026-11-05"), calendar: calendar)
        #expect(all.total.total == 1050 && all.total.withoutCacheRead == 150)
        #expect(all.models.map(\.model) == ["claude-opus-5-5", "claude-sonnet-5-5"])
        #expect(all.models.first?.tool == "Claude Code")
        #expect(all.tools.map(\.tool) == ["Claude Code", "Copilot CLI"])
        #expect(all.activeDays == 2)
        #expect(all.peak?.day == "2026-11-01" && all.peak?.total == 1000)
        #expect(all.series.count == 5, "every day from the first to today")
        #expect(all.series.last?.byModel["claude-sonnet-5-5"] == 40)
        #expect(all.daily.first?.day == "2026-11-05", "newest first")

        let week = ledger.summary(days: 3, now: date("2026-11-05"), calendar: calendar)
        #expect(week.total.total == 50 && week.series.count == 3)
    }
}

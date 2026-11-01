import Foundation
import Testing
@testable import VisorCore

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Suite("Pricing")
struct PricingTests {
    @Test func opusListPrice() throws {
        let opus = try #require(Pricing.price(for: "claude-opus-5-5"))
        #expect(opus.input == 4 && opus.output == 20 && opus.cacheRead == 0.20)
    }

    @Test func cacheWritesAreMultiplesOfInput() throws {
        let opus = try #require(Pricing.price(for: "claude-opus-5-5"))
        #expect(opus.cacheWrite5m == 5 && opus.cacheWrite1h == 8)
    }

    @Test("Model ids match by prefix, most specific first", arguments: [
        ("claude-opus-5", 5.0), ("claude-opus-4-1-20250805", 15.0), ("claude-sonnet-5", 2.0), ("claude-haiku-4-5-20251001", 1.0),
    ])
    func prefixes(model: String, input: Double) {
        #expect(Pricing.price(for: model)?.input == input)
    }

    @Test func syntheticMessagesCostNothing() {
        #expect(Pricing.price(for: "<synthetic>") == nil)
    }

    @Test func costAddsEveryTokenKind() {
        let usage = TokenUsage(model: "claude-opus-5-5", timestamp: Date(), input: 1_000_000, output: 1_000_000,
                               cacheWrite5m: 0, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
        #expect(near(usage.cost, 4 + 20 + 8 + 0.2))
        var fast = usage
        fast.fast = true
        #expect(near(fast.cost, usage.cost * 2))
    }
}

@Suite("Transcripts")
struct TranscriptTests {
    static let line1 = #"{"type":"assistant","requestId":"req_1","timestamp":"2026-10-31T02:31:01.360Z","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":100,"ephemeral_5m_input_tokens":0},"speed":"standard"}}}"#
    static let user = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
    static let noSplit = #"{"type":"assistant","requestId":"req_2","timestamp":"2026-10-31T03:00:00Z","message":{"id":"msg_2","model":"claude-sonnet-5","usage":{"input_tokens":10,"cache_creation_input_tokens":40,"output_tokens":5}}}"#

    @Test func duplicateContentBlocksCountOnce() {
        let log = TranscriptUsage()
        log.ingest(Data([Self.line1, Self.user, Self.line1, Self.noSplit, ""].joined(separator: "\n").utf8))
        #expect(log.records.count == 2)
        #expect(log.records[0].cacheWrite1h == 100 && log.records[0].cacheWrite5m == 0 && log.records[0].cacheRead == 1000)
        #expect(log.records[1].cacheWrite5m == 40, "without a split, cache writes count as 5-minute")
        #expect(log.records[1].timestamp == ISO8601DateFormatter().date(from: "2026-10-31T03:00:00Z"))
    }

    @Test func incrementalScanReadsCompleteLinesOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nb-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("s.jsonl")
        try Data((Self.line1 + "\n" + #"{"type":"assistant","#).utf8).write(to: file)

        let scanner = TranscriptUsage()
        #expect(scanner.scan(root: dir) && scanner.records.count == 1)
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data(#""requestId":"req_3","timestamp":"2026-10-31T04:00:00Z","message":{"id":"msg_3","model":"claude-opus-5-5","usage":{"output_tokens":7}}}"#.utf8 + [0x0A]))
        try handle.close()
        #expect(scanner.scan(root: dir) && scanner.records.count == 2, "a finished half-line is picked up next scan")
        #expect(!scanner.scan(root: dir), "an unchanged directory finds nothing new")
    }

    /// `VISOR_REAL=1 swift test --filter realTranscripts` times a scan of this Mac's transcripts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VISOR_REAL"] != nil))
    func realTranscripts() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let log = TranscriptUsage()
        let start = Date()
        log.scan(root: root)
        let first = Date().timeIntervalSince(start)
        let again = Date()
        log.scan(root: root)
        print(String(format: "%d responses, first scan %.2fs, rescan %.3fs", log.records.count, first, Date().timeIntervalSince(again)))
        #expect(first < 5)
    }
}

@Suite("Spend summary")
struct SpendSummaryTests {
    @Test func totalsAndDailyBars() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
        func spend(_ daysAgo: Double, _ output: Int) -> TokenUsage {
            TokenUsage(model: "claude-sonnet-5", timestamp: now.addingTimeInterval(-daysAgo * 86_400), output: output)
        }
        // Sonnet 5 output is $10/MTok, so 100k tokens is $1.
        let s = SpendSummary.make(from: [spend(0, 100_000), spend(1, 200_000), spend(6, 100_000), spend(10, 100_000), spend(40, 100_000)],
                                  now: now, calendar: calendar)
        #expect(near(s.today, 1) && near(s.last7Days, 4) && near(s.last30Days, 5))
        #expect(s.daily.count == 14 && near(s.daily[13], 1) && near(s.daily[12], 2) && near(s.daily[3], 1))
        #expect(s.tokensToday == 100_000)
    }
}

@Suite("Plan limits")
struct PlanLimitTests {
    @Test func limitsListWins() throws {
        let json = #"{"five_hour":{"utilization":25.0,"resets_at":"2026-10-31T06:09:59.753857+00:00"},"limits":[{"kind":"session","percent":27,"severity":"normal","resets_at":"2026-10-31T06:09:59.773043+00:00"},{"kind":"weekly_all","percent":19,"severity":"normal","resets_at":"2026-11-05T08:59:59.773061+00:00"}],"extra_usage":{"is_enabled":false}}"#
        let plan = try #require(PlanUsage.parse(Data(json.utf8)))
        #expect(plan.limits.count == 2)
        #expect(plan.session?.percentUsed == 27 && plan.session?.percentLeft == 73)
        #expect(plan.session?.resetsAt != nil, "reset time with microseconds parses")
        #expect(plan.limits[1].title == "Weekly")
        #expect(plan.extra == nil, "disabled extra usage is hidden")
    }

    @Test func olderShapeStillParses() throws {
        let old = try #require(PlanUsage.parse(Data(#"{"five_hour":{"utilization":40,"resets_at":null},"seven_day":{"utilization":10}}"#.utf8)))
        #expect(old.limits.map(\.kind) == ["five_hour", "seven_day"] && old.session?.percentUsed == 40)
    }

    @Test func emptyResponseIsNoData() {
        #expect(PlanUsage.parse(Data("{}".utf8)) == nil)
    }
}

@Suite("Copilot usage")
struct CopilotUsageTests {
    static let business = #"{"login":"octocat","copilot_plan":"business","quota_reset_date":"2026-11-01","quota_reset_date_utc":"2026-11-01T00:00:00.000Z","quota_snapshots":{"chat":{"unlimited":true,"entitlement":0,"remaining":0},"completions":{"unlimited":true},"premium_interactions":{"entitlement":15000,"remaining":8906,"percent_remaining":59.3,"unlimited":false,"overage_permitted":true,"overage_count":0}}}"#

    @Test func businessSeat() throws {
        let c = try #require(CopilotUsage.parse(Data(Self.business.utf8), host: "acme.ghe.com"))
        #expect(c.title == "Copilot Business" && c.login == "octocat" && c.host == "acme.ghe.com")
        #expect(c.premiumUsed == 6094 && c.premiumRemaining == 8906 && abs(c.percentLeft - 59.37) < 0.01)
        #expect(c.chatUnlimited && c.completionsUnlimited && c.overagePermitted && c.isTracked)
    }

    @Test func perDayPace() throws {
        let c = try #require(CopilotUsage.parse(Data(Self.business.utf8), host: "acme.ghe.com"))
        let oct30 = ISO8601DateFormatter().date(from: "2026-10-30T00:00:00Z")!
        #expect(c.perDayToLast(now: oct30) == 4453)
        #expect(c.perDayToLast(now: oct30.addingTimeInterval(86_400 + 3600)) == nil, "no per-day figure on the last day")
    }

    @Test func freePlanIsNotTracked() throws {
        let free = try #require(CopilotUsage.parse(Data(#"{"login":"me","copilot_plan":"individual","quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0}}}"#.utf8), host: "github.com"))
        #expect(!free.isTracked)
        #expect(CopilotUsage.parse(Data("{}".utf8), host: "x") == nil)
    }

    @Test("API roots", arguments: [
        ("github.com", "https://api.github.com"), ("acme.ghe.com", "https://api.acme.ghe.com"),
    ])
    func apiBase(host: String, api: String) {
        #expect(CopilotUsage.apiBase(for: host)?.absoluteString == api)
    }

    @Test func otherHostsAreSkipped() {
        #expect(CopilotUsage.apiBase(for: "git.example.com") == nil)
    }

    @Test func hostsFromGhAuthStatus() {
        let status = """
        github.com
          ✓ Logged in to github.com account octocat (keyring)
        acme.ghe.com
          ✓ Logged in to acme.ghe.com account octocat-ext (keyring)
        """
        #expect(CopilotUsage.signedInHosts(fromStatus: status) == ["github.com", "acme.ghe.com"])
    }
}

@Suite("Pricing, more")
struct PricingMoreTests {
    @Test("Cache read prices that differ from 0.1x input", arguments: [
        ("claude-fable-5-1", 0.25), ("claude-opus-5-5", 0.20), ("claude-sonnet-5-5", 0.20), ("claude-sonnet-4-6", 0.30),
    ])
    func cacheReads(model: String, read: Double) throws {
        // Prices are derived from input (3 x 0.1 is 0.30000000000000004), so compare closely, not exactly.
        let price = try #require(Pricing.price(for: model))
        #expect(near(price.cacheRead, read))
    }

    @Test func unknownModelsCostNothing() {
        #expect(TokenUsage(model: "gpt-9", timestamp: Date(), input: 1_000_000, output: 1_000_000).cost == 0)
    }
}

@Suite("Transcripts, more")
struct TranscriptMoreTests {
    func folder(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func aRewrittenShorterFileIsReadAgainWithoutDoubleCounting() throws {
        try folder { dir in
            let file = dir.appendingPathComponent("s.jsonl")
            try Data((TranscriptTests.line1 + "\n" + TranscriptTests.noSplit + "\n").utf8).write(to: file)
            let scanner = TranscriptUsage()
            scanner.scan(root: dir)
            #expect(scanner.records.count == 2)
            // Rewritten (e.g. compacted) with only the first response: shorter than before.
            try Data((TranscriptTests.line1 + "\n").utf8).write(to: file)
            scanner.scan(root: dir)
            #expect(scanner.records.count == 2, "the same responses aren't counted twice")
        }
    }

    @Test func onlyJSONLFilesAreRead() throws {
        try folder { dir in
            try Data((TranscriptTests.line1 + "\n").utf8).write(to: dir.appendingPathComponent("notes.txt"))
            let scanner = TranscriptUsage()
            #expect(!scanner.scan(root: dir) && scanner.records.isEmpty)
        }
    }

    @Test func brokenAndUnrelatedLinesAreSkipped() {
        let log = TranscriptUsage()
        let lines = [
            #"{"type":"assistant","message":{"usage":{"output_tokens":1}}"#,                       // cut off
            #"{"type":"user","message":{"content":"what is my \"usage\" today?"}}"#,               // a user asking about usage
            #"{"type":"assistant","timestamp":"2026-10-31T02:31:01Z","message":{"usage":{"output_tokens":5}}}"#, // no model
            "",
        ]
        log.ingest(Data(lines.joined(separator: "\n").utf8))
        #expect(log.records.isEmpty)
    }
}

@Suite("Spend summary, more")
struct SpendMoreTests {
    @Test func nothingSpent() {
        let s = SpendSummary.make(from: [])
        #expect(s.today == 0 && s.last30Days == 0 && s.daily == Array(repeating: 0, count: 14))
    }

    @Test func futureTimestampsAreIgnored() {
        let now = Date()
        let tomorrow = TokenUsage(model: "claude-sonnet-5", timestamp: now.addingTimeInterval(86_400 * 2), output: 1_000_000)
        #expect(SpendSummary.make(from: [tomorrow], now: now).last30Days == 0)
    }
}

@Suite("Plan limits, more")
struct PlanLimitMoreTests {
    @Test func extraUsageInDollars() throws {
        let json = #"{"limits":[{"kind":"session","percent":10}],"extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":5000,"decimal_places":2,"currency":"USD"}}"#
        let extra = try #require(PlanUsage.parse(Data(json.utf8))?.extra)
        #expect(extra.used == 12.34 && extra.limit == 50 && extra.currency == "USD")
    }

    @Test func unknownLimitsGetReadableTitles() {
        #expect(PlanLimit(kind: "seven_day_cowork", percentUsed: 1, resetsAt: nil).title == "Seven Day Cowork")
    }

    @Test func overTheLimitLeavesNothing() {
        #expect(PlanLimit(kind: "session", percentUsed: 104, resetsAt: nil).percentLeft == 0)
    }
}

@Suite("Copilot usage, more")
struct CopilotUsageMoreTests {
    @Test func unlimitedPremiumRequests() throws {
        let json = #"{"login":"me","copilot_plan":"enterprise","quota_reset_date":"2026-11-01","quota_snapshots":{"premium_interactions":{"unlimited":true,"entitlement":0,"remaining":0}}}"#
        let c = try #require(CopilotUsage.parse(Data(json.utf8), host: "acme.ghe.com"))
        #expect(c.title == "Copilot Enterprise")
        #expect(c.isTracked && c.percentLeft == 100 && c.perDayToLast() == nil)
        #expect(c.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"), "date-only reset is midnight UTC")
    }
}

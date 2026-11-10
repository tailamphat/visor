import Foundation
import Testing
@testable import VisorCore

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@Suite("OpenCode usage")
struct OpenCodeUsageTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func row(_ daysAgo: Double, cost: Double = 0, input: Int = 0, output: Int = 0,
                    reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) -> OpenCodeRow {
        OpenCodeRow(timestamp: now.addingTimeInterval(-daysAgo * 86_400), cost: cost,
                    input: input, output: output, reasoning: reasoning,
                    cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    @Test func totalsByPeriodAndDailyBars() {
        let rows = [
            Self.row(0, input: 1_000, output: 200, cacheRead: 5_000),
            Self.row(0, cost: 0.5, input: 100, output: 50, reasoning: 10, cacheWrite: 20),
            Self.row(3, cost: 1.0, input: 2_000),
            Self.row(10, cost: 2.0),
            Self.row(40, cost: 9.0, input: 9_000),
        ]
        let usage = OpenCodeUsage.make(from: rows, now: Self.now, calendar: Self.calendar)
        #expect(near(usage.today.cost, 0.5))
        #expect(usage.today.tokens == 6_380)
        #expect(usage.today.input == 1_100 && usage.today.output == 250)
        #expect(usage.today.cacheRead == 5_000 && usage.today.cacheWrite == 20 && usage.today.reasoning == 10)
        #expect(near(usage.last7.cost, 1.5))
        #expect(near(usage.last30.cost, 3.5))
        #expect(usage.last30.input == 3_100)
        #expect(usage.daily.count == 14)
        #expect(usage.daily[13] == 6_380)
        #expect(usage.daily[10] == 2_000)
        #expect(usage.daily[3] == 0)
    }

    @Test func futureAndOldDaysAreIgnored() {
        let usage = OpenCodeUsage.make(from: [Self.row(-2, cost: 5), Self.row(40, cost: 5)],
                                       now: Self.now, calendar: Self.calendar)
        #expect(usage.today.cost == 0 && usage.last7.cost == 0 && usage.last30.cost == 0)
        #expect(usage.daily.allSatisfy { $0 == 0 })
    }

    @Test func parsesSQLiteJSON() throws {
        let json = #"[{"stamp":1794213056,"cost":0.25,"input":609,"output":157,"reasoning":450,"cache_read":78464,"cache_write":12}]"#
        let rows = try #require(OpenCodeUsage.parse(Data(json.utf8)))
        #expect(rows.count == 1)
        #expect(rows[0].timestamp == Date(timeIntervalSince1970: 1_794_213_056))
        #expect(near(rows[0].cost, 0.25))
        #expect(rows[0].input == 609 && rows[0].output == 157 && rows[0].reasoning == 450)
        #expect(rows[0].cacheRead == 78_464 && rows[0].cacheWrite == 12)
        #expect(OpenCodeUsage.parse(Data("not json".utf8)) == nil)
    }

    @Test func missingColumnsReadAsZero() throws {
        let rows = try #require(OpenCodeUsage.parse(Data(#"[{"stamp":1794213056}]"#.utf8)))
        #expect(rows[0].cost == 0 && rows[0].input == 0 && rows[0].cacheRead == 0)
    }
}

@Suite("Token counts")
struct TokenCountTests {
    @Test("Compact token counts", arguments: [
        (0, "0"), (999, "999"), (1_000, "1K"), (1_234, "1.2K"), (12_345, "12.3K"),
        (303_314, "303K"), (4_200_000, "4.2M"), (52_100_000, "52.1M"), (1_000_000_000, "1B"),
    ])
    func compact(value: Int, text: String) {
        #expect(TokenCount.compact(value) == text)
    }
}

@Suite("OpenCode Go usage")
struct OpenCodeGoUsageTests {
    static let json = #"{"usage":{"rolling":{"status":"ok","percent":1,"resetsAt":"2026-09-30T17:15:45.084Z"},"weekly":{"status":"ok","percent":25,"resetsAt":"2026-10-05T00:00:00.000Z"},"monthly":{"status":"ok","percent":29,"resetsAt":"2026-10-21T07:45:46.000Z"}}}"#

    @Test func parsesTheThreeWindows() throws {
        let usage = try #require(OpenCodeGoUsage.parse(Data(Self.json.utf8)))
        #expect(usage.limits.map(\.id) == ["rolling", "weekly", "monthly"])
        #expect(usage.limits.map(\.title) == ["Session (5h)", "Weekly", "Monthly"])
        #expect(usage.limits.map(\.percentUsed) == [1, 25, 29])
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-30T17:15:45Z"))
        #expect(abs(usage.limits[0].resetsAt!.timeIntervalSince(expected)) < 0.1)
        #expect(usage.lowest?.id == "monthly")
        #expect(usage.lowest?.percentLeft == 71)
    }

    @Test func percentIsClamped() throws {
        let json = #"{"usage":{"rolling":{"status":"ok","percent":140},"weekly":{"status":"blocked","percent":-5}}}"#
        let usage = try #require(OpenCodeGoUsage.parse(Data(json.utf8)))
        #expect(usage.limits.map(\.percentUsed) == [100, 0])
    }

    @Test func missingPercentSkipsTheWindow() throws {
        let json = #"{"usage":{"rolling":{"status":"ok","resetsAt":"2026-09-30T17:15:45.084Z"},"weekly":{"status":"ok","percent":25}}}"#
        let usage = try #require(OpenCodeGoUsage.parse(Data(json.utf8)))
        #expect(usage.limits.map(\.id) == ["weekly"])
    }

    @Test func unusableResponsesReturnNil() {
        #expect(OpenCodeGoUsage.parse(Data("{}".utf8)) == nil)
        #expect(OpenCodeGoUsage.parse(Data(#"{"usage":{}}"#.utf8)) == nil)
        #expect(OpenCodeGoUsage.parse(Data(#"{"type":"error","error":{"type":"EntitlementError"}}"#.utf8)) == nil)
    }
}

@Suite("OpenCode database query")
struct OpenCodeQueryTests {
    /// Runs the query against a real database built with /usr/bin/sqlite3.
    static func run(_ setup: String, tables: Set<String>) throws -> [OpenCodeRow] {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try sqlite(path, setup)
        let query = try #require(OpenCodeUsage.query(tables: tables, since: Date(timeIntervalSince1970: 0)))
        let data = try sqlite(path, query)
        return try #require(data.isEmpty ? [] : OpenCodeUsage.parse(data))
    }

    static func sqlite(_ path: String, _ sql: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    static let v1 = """
    CREATE TABLE message (id TEXT, time_created INTEGER, data TEXT);
    INSERT INTO message VALUES ('a', 1000000, '{"role":"assistant","cost":0.5,"tokens":{"input":10,"output":2,"cache":{"read":5}}}');
    INSERT INTO message VALUES ('b', 2000000, '{"role":"user"}');
    """
    static let v2Table = "CREATE TABLE session_message (id TEXT, type TEXT, time_created INTEGER, data TEXT);"

    @Test func readsV1Messages() throws {
        let rows = try Self.run(Self.v1, tables: ["message"])
        #expect(rows.map(\.input) == [10])
        #expect(rows[0].cacheRead == 5 && rows[0].cost == 0.5)
    }

    @Test func emptyV2TableFallsBackToV1() throws {
        let rows = try Self.run(Self.v1 + Self.v2Table, tables: ["message", "session_message"])
        #expect(rows.map(\.input) == [10])
    }

    @Test func v2WinsOnceItHasAssistantMessages() throws {
        let setup = Self.v1 + Self.v2Table + """
        INSERT INTO session_message VALUES ('c', 'assistant', 3000000, '{"tokens":{"input":7}}');
        """
        let rows = try Self.run(setup, tables: ["message", "session_message"])
        #expect(rows.map(\.input) == [7])
    }

    @Test func noKnownTableHasNoQuery() {
        #expect(OpenCodeUsage.query(tables: ["other"], since: Date()) == nil)
    }
}

import Foundation
import Testing
@testable import VisorCore

@Suite("Session text")
struct SessionTextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func elapsedClock() {
        #expect(SessionText.elapsed(since: now.addingTimeInterval(-38), now: now) == "0:38")
        #expect(SessionText.elapsed(since: now.addingTimeInterval(-252), now: now) == "4:12")
        #expect(SessionText.elapsed(since: now.addingTimeInterval(-3909), now: now) == "1:05:09")
        #expect(SessionText.elapsed(since: now.addingTimeInterval(5), now: now) == "0:00", "never negative")
    }

    @Test func shortAgo() {
        #expect(SessionText.ago(now.addingTimeInterval(-3), now: now) == "just now")
        #expect(SessionText.ago(now.addingTimeInterval(-12), now: now) == "12s ago")
        #expect(SessionText.ago(now.addingTimeInterval(-250), now: now) == "4m ago")
        #expect(SessionText.ago(now.addingTimeInterval(-7300), now: now) == "2h ago")
        #expect(SessionText.ago(now.addingTimeInterval(-3 * 86400), now: now) == "3d ago")
    }

    /// The office's tooltip says the same time as the list's card.
    @Test func timeAndDetail() {
        var session = AgentSession(id: "s", agent: "Claude Code", cwd: "/Users/me/api", state: .working("Bash: ls"))
        session.since = now.addingTimeInterval(-75)
        #expect(SessionText.time(session, now: now) == "Working 1:15")
        #expect(SessionText.detail(session) == "Bash: ls")
        session.state = .done
        #expect(SessionText.time(session, now: now) == "Finished 1m ago")
        session.state = .working("Thinking")
        session.task = "fix the build"
        #expect(SessionText.detail(session) == "Thinking · fix the build")
    }

    @Test func resets() {
        #expect(SessionText.reset(now.addingTimeInterval(-1), now: now) == "now")
        #expect(SessionText.reset(now.addingTimeInterval(7800), now: now) == "in 2h 10m")
        #expect(SessionText.reset(now.addingTimeInterval(300), now: now) == "in 5m")
    }

    @Test func contextWarning() {
        #expect(SessionText.contextHigh(80) && !SessionText.contextHigh(79.9) && !SessionText.contextHigh(nil))
    }
}

@Suite("ISO dates")
struct ISODateTests {
    /// The fast path reads the tools' timestamps exactly as Foundation does.
    @Test func matchesFoundation() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for text in ["2026-10-31T02:31:01.360Z", "2026-10-31T02:31:01Z", "2024-02-29T23:59:59.999Z", "1999-12-31T00:00:00.5Z",
                     "2026-11-21T07:02:00.000Z", "2026-03-01T12:00:00+07:00", "2026-03-01T12:00:00.25-05:30"] {
            let expected = fractional.date(from: text) ?? plain.date(from: text)
            let parsed = ISODate.parse(text)
            #expect(parsed != nil && abs(parsed!.timeIntervalSince(expected!)) < 0.0005, "\(text)")
            #expect(ISODate.fast(text) != nil, "the fast path reads \(text) itself")
        }
        #expect(ISODate.parse("not a date") == nil && ISODate.parse("2026-13-01T00:00:00Z") == nil)
    }
}

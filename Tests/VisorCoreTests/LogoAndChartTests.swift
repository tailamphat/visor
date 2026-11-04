import CoreGraphics
import Foundation
import Testing
@testable import VisorCore

@Suite("SVG paths")
struct SVGPathTests {
    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.05 }

    @Test func absoluteLines() {
        let box = SVGPath.parse("M0 0L10 0L10 10Z").boundingBoxOfPath
        #expect(box == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test func relativeLinesAndShorthands() {
        let box = SVGPath.parse("m1 1h2v3h-2z").boundingBoxOfPath
        #expect(box == CGRect(x: 1, y: 1, width: 2, height: 3))
    }

    /// Icon paths drop separators: ".5.5" is two numbers, "1-1" is too.
    @Test func compactNumbers() {
        let box = SVGPath.parse("M.5.5l1-1").boundingBoxOfPath
        #expect(close(box.minX, 0.5) && close(box.minY, -0.5) && close(box.width, 1) && close(box.height, 1))
    }

    @Test func arcs() {
        // Clockwise on screen (y down) from (0,0) to (10,0): over the top.
        let box = SVGPath.parse("M0 0A5 5 0 0 1 10 0").boundingBoxOfPath
        #expect(close(box.minX, 0) && close(box.maxX, 10) && close(box.minY, -5) && close(box.maxY, 0))
    }

    /// Arc flags may be written without separators: "0110 0" is flags 0, 1 then x 10.
    @Test func compactArcFlags() {
        let box = SVGPath.parse("M0 0a5 5 0 0110 0").boundingBoxOfPath
        #expect(close(box.minY, -5) && close(box.maxX, 10))
    }

    @Test func curves() {
        let box = SVGPath.parse("M0 0C0 10 10 10 10 0").boundingBoxOfPath
        #expect(close(box.maxY, 7.5) && close(box.maxX, 10))
    }

    @Test("Agent logos fill their 24-unit box", arguments: ["Claude Code", "Copilot CLI"])
    func logos(agent: String) {
        let box = AgentLogo.path(for: agent).boundingBoxOfPath
        #expect(box.minX >= -0.01 && box.minY >= -0.01 && box.maxX <= 24.01 && box.maxY <= 24.01)
        #expect(box.width > 20)
    }
}

@Suite("Spend chart days")
struct DayAxisTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_US_POSIX")
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15))! }

    @Test func everyThirdDayEndingToday() {
        let labels = DayAxis.labels(days: 14, every: 3, today: today, calendar: calendar, locale: locale)
        #expect(labels.map(\.index) == [1, 4, 7, 10, 13])
        #expect(labels.map(\.text) == ["23 Oct", "26 Oct", "29 Oct", "1 Nov", "Today"])
    }

    @Test func eachDayHasAName() {
        #expect(DayAxis.name(13, of: 14, today: today, calendar: calendar, locale: locale) == "Today")
        #expect(DayAxis.name(12, of: 14, today: today, calendar: calendar, locale: locale) == "Yesterday")
        #expect(DayAxis.name(0, of: 14, today: today, calendar: calendar, locale: locale) == "Thu 22 Oct")
    }
}

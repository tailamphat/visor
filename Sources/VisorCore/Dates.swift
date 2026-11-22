import Foundation

/// Dates as the tools write them. Formatters are costly to make, so each is made once and shared
/// (Foundation's formatters are thread-safe).
public enum ISODate {
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    /// "2026-11-21T07:02:00.000Z" or "2026-11-21T07:02:00Z", or with an offset ("+07:00").
    public static func parse(_ string: String) -> Date? {
        fast(string) ?? fractional.date(from: string) ?? plain.date(from: string)
    }

    /// "2026-11-21T07:02:00Z", for log lines.
    public static func string(_ date: Date) -> String { plain.string(from: date) }

    /// Reads the digits directly: transcripts hold tens of thousands of timestamps, and
    /// the formatter took a quarter of a first scan. Nil for anything unusual, which the
    /// formatters then read.
    static func fast(_ string: String) -> Date? {
        var utf8 = string.utf8
        return utf8.withContiguousStorageIfAvailable { b -> Date? in
            func digits(_ at: Int, _ count: Int) -> Int? {
                guard at + count <= b.count else { return nil }
                var value = 0
                for i in at..<(at + count) {
                    let d = Int(b[i]) - 48
                    guard d >= 0 && d <= 9 else { return nil }
                    value = value * 10 + d
                }
                return value
            }
            guard b.count >= 20, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A,
                  let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
                  let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
                  (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
            var i = 19
            var fraction = 0.0
            if b[i] == 0x2E {
                i += 1
                var scale = 0.1
                let start = i
                while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { fraction += Double(b[i] - 0x30) * scale; scale /= 10; i += 1 }
                guard i > start else { return nil }
            }
            guard i < b.count else { return nil }
            var offset = 0
            if b[i] == 0x5A {
                i += 1
            } else if b[i] == 0x2B || b[i] == 0x2D, b.count == i + 6, b[i + 3] == 0x3A,
                      let h = digits(i + 1, 2), let m = digits(i + 4, 2) {
                offset = (h * 3600 + m * 60) * (b[i] == 0x2B ? 1 : -1)
                i += 6
            } else {
                return nil
            }
            guard i == b.count else { return nil }
            // Days since 1970 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
            return Date(timeIntervalSince1970: Double(seconds) + fraction)
        } ?? nil
    }
}

/// Localized date formatters by template, calendar and locale, made once each.
enum DateTemplates {
    private nonisolated(unsafe) static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    /// `localized`: the template is turned into the locale's own order ("EEEEdMMM");
    /// otherwise it is used as written ("EEE d MMM").
    static func formatter(_ template: String, localized: Bool, calendar: Calendar, locale: Locale = .current) -> DateFormatter {
        let key = "\(template)|\(localized)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(locale.identifier)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if localized { formatter.setLocalizedDateFormatFromTemplate(template) } else { formatter.dateFormat = template }
        cache[key] = formatter
        return formatter
    }
}

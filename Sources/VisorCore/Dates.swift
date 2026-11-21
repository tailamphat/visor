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

    /// "2026-11-21T07:02:00.000Z" or "2026-11-21T07:02:00Z".
    public static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
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

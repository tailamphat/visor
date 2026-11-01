import Foundation

/// One usage limit of a Claude subscription, such as the 5-hour session or the weekly cap.
public struct PlanLimit: Equatable, Sendable, Identifiable {
    public var id: String { kind }
    public var kind: String
    /// Percent used, 0...100.
    public var percentUsed: Double
    public var resetsAt: Date?
    /// "normal", "warning", ... as reported by the server.
    public var severity: String

    public init(kind: String, percentUsed: Double, resetsAt: Date?, severity: String = "normal") {
        self.kind = kind
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.severity = severity
    }

    public var percentLeft: Double { max(0, 100 - percentUsed) }

    public var title: String {
        switch kind {
        case "session", "five_hour": return "Session (5h)"
        case "weekly_all", "seven_day": return "Weekly"
        case "seven_day_opus", "weekly_opus": return "Weekly Opus"
        case "seven_day_sonnet", "weekly_sonnet": return "Weekly Sonnet"
        default:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Paid usage beyond the plan ("extra usage"), when turned on.
public struct ExtraUsage: Equatable, Sendable {
    public var used: Double
    public var limit: Double?
    public var currency: String
}

/// What /api/oauth/usage reports for the signed-in Claude account.
public struct PlanUsage: Equatable, Sendable {
    public var limits: [PlanLimit]
    public var extra: ExtraUsage?

    public init(limits: [PlanLimit], extra: ExtraUsage? = nil) {
        self.limits = limits
        self.extra = extra
    }

    /// The 5-hour session limit, the one that runs out first in practice.
    public var session: PlanLimit? { limits.first { $0.kind == "session" || $0.kind == "five_hour" } }

    public static func parse(_ data: Data) -> PlanUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var limits: [PlanLimit] = []
        if let list = object["limits"] as? [[String: Any]] {
            for item in list {
                guard let kind = item["kind"] as? String,
                      let percent = (item["percent"] as? NSNumber)?.doubleValue else { continue }
                limits.append(PlanLimit(kind: kind, percentUsed: percent,
                                        resetsAt: (item["resets_at"] as? String).flatMap(TranscriptUsage.date),
                                        severity: item["severity"] as? String ?? "normal"))
            }
        }
        if limits.isEmpty {
            // Older response shape: one object per window.
            for kind in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"] {
                guard let item = object[kind] as? [String: Any],
                      let percent = (item["utilization"] as? NSNumber)?.doubleValue else { continue }
                limits.append(PlanLimit(kind: kind, percentUsed: percent,
                                        resetsAt: (item["resets_at"] as? String).flatMap(TranscriptUsage.date)))
            }
        }
        var extra: ExtraUsage?
        if let item = object["extra_usage"] as? [String: Any], item["is_enabled"] as? Bool == true {
            let places = (item["decimal_places"] as? NSNumber)?.intValue ?? 2
            let scale = pow(10, Double(places))
            let used = ((item["used_credits"] as? NSNumber)?.doubleValue ?? 0) / scale
            let limit = (item["monthly_limit"] as? NSNumber).map { $0.doubleValue / scale }
            extra = ExtraUsage(used: used, limit: limit, currency: item["currency"] as? String ?? "USD")
        }
        guard !limits.isEmpty || extra != nil else { return nil }
        return PlanUsage(limits: limits, extra: extra)
    }
}

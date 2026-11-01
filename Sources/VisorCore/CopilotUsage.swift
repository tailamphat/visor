import Foundation

/// A GitHub Copilot account's monthly allowance, as Copilot's own apps read it
/// from `<api>/copilot_internal/user`.
public struct CopilotUsage: Equatable, Sendable {
    public var login: String
    /// "business", "enterprise", "individual", ...
    public var plan: String
    /// The host the account lives on: github.com or yourcompany.ghe.com.
    public var host: String
    public var premiumEntitlement: Int
    public var premiumRemaining: Int
    public var premiumUnlimited: Bool
    public var overagePermitted: Bool
    public var overageUsed: Int
    public var chatUnlimited: Bool
    public var completionsUnlimited: Bool
    public var resetsAt: Date?

    public var premiumUsed: Int { max(0, premiumEntitlement - premiumRemaining) }
    public var percentLeft: Double {
        premiumEntitlement > 0 ? Double(premiumRemaining) / Double(premiumEntitlement) * 100 : 100
    }

    /// "Copilot Business"
    public var title: String { "Copilot " + plan.prefix(1).uppercased() + plan.dropFirst() }

    /// Worth showing: a plan with premium requests to count (not Copilot Free's zero).
    public var isTracked: Bool { premiumUnlimited || premiumEntitlement > 0 }

    /// Requests per day that would last until the reset; nil when the reset is
    /// a day or less away (the figure would just repeat what's left).
    public func perDayToLast(now: Date = Date()) -> Int? {
        guard let resetsAt, !premiumUnlimited else { return nil }
        let days = Int(ceil(resetsAt.timeIntervalSince(now) / 86_400))
        return days >= 2 ? premiumRemaining / days : nil
    }

    public static func parse(_ data: Data, host: String) -> CopilotUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = object["login"] as? String,
              let quotas = object["quota_snapshots"] as? [String: Any] else { return nil }
        func quota(_ key: String) -> [String: Any] { quotas[key] as? [String: Any] ?? [:] }
        func int(_ q: [String: Any], _ key: String) -> Int { (q[key] as? NSNumber)?.intValue ?? 0 }
        let premium = quota("premium_interactions")
        let reset = (object["quota_reset_date_utc"] as? String).flatMap(TranscriptUsage.date)
            ?? (object["quota_reset_date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0 + "T00:00:00Z") }
        return CopilotUsage(login: login,
                            plan: object["copilot_plan"] as? String ?? "copilot",
                            host: host,
                            premiumEntitlement: int(premium, "entitlement"),
                            premiumRemaining: int(premium, "remaining"),
                            premiumUnlimited: premium["unlimited"] as? Bool ?? false,
                            overagePermitted: premium["overage_permitted"] as? Bool ?? false,
                            overageUsed: int(premium, "overage_count"),
                            chatUnlimited: quota("chat")["unlimited"] as? Bool ?? false,
                            completionsUnlimited: quota("completions")["unlimited"] as? Bool ?? false,
                            resetsAt: reset)
    }

    /// The REST API root for a host: api.github.com, or api.<company>.ghe.com.
    public static func apiBase(for host: String) -> URL? {
        let host = host.lowercased()
        if host == "github.com" { return URL(string: "https://api.github.com") }
        if host.hasSuffix(".ghe.com") { return URL(string: "https://api.\(host)") }
        return nil
    }

    /// Hosts and accounts from `gh auth status` ("Logged in to acme.ghe.com account octocat (keyring)").
    public static func signedInHosts(fromStatus text: String) -> [String] {
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "Logged in to ") else { continue }
            let rest = line[range.upperBound...]
            guard let host = rest.split(separator: " ").first.map(String.init), !hosts.contains(host) else { continue }
            hosts.append(host)
        }
        return hosts
    }
}

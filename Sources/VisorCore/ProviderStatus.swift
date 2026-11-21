import Foundation

/// An incident on a provider's status page that touches a tool you use.
public struct ProviderIncident: Equatable, Sendable {
    public enum Severity: Equatable, Sendable { case minor, major }
    /// The incident's id, or the component and its state when none is written yet:
    /// what "once per incident" is counted by.
    public var id: String
    public var title: String
    public var severity: Severity
    public var since: Date?
    public var link: String

    public init(id: String, title: String, severity: Severity, since: Date?, link: String) {
        self.id = id
        self.title = title
        self.severity = severity
        self.since = since
        self.link = link
    }
}

/// Reads a provider's public status page (the common Statuspage format:
/// /api/v2/summary.json) for incidents on the parts a tool depends on.
public struct ProviderStatus: Sendable {
    public var agent: String
    public var url: URL
    /// The page's components that matter: an exact name, or a prefix ending in "*".
    public var components: [String]

    public static let claude = ProviderStatus(agent: "Claude Code", url: URL(string: "https://status.claude.com/api/v2/summary.json")!,
                                              components: ["Claude Code", "Claude API*"])
    public static let copilot = ProviderStatus(agent: "Copilot CLI", url: URL(string: "https://www.githubstatus.com/api/v2/summary.json")!,
                                               components: ["Copilot"])

    static func matches(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { $0.hasSuffix("*") ? name.hasPrefix(String($0.dropLast())) : name == $0 }
    }

    /// The incident that matters, from a summary page: an open incident on a
    /// watched component first; else a watched component that's degraded or
    /// down without one; nil when all is well (planned maintenance included).
    public static func incident(in data: Data, watching patterns: [String]) throws -> ProviderIncident? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let pageURL = (object["page"] as? [String: Any])?["url"] as? String ?? ""
        for incident in object["incidents"] as? [[String: Any]] ?? [] {
            guard incident["status"] as? String != "resolved", incident["status"] as? String != "postmortem" else { continue }
            let touched = (incident["components"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            guard touched.contains(where: { matches($0, patterns) }) else { continue }
            let impact = incident["impact"] as? String ?? "minor"
            return ProviderIncident(id: incident["id"] as? String ?? (incident["name"] as? String ?? ""),
                                    title: incident["name"] as? String ?? "Incident",
                                    severity: impact == "major" || impact == "critical" ? .major : .minor,
                                    since: (incident["created_at"] as? String).flatMap(ISODate.parse),
                                    link: incident["shortlink"] as? String ?? pageURL)
        }
        let words = ["degraded_performance": "degraded performance", "partial_outage": "partial outage", "major_outage": "major outage"]
        for component in object["components"] as? [[String: Any]] ?? [] {
            guard let name = component["name"] as? String, matches(name, patterns),
                  let status = component["status"] as? String, let word = words[status] else { continue }
            let short = name.components(separatedBy: " (").first ?? name
            return ProviderIncident(id: name + "|" + status, title: "\(short): \(word)",
                                    severity: status == "degraded_performance" ? .minor : .major,
                                    since: (component["updated_at"] as? String).flatMap(ISODate.parse), link: pageURL)
        }
        return nil
    }
}

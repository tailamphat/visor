import Foundation

/// One limit reported by Google Antigravity's `/usage` command.
public struct AntigravityLimit: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Percent used, 0...100. Antigravity reports what's left.
    public var percentUsed: Double
    public var resetsAt: Date?

    public init(id: String, title: String, percentUsed: Double, resetsAt: Date?) {
        self.id = id
        self.title = title
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
    }

    public var percentLeft: Double { max(0, 100 - percentUsed) }
}

/// What `agy -p /usage --output-format json` reports.
public struct AntigravityUsage: Equatable, Sendable {
    public var limits: [AntigravityLimit]

    public init(limits: [AntigravityLimit]) {
        self.limits = limits
    }

    public static func parse(_ data: Data) -> AntigravityUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]] else { return nil }

        var limits: [AntigravityLimit] = []
        for group in groups {
            guard let groupName = group["name"] as? String,
                  let buckets = group["buckets"] as? [[String: Any]] else { continue }
            let groupTitle = groupName
                .strippingSuffix(" Models")
                .strippingSuffix(" models")
                .replacingOccurrences(of: " and ", with: " + ")
            for bucket in buckets {
                guard let id = bucket["id"] as? String,
                      let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue else { continue }
                let percentUsed = min(100, max(0, (1 - remaining) * 100))
                let window = bucket["window"] as? String ?? ""
                let suffix = window.isEmpty ? (bucket["name"] as? String ?? "") : window
                let title = suffix.isEmpty ? groupTitle : groupTitle + " " + suffix
                limits.append(AntigravityLimit(id: id, title: title, percentUsed: percentUsed,
                                               resetsAt: (bucket["reset_time"] as? String).flatMap(TranscriptUsage.date)))
            }
        }
        return limits.isEmpty ? nil : AntigravityUsage(limits: limits)
    }
}

private extension String {
    func strippingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

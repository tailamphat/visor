import Foundation

/// Claude Code's `permission_mode` hook field. Untrusted text: only ever mapped
/// to this enum, never interpreted further and never used for any decision.
public enum PermissionMode: String, Codable, Sendable, Equatable {
    case standard, bypass, acceptEdits, plan, unknown

    /// nil (the field is absent or not text) means "no information".
    public init?(field: Any?) {
        guard let text = field as? String else { return nil }
        switch text {
        case "default": self = .standard
        case "bypassPermissions": self = .bypass
        case "acceptEdits": self = .acceptEdits
        case "plan": self = .plan
        default: self = .unknown
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PermissionMode(rawValue: raw) ?? .unknown
    }

    /// The pill's text; nil for the default and unknown modes.
    public var label: String? {
        switch self {
        case .bypass: return "no asks"
        case .acceptEdits: return "auto-edit"
        case .plan: return "plan"
        case .standard, .unknown: return nil
        }
    }

    /// The one peek: when a session is in bypass and has not peeked yet.
    public static func shouldPeek(mode: PermissionMode?, alreadyPeeked: Bool) -> Bool {
        mode == .bypass && !alreadyPeeked
    }
}

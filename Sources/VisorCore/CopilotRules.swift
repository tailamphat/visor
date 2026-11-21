import Foundation

/// Copilot CLI "always allow" rules. Copilot's hooks can't save rules, so
/// Visor keeps them, per project, like Claude Code's own rules.
public struct CopilotRules: Codable, Equatable, Sendable {
    public struct Rule: Codable, Equatable, Sendable {
        public var project: String
        /// "command", "edits", "web", or another tool's name.
        public var kind: String
        /// The command's first word, the site, or "*" for any.
        public var match: String

        public init(for request: ApprovalRequest) {
            project = request.cwd
            switch request.tool {
            case "Bash":
                kind = "command"
                match = Self.commandName(request.preview)
            case "Edit", "Write", "MultiEdit":
                kind = "edits"
                match = "*"
            case "WebFetch":
                kind = "web"
                match = URL(string: request.preview)?.host ?? "*"
            default:
                kind = request.tool
                match = "*"
            }
        }

        /// The command's first word, after any leading `NAME=value` assignments.
        static func commandName(_ command: String) -> String {
            let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
            let isAssignment = { (word: String) in
                guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
                return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }
            return words.first { !isAssignment($0) } ?? words.first ?? "*"
        }

        /// One plain command: no chaining, pipes, background jobs, subshells,
        /// redirection or second line, so its first word says what it runs.
        public static func isSimple(_ command: String) -> Bool {
            !command.contains { ";&|`<>\n\r".contains($0) } && !command.contains("$(")
        }

        /// What the "Always" button names: "npm", "edits", "docs.github.com".
        public var label: String {
            switch kind {
            case "edits": return "edits"
            default: return match == "*" ? kind : match
            }
        }
    }

    public var rules: [Rule] = []

    public init() {}

    public mutating func add(for request: ApprovalRequest) {
        let rule = Rule(for: request)
        if !rules.contains(rule) { rules.append(rule) }
    }

    public func allows(_ request: ApprovalRequest) -> Bool {
        let wanted = Rule(for: request)
        // A rule names one command; anything chained to it must still ask.
        if wanted.kind == "command" && !Rule.isSimple(request.preview) { return false }
        return rules.contains { $0.project == wanted.project && $0.kind == wanted.kind && ($0.match == "*" || $0.match == wanted.match) }
    }
}

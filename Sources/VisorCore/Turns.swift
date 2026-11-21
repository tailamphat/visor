import Foundation

/// What an agent did in one turn, tallied from its tool events: the files it
/// changed and by how many lines, how many commands it ran, and its latest test
/// run. Shown as the turn summary when the turn finishes.
public struct TurnStats: Equatable, Sendable, Codable {
    public enum Tests: Equatable, Sendable, Codable {
        case ran(String), passed(String), failed(String)
    }

    /// Changed files, full paths, in the order first touched.
    public private(set) var files: [String] = []
    public private(set) var added = 0
    public private(set) var removed = 0
    public private(set) var commands = 0
    public private(set) var tests: Tests?

    public init() {}

    public var isEmpty: Bool { files.isEmpty && commands == 0 }

    /// Counts one tool event: edits before they run, commands too; a test's
    /// outcome after it ran (or failed to).
    public mutating func record(_ message: HookMessage) {
        let name = (message.toolName ?? "").lowercased()
        let input = message.toolInput
        switch message.event {
        case "PreToolUse":
            if ["bash", "shell", "run_command"].contains(name), let command = input["command"] as? String {
                commands += 1
                if Self.isTest(command) { tests = .ran(command) }
                return
            }
            guard let path = (input["file_path"] ?? input["path"]) as? String else { return }
            switch name {
            case "edit", "str_replace_editor", "replace":
                count(path, old: input["old_string"] as? String, new: input["new_string"] as? String)
            case "multiedit":
                note(path)
                for edit in input["edits"] as? [[String: Any]] ?? [] {
                    count(path, old: edit["old_string"] as? String, new: edit["new_string"] as? String)
                }
            case "write", "create", "write_file":
                count(path, old: nil, new: (input["content"] ?? input["file_text"]) as? String)
            default: break
            }
        case "PostToolUse", "PostToolUseFailure":
            guard ["bash", "shell", "run_command"].contains(name), let command = input["command"] as? String, Self.isTest(command) else { return }
            if message.event == "PostToolUseFailure" { tests = .failed(command); return }
            let response = message.payload["tool_response"] as? [String: Any] ?? [:]
            let output = [response["stdout"], response["stderr"], response["output"]].compactMap { $0 as? String }.joined(separator: "\n")
            tests = Self.outcome(of: output).map { $0 ? .passed(command) : .failed(command) } ?? .ran(command)
        default: break
        }
    }

    private mutating func note(_ path: String) {
        if !files.contains(path) { files.append(path) }
    }

    private mutating func count(_ path: String, old: String?, new: String?) {
        note(path)
        removed += Self.lines(old)
        added += Self.lines(new)
    }

    static func lines(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        return text.hasSuffix("\n") ? parts.count - 1 : parts.count
    }

    /// Whether a shell command runs tests: the usual test runners and scripts.
    public static func isTest(_ command: String) -> Bool {
        let patterns = [
            #"(^|[\s;&|])(npm|pnpm|yarn|bun)( run)? test\b"#, #"\bpytest\b"#, #"\bgo test\b"#, #"\bcargo test\b"#,
            #"\bswift test\b"#, #"\bmake test\b"#, #"\b(rspec|jest|vitest|mocha|phpunit)\b"#, #"(^|[\s/])test\.sh\b"#,
            #"\bxcodebuild\b.*\btest\b"#, #"\bgradlew? test\b"#, #"\bmvn test\b"#, #"\bdotnet test\b"#,
        ]
        return patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }

    /// Passed (true) or failed (false), from a test run's output; nil when it doesn't say.
    static func outcome(of output: String) -> Bool? {
        let text = output.lowercased()
        let failed = [#"\b[1-9]\d* (failed|failing|failures?|errors?)\b"#, #"tests? failed"#, #"(?m)^fail\b"#, #"\bfailed after\b"#]
        if output.contains("✘") || failed.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
            return false
        }
        if output.contains("✔") || text.range(of: #"(?m)\b\d+ passed\b|\ball tests passed\b|^ok\b|\btests? passed\b"#,
                                                options: .regularExpression) != nil {
            return true
        }
        return nil
    }

    /// The first `limit` files, relative to the project where they're inside it,
    /// and how many more there are.
    public func shortFiles(in cwd: String, limit: Int) -> ([String], Int) {
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        let short = files.prefix(limit).map { $0.hasPrefix(base) ? String($0.dropFirst(base.count)) : ($0 as NSString).lastPathComponent }
        return (short, max(0, files.count - limit))
    }
}

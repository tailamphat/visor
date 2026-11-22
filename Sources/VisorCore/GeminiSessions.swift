import CryptoKit
import Foundation

/// One Gemini CLI chat (`~/.gemini/tmp/<project>/chats/session-*.json` or
/// `.jsonl`), read-only, as a session for the Agents tab. A `.json` chat is a
/// `ConversationRecord` (`sessionId`, `lastUpdated`, `kind`, `messages`)
/// rewritten whole on each change; a `.jsonl` chat only grows, one record a
/// line, and a later record with the same message `id` replaces the earlier one.
/// Field names follow Gemini CLI's public docs and source: unverified live.
public struct GeminiChat: Sendable {
    /// Bytes of a `.jsonl` chat consumed so far (complete lines only).
    public private(set) var offset: UInt64 = 0
    private let fileID: String
    private var id: String?
    private var subagent = false
    private var lastUpdated: Date?
    private var order: [String] = []
    private var messages: [String: Message] = [:]
    private var unnamed = 0

    /// What a message says, kept small: the user's prompt, the end of an
    /// answer, and each tool call already described.
    private struct Message: Sendable {
        var type: String
        var time: Date?
        var text: String
        var calls: [(status: String, activity: String)]
    }

    /// `id`: the file name, used until the chat names its session.
    public init(id: String) {
        fileID = id
    }

    /// A whole `.json` chat; replaces anything read before.
    public mutating func read(json data: Data) {
        self = GeminiChat(id: fileID)
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        takeMeta(record)
        for message in record["messages"] as? [[String: Any]] ?? [] { take(message) }
    }

    /// The complete lines of `data`, which starts at `offset`; a half-written last line waits.
    public mutating func read(lines data: Data) {
        let end = data.last == 0x0A ? data.endIndex : (data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex)
        offset += UInt64(end - data.startIndex)
        TokenLedger.forEachLine(data[data.startIndex..<end]) { record in
            if let set = record["$set"] as? [String: Any] { takeMeta(set) }
            if Self.types.contains(record["type"] as? String ?? "") { take(record) } else { takeMeta(record) }
        }
    }

    private static let types: Set<String> = ["user", "gemini", "info", "error", "warning"]

    private mutating func takeMeta(_ record: [String: Any]) {
        if let value = record["sessionId"] as? String, !value.isEmpty { id = value }
        if let kind = record["kind"] as? String { subagent = kind == "subagent" }
        if let stamp = (record["lastUpdated"] as? String).flatMap(ISODate.parse) { lastUpdated = max(lastUpdated ?? stamp, stamp) }
    }

    private mutating func take(_ object: [String: Any]) {
        guard let type = object["type"] as? String, Self.types.contains(type) else { return }
        var key = object["id"] as? String ?? ""
        if key.isEmpty {
            unnamed += 1
            key = "#\(unnamed)"
        }
        let calls = (object["toolCalls"] as? [[String: Any]] ?? []).map { call in
            (status: call["status"] as? String ?? "",
             activity: Self.describe(name: call["name"] as? String ?? "tool", args: call["args"] as? [String: Any] ?? [:],
                                     displayName: call["displayName"] as? String))
        }
        let text = Self.text(object["content"])
        let message = Message(type: type, time: (object["timestamp"] as? String).flatMap(ISODate.parse),
                              text: type == "user" ? text : String(text.suffix(200)), calls: calls)
        if messages[key] == nil { order.append(key) }
        messages[key] = message
    }

    /// A message's text: a string, or parts with `text`.
    private static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        if let part = content as? [String: Any] { return part["text"] as? String ?? "" }
        return ""
    }

    /// The session, or nil for a helper's chat or one with no messages.
    /// `fallback` dates a chat that carries no times (its file's modification date).
    public func session(cwd: String, fallback: Date) -> ScannedSession? {
        guard !subagent, !order.isEmpty else { return nil }
        let all = order.compactMap { messages[$0] }
        let prompt = all.last { $0.type == "user" }
        let newest = all.compactMap(\.time).max()
        let last = [lastUpdated, newest].compactMap { $0 }.max() ?? fallback
        var asked = false
        let state: AgentState
        // The newest message that says something about the turn; other notices don't.
        let deciding = all.last { message in
            message.type != "warning" && (message.type != "info" || Self.cancelled(message))
        }
        switch deciding?.type {
        case "user":
            state = .working("Thinking")
        case "gemini":
            let calls = deciding?.calls ?? []
            if let waiting = calls.first(where: { $0.status == "awaiting_approval" }) {
                state = .asking(waiting.activity)
            } else if let running = calls.first(where: { ["executing", "scheduled", "validating"].contains($0.status) }) {
                state = .working(running.activity)
            } else if !calls.isEmpty, calls.allSatisfy({ $0.status == "cancelled" }) {
                state = .idle
            } else if !calls.isEmpty {
                // Calls finished and nothing newer: the model is reading their results.
                state = .working("Thinking")
            } else {
                asked = AgentBoard.asksForReply(deciding?.text ?? "")
                state = .done
            }
        case "info", "error":
            state = .idle
        default:
            state = .idle
        }
        return ScannedSession(id: id ?? fileID, agent: "Gemini CLI", cwd: cwd, state: state,
                              task: prompt.flatMap { AgentBoard.summarize($0.text) }, turnStart: prompt?.time,
                              lastActivity: last, askedForReply: asked)
    }

    private static func cancelled(_ message: Message) -> Bool {
        message.text.lowercased().hasPrefix("request cancelled")
    }

    /// A Gemini CLI tool call in the words the other agents use: "Bash: npm test", "Edit: cart.ts".
    public static func describe(name: String, args: [String: Any], displayName: String?) -> String {
        func string(_ keys: String...) -> String? {
            for key in keys { if let value = args[key] as? String, !value.isEmpty { return value } }
            return nil
        }
        switch name {
        case "run_shell_command":
            return AgentBoard.describe(tool: "Bash", input: string("command").map { ["command": $0] } ?? [:])
        case "read_file":
            return AgentBoard.describe(tool: "Read", input: string("absolute_path", "file_path", "path").map { ["file_path": $0] } ?? [:])
        case "read_many_files":
            return "Read"
        case "write_file":
            return AgentBoard.describe(tool: "Write", input: string("file_path", "absolute_path").map { ["file_path": $0] } ?? [:])
        case "replace", "edit":
            return AgentBoard.describe(tool: "Edit", input: string("file_path", "absolute_path").map { ["file_path": $0] } ?? [:])
        case "glob":
            return AgentBoard.describe(tool: "Glob", input: string("pattern").map { ["pattern": $0] } ?? [:])
        case "search_file_content", "grep", "grep_search":
            return AgentBoard.describe(tool: "Grep", input: string("pattern").map { ["pattern": $0] } ?? [:])
        case "google_web_search":
            return AgentBoard.describe(tool: "WebSearch", input: string("query").map { ["query": $0] } ?? [:])
        case "web_fetch":
            // The fetch is asked in words; the first link in them names the site.
            let url = string("url") ?? string("prompt")?.split(whereSeparator: \.isWhitespace)
                .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }.map(String.init)
            return AgentBoard.describe(tool: "WebFetch", input: url.map { ["url": $0] } ?? [:])
        default:
            return displayName.flatMap { $0.isEmpty ? nil : $0 } ?? name
        }
    }

    /// The project a chat folder (`tmp/<id>`) belongs to: the path in its
    /// `.project_root`, else the live Gemini folder whose SHA-256 is the
    /// folder's name; "" when unknown (the card then reads "Gemini CLI").
    public static func project(folder: String, projectRoot: String?, liveCwds: [String]) -> String {
        if let root = projectRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty { return root }
        guard folder.count == 64 else { return "" }
        return liveCwds.first { cwd in
            SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined() == folder.lowercased()
        } ?? ""
    }

    /// Whether `path`, relative to the Gemini home, is a Gemini CLI chat:
    /// `tmp/<id>/chats/session-*.json(l)`. Antigravity's `antigravity-cli/`
    /// and `config/` never are.
    public static func isChatFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == "tmp", parts[2] == "chats", parts[3].hasPrefix("session-") else { return false }
        return parts[3].hasSuffix(".json") || parts[3].hasSuffix(".jsonl")
    }

    /// The script a `node` command line runs: the first argument after
    /// argv[0] that isn't one of node's options (`node --no-warnings=DEP0040
    /// /opt/homebrew/bin/gemini`, or Gemini's relaunch with `--max-old-space-size`).
    public static func script(nodeArguments args: [String]) -> String? {
        var rest = args.dropFirst()
        while let arg = rest.first {
            rest = rest.dropFirst()
            if arg == "--" { return rest.first }
            guard arg.hasPrefix("-") else { return arg }
            // Options whose value is the next argument.
            if ["-r", "--require", "--import", "--loader", "--experimental-loader"].contains(arg) { rest = rest.dropFirst() }
        }
        return nil
    }

    /// Whether a process is Gemini CLI: a `gemini` binary, or Node running a
    /// script named `gemini` or inside `@google/gemini-cli`. Antigravity
    /// (`agy`, `~/.gemini/antigravity-cli`) never matches.
    public static func isGeminiCommand(name: String, script: String?) -> Bool {
        if name == "gemini" { return true }
        guard name == "node", let script, !script.contains("/antigravity-cli/") else { return false }
        return (script as NSString).lastPathComponent == "gemini" || script.contains("/@google/gemini-cli/")
    }
}

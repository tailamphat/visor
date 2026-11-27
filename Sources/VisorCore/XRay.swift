import Foundation

/// One CLAUDE.md or memory file the harness sent before the first prompt.
/// Only its path and size are kept, never its text.
public struct XRayFile: Equatable, Codable, Sendable {
    public var path: String
    public var tokens: Int
}

/// What one MCP server's tools and instructions add before the first prompt.
public struct XRayServer: Equatable, Codable, Sendable {
    public var name: String
    public var tokens: Int
    /// Tools the transcript lists for it (deferred names count, too).
    public var tools: Int
}

/// One line of the X-ray, ready to show: the total is exact, every part "about".
public struct XRayRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case total, systemAndTools, mcp, instructions, skills, prompt }
    public var kind: Kind
    public var title: String
    public var tokens: Int
    /// An estimate (bytes / 4), shown with "about".
    public var about: Bool
}

/// How much context a Claude Code session (or one of its helpers) used before
/// its first prompt: the exact total from the first reply's input and cache
/// tokens, and an estimated split from the transcript's attachments.
public struct HarnessXRay: Equatable, Codable, Sendable {
    /// Exact: the first reply's input + cache write + cache read tokens.
    public var total: Int
    public var model: String
    /// About: the first prompt itself, which the total includes.
    public var prompt: Int
    public var skills: Int
    public var instructions: [XRayFile]
    /// Largest first.
    public var mcp: [XRayServer]
    /// About: what is left, the system prompt and built-in tools.
    public var systemAndTools: Int

    public var instructionTokens: Int { instructions.reduce(0) { $0 + $1.tokens } }
    public var mcpTokens: Int { mcp.reduce(0) { $0 + $1.tokens } }

    /// The total first, then the non-zero parts, largest kinds in a fixed order.
    public var rows: [XRayRow] {
        var rows = [XRayRow(kind: .total, title: "Harness", tokens: total, about: false),
                    XRayRow(kind: .systemAndTools, title: "System + tools", tokens: systemAndTools, about: true)]
        rows += mcp.map { XRayRow(kind: .mcp, title: "MCP: \($0.name)", tokens: $0.tokens, about: true) }
        rows.append(XRayRow(kind: .instructions, title: "CLAUDE.md + memory", tokens: instructionTokens, about: true))
        rows.append(XRayRow(kind: .skills, title: "Skills", tokens: skills, about: true))
        rows.append(XRayRow(kind: .prompt, title: "First prompt", tokens: prompt, about: true))
        return rows.filter { $0.kind == .total || $0.tokens > 0 }
    }

    /// The usual estimate for text sent to the model: four bytes a token.
    public static func estimate(bytes: Int) -> Int { (bytes + 3) / 4 }
}

/// Builds a `HarnessXRay` from a transcript's complete JSONL lines, fed in
/// order as they are read. Once the first reply is seen it is done and
/// ignores everything after. Works the same on a helper's `agent-*.jsonl`.
public struct XRayScanner: Sendable {
    private struct Tool: Sendable { var server: String; var line = 0; var definition = 0 }

    public private(set) var result: HarnessXRay?
    /// Found, or given up after replies without usage (offline, bad key).
    public var isDone: Bool { result != nil || emptyReplies >= Self.maxEmptyReplies }
    /// Error stand-ins ("<synthetic>") seen before a real reply.
    private var emptyReplies = 0
    static let maxEmptyReplies = 3
    /// Lines handed to the JSON parser, for tests.
    public private(set) var linesParsed = 0

    private var tools: [String: Tool] = [:]
    /// Instruction blocks by server name as listed.
    private var blocks: [String: Int] = [:]
    private var skills = 0
    private var files: [XRayFile] = []
    private var prompt = 0

    public init() {}

    private static let markers = [#""type":"attachment""#, #""type":"assistant""#, #""type":"user""#].map { Array($0.utf8) }

    /// Feeds complete lines; does nothing once done.
    public mutating func ingest(_ data: Data) {
        guard !isDone else { return }
        let lines: [Range<Int>] = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>] in
            guard let base = raw.baseAddress else { return [] }
            var found: [Range<Int>] = []
            var start = 0
            while start < raw.count {
                var end = raw.count
                if let newline = memchr(base + start, 0x0A, raw.count - start) {
                    end = UnsafeRawPointer(newline) - base
                }
                if Self.markers.contains(where: { memmem(base + start, end - start, $0, $0.count) != nil }) {
                    found.append(start..<end)
                }
                start = end + 1
            }
            return found
        }
        for range in lines {
            let line = data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
            linesParsed += 1
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "attachment": (object["attachment"] as? [String: Any]).map { add(attachment: $0) }
            case "user": addPrompt(object)
            case "assistant": finish(object)
            default: break
            }
            if isDone { return }
        }
    }

    private static func bytes(_ string: String?) -> Int { string?.utf8.count ?? 0 }

    private static func bytes(json value: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return 0 }
        return data.count
    }

    /// `mcp__<server>__<tool>`: the server, or nil for a built-in tool.
    static func server(ofTool name: String) -> String? {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// Instruction blocks are listed by display name, tools by id: match them loosely.
    static func key(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }

    private mutating func add(attachment: [String: Any]) {
        switch attachment["type"] as? String {
        case "deferred_tools_delta":
            let names = attachment["addedNames"] as? [String] ?? []
            let lines = attachment["addedLines"] as? [String] ?? []
            for (index, name) in names.enumerated() {
                guard let server = Self.server(ofTool: name) else { continue }
                var tool = tools[name] ?? Tool(server: server)
                tool.line = Self.bytes(index < lines.count ? lines[index] : name)
                tools[name] = tool
            }
            for definition in attachment["surfacedDefinitions"] as? [[String: Any]] ?? [] {
                guard let name = definition["name"] as? String, let server = Self.server(ofTool: name) else { continue }
                var tool = tools[name] ?? Tool(server: server)
                tool.definition = Self.bytes(json: definition["definition"] ?? definition)
                tools[name] = tool
            }
            for name in attachment["removedNames"] as? [String] ?? [] { tools[name] = nil }
        case "mcp_instructions_delta":
            let names = attachment["addedNames"] as? [String] ?? []
            let texts = attachment["addedBlocks"] as? [String] ?? []
            for (index, name) in names.enumerated() where index < texts.count {
                blocks[name] = Self.bytes(texts[index])
            }
            for name in attachment["removedNames"] as? [String] ?? [] { blocks[name] = nil }
        case "skill_listing":
            skills += Self.bytes(attachment["content"] as? String)
        case "instructions":
            var listed = attachment["files"] as? [[String: Any]] ?? []
            if listed.isEmpty, attachment["path"] != nil { listed = [attachment] }
            for file in listed {
                guard let path = file["path"] as? String else { continue }
                let tokens = HarnessXRay.estimate(bytes: Self.bytes(file["content"] as? String))
                if let index = files.firstIndex(where: { $0.path == path }) {
                    files[index].tokens = tokens
                } else {
                    files.append(XRayFile(path: path, tokens: tokens))
                }
            }
        default:
            break
        }
    }

    private mutating func addPrompt(_ object: [String: Any]) {
        guard object["isMeta"] as? Bool != true, let message = object["message"] as? [String: Any] else { return }
        if let text = message["content"] as? String {
            prompt += Self.bytes(text)
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "text" { prompt += Self.bytes(block["text"] as? String) }
        }
    }

    private mutating func finish(_ object: [String: Any]) {
        guard let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        var write = usage.int("cache_creation_input_tokens")
        if write == 0, let split = usage["cache_creation"] as? [String: Any] {
            write = split.int("ephemeral_5m_input_tokens") + split.int("ephemeral_1h_input_tokens")
        }
        let total = usage.int("input_tokens") + write + usage.int("cache_read_input_tokens")
        // An error stand-in ("<synthetic>") carries no real usage: wait a little for a real reply.
        guard total > 0 else {
            emptyReplies += 1
            return
        }
        result = build(total: total, model: message["model"] as? String ?? "")
    }

    private func build(total: Int, model: String) -> HarnessXRay {
        var servers: [String: XRayServer] = [:]
        for (_, tool) in tools {
            let key = Self.key(tool.server)
            var server = servers[key] ?? XRayServer(name: tool.server, tokens: 0, tools: 0)
            server.tokens += tool.line + tool.definition
            server.tools += 1
            servers[key] = server
        }
        for (name, size) in blocks {
            let key = Self.key(name)
            var server = servers[key] ?? XRayServer(name: name, tokens: 0, tools: 0)
            // The block's display name ("claude.ai Docs") reads better than the tool id.
            server.name = name
            server.tokens += size
            servers[key] = server
        }
        var mcp = servers.values.map { XRayServer(name: $0.name, tokens: HarnessXRay.estimate(bytes: $0.tokens), tools: $0.tools) }
        var files = files
        var skills = HarnessXRay.estimate(bytes: skills)
        var prompt = HarnessXRay.estimate(bytes: prompt)
        let measured = mcp.reduce(0) { $0 + $1.tokens } + files.reduce(0) { $0 + $1.tokens } + skills + prompt
        if measured > total {
            // Estimates ran over the exact total: shrink them to fit, keeping their shares.
            let scale = Double(total) / Double(measured)
            func fit(_ value: Int) -> Int { Int(Double(value) * scale) }
            for index in mcp.indices { mcp[index].tokens = fit(mcp[index].tokens) }
            for index in files.indices { files[index].tokens = fit(files[index].tokens) }
            skills = fit(skills)
            prompt = fit(prompt)
        }
        let parts = mcp.reduce(0) { $0 + $1.tokens } + files.reduce(0) { $0 + $1.tokens } + skills + prompt
        mcp.sort { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }
        return HarnessXRay(total: total, model: model, prompt: prompt, skills: skills, instructions: files,
                           mcp: mcp, systemAndTools: max(0, total - parts))
    }
}

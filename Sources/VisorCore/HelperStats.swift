import Foundation

/// What one helper has done so far, from its `subagents/agent-<id>.jsonl` and
/// `agent-<id>.meta.json`. Strings are capped: the files are not ours.
public struct HelperStats: Equatable, Sendable, Codable {
    public var dollars = 0.0
    /// Input, output and cache writes, like `SessionCost.tokens`.
    public var tokens = 0
    public var unpriced = false
    public var model: String?
    /// The last reply's input, cache reads and cache writes: what its context held.
    public var context = 0
    /// Calls per tool name (at most `maxTools` names) and all calls.
    public var tools: [String: Int] = [:]
    public var toolCalls = 0
    /// From the meta file; the Agent call that started it, its parent helper and type.
    public var toolUseID: String?
    public var parentAgentID: String?
    public var agentType: String?
    /// What it started with before its first reply (its own transcript's X-ray).
    public var xray: HarnessXRay?
    var metaDone = false

    public init() {}

    /// Only what a view shows: cost as its label, context in thousands, model, tool counts, type, X-ray.
    public struct Shown: Equatable, Sendable {
        public var cost: String?
        public var contextK: Int
        public var model: String?
        public var tools: [String: Int]
        /// The detail card's type pill and Started line.
        public var agentType: String?
        public var xray: HarnessXRay?
    }
    public var shown: Shown {
        Shown(cost: SessionCost(dollars: dollars, tokens: tokens, unpriced: unpriced).label,
              contextK: context / 1000, model: model, tools: tools, agentType: agentType, xray: xray)
    }

    public static let maxID = 128
    public static let maxTools = 16
    public static let maxName = 40
    static let maxMeta = 64 * 1024

    /// Claude Code's stand-in for an API error or interrupt: no real reply.
    static func isSynthetic(_ usage: TokenUsage) -> Bool { usage.model == "<synthetic>" }

    mutating func context(_ usage: TokenUsage) {
        guard !Self.isSynthetic(usage) else { return }
        context = usage.input + usage.cacheRead + usage.cacheWrite5m + usage.cacheWrite1h
        model = String(usage.model.prefix(Self.maxName))
    }

    mutating func add(_ usage: TokenUsage) {
        guard !Self.isSynthetic(usage) else { return }
        tokens += usage.input + usage.output + usage.cacheWrite5m + usage.cacheWrite1h
        if Pricing.price(for: usage.model) == nil { unpriced = true } else { dollars += Pricing.cost(of: usage) }
    }

    /// "a1b2" from ".../agent-a1b2.jsonl".
    static func agentID(ofFile file: String) -> String? {
        var name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        guard name.hasPrefix("agent-") else { return nil }
        name.removeFirst("agent-".count)
        return name.isEmpty ? nil : String(name.prefix(maxID))
    }

    /// Reads the meta file next to the transcript until it names its Agent call; then never again.
    static func readMeta(for file: String, id: String, into helpers: inout [String: HelperStats]) {
        if helpers[id]?.metaDone == true { return }
        let meta = (file as NSString).deletingPathExtension + ".meta.json"
        guard let data = readSmall(meta, limit: maxMeta),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func text(_ key: String, _ cap: Int) -> String? {
            (object[key] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(cap)) }
        }
        var stats = helpers[id] ?? HelperStats()
        stats.toolUseID = text("toolUseId", maxID)
        stats.parentAgentID = text("parentAgentId", maxID)
        stats.agentType = text("agentType", maxName)
        // Done once it names its Agent call, or says the helper finished: never read again.
        stats.metaDone = stats.toolUseID != nil || object["finished"] as? Bool == true
        helpers[id] = stats
    }

    /// The whole of a small regular file, opened without following a link or blocking on a
    /// pipe, and checked on the descriptor itself; nil when it is anything else or too big.
    static func readSmall(_ path: String, limit: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data.count <= limit ? data : nil
    }

    private static let toolMarker = Array(#""tool_use""#.utf8)

    /// Counts `tool_use` blocks of assistant lines, each id once. Only lines holding the
    /// marker are parsed.
    static func countTools(in data: Data, id: String, seen: inout Set<Int>, into helpers: inout [String: HelperStats]) {
        let marker = toolMarker
        let lines: [Range<Int>] = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>] in
            guard let base = raw.baseAddress else { return [] }
            var found: [Range<Int>] = []
            var start = 0
            while start < raw.count {
                var end = raw.count
                if let newline = memchr(base + start, 0x0A, raw.count - start) { end = UnsafeRawPointer(newline) - base }
                if memmem(base + start, end - start, marker, marker.count) != nil { found.append(start..<end) }
                start = end + 1
            }
            return found
        }
        for range in lines {
            autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: data[range]) as? [String: Any],
                      object["type"] as? String == "assistant",
                      let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
                for block in content where block["type"] as? String == "tool_use" {
                    guard let name = block["name"] as? String else { continue }
                    if let toolID = block["id"] as? String, !seen.insert(toolID.hashValue).inserted { continue }
                    var stats = helpers[id] ?? HelperStats()
                    stats.toolCalls += 1
                    let key = String(name.prefix(maxName))
                    if stats.tools[key] != nil || stats.tools.count < maxTools { stats.tools[key, default: 0] += 1 }
                    helpers[id] = stats
                }
            }
        }
    }
}

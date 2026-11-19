import Foundation

/// Reading tokens from Codex CLI, Gemini CLI and Antigravity CLI logs, the way
/// tokscale does. Each returns a file's (or conversation's) tokens by day and model.
extension TokenLedger {
    // MARK: Codex CLI

    /// One Codex rollout (~/.codex/sessions/**/*.jsonl). Codex writes running
    /// totals in `token_count` events; each counts the change since the last.
    /// A total that drops a little is a stale snapshot (skipped); one that drops
    /// a lot is a new count, and its last response counts on its own. Cached
    /// input is part of input, and reasoning part of output.
    public static func daily(codex data: Data, calendar: Calendar = .current) -> [String: [String: TokenCount]] {
        var out: [String: [String: TokenCount]] = [:]
        var model = "codex"
        var previous: CodexTotals?
        forEachLine(data) { object in
            guard let payload = object["payload"] as? [String: Any] else { return }
            if object["type"] as? String == "turn_context", let name = payload["model"] as? String, !name.isEmpty {
                model = name
                return
            }
            guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                  let stamp = (object["timestamp"] as? String).flatMap(TranscriptUsage.date) else { return }
            let total = (info["total_token_usage"] as? [String: Any]).map(CodexTotals.init)
            let last = (info["last_token_usage"] as? [String: Any]).map(CodexTotals.init)
            var delta: CodexTotals?
            if let total {
                if let before = previous {
                    if let change = total.minus(before) {
                        delta = change
                        previous = total
                    } else if total.sum * 100 >= before.sum * 98 {
                        return  // a stale snapshot; the next one carries on from `before`
                    } else {
                        delta = last
                        previous = total
                    }
                } else {
                    delta = total
                    previous = total
                }
            } else {
                delta = last
            }
            guard let delta, delta.sum > 0 else { return }
            let cached = min(delta.cached, delta.input)
            let count = TokenCount(input: delta.input - cached, output: delta.output, cacheRead: cached)
            add(&out, dayKey(stamp, calendar: calendar), key("Codex CLI", modelName(model)), count)
        }
        return out
    }

    struct CodexTotals {
        var input = 0, cached = 0, output = 0

        init(input: Int = 0, cached: Int = 0, output: Int = 0) {
            self.input = input
            self.cached = cached
            self.output = output
        }

        init(_ usage: [String: Any]) {
            func int(_ key: String) -> Int { max(0, (usage[key] as? NSNumber)?.intValue ?? 0) }
            self.init(input: int("input_tokens"), cached: max(int("cached_input_tokens"), int("cache_read_input_tokens")),
                      output: int("output_tokens"))
        }

        var sum: Int { input + output }

        /// What grew since `before`, or nil when anything went down.
        func minus(_ before: CodexTotals) -> CodexTotals? {
            guard input >= before.input, cached >= before.cached, output >= before.output else { return nil }
            return CodexTotals(input: input - before.input, cached: cached - before.cached, output: output - before.output)
        }
    }

    // MARK: Gemini CLI

    /// One Gemini CLI chat (~/.gemini/tmp/*/chats/): a JSON file with
    /// `messages`, or one JSON object per line. When a message's total says its
    /// input includes the cached tokens, they're taken out; thoughts count as
    /// output and tool use as input. `fallback` dates a message with no time.
    public static func daily(gemini data: Data, fallback: Date, calendar: Calendar = .current) -> [String: [String: TokenCount]] {
        var out: [String: [String: TokenCount]] = [:]
        var seen = Set<String>()
        func take(_ message: [String: Any]) {
            guard let tokens = message["tokens"] as? [String: Any], let model = message["model"] as? String else { return }
            if let id = message["id"] as? String, !seen.insert(id).inserted { return }
            func int(_ keys: String...) -> Int {
                for key in keys { if let value = (tokens[key] as? NSNumber)?.intValue { return max(0, value) } }
                return 0
            }
            var input = int("input", "prompt", "input_tokens", "promptTokenCount")
            let output = int("output", "candidates", "output_tokens", "candidatesTokenCount")
            let cached = int("cached", "cached_tokens", "cachedContentTokenCount")
            let thoughts = int("thoughts", "reasoning", "thoughtsTokenCount")
            let tool = int("tool", "tool_tokens", "toolUsePromptTokenCount")
            let total = int("total", "totalTokenCount", "total_tokens")
            if total > 0 && total == input + output + thoughts + tool { input -= min(cached, input) }
            let stamp = (message["timestamp"] as? String).flatMap(TranscriptUsage.date) ?? fallback
            let count = TokenCount(input: input + tool, output: output + thoughts, cacheRead: cached)
            add(&out, dayKey(stamp, calendar: calendar), key("Gemini CLI", modelName(model)), count)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let messages = object["messages"] as? [[String: Any]] { messages.forEach(take) } else { take(object) }
        } else {
            forEachLine(data, take)
        }
        return out
    }

    // MARK: Antigravity CLI

    /// When an Antigravity conversation started: `trajectory_metadata_blob.data`, field 2 = {1: seconds}.
    public static func antigravityCreated(_ blob: Data) -> Date? {
        guard let created = Protobuf.fields(blob).first(where: { $0.number == 2 })?.bytes,
              let seconds = Protobuf.fields(created).first(where: { $0.number == 1 })?.value, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// One Antigravity conversation's generations (`gen_metadata.data`). Each holds,
    /// in field 1, the model name (#19) and usage (#4: #2 input, #3 output, #4 cache
    /// write, #5 cache read). Generations are dated by the conversation's start:
    /// their own time moved between agy versions and can't be read reliably.
    public static func daily(antigravity generations: [Data], created: Date, calendar: Calendar = .current) -> [String: [String: TokenCount]] {
        var out: [String: [String: TokenCount]] = [:]
        let day = dayKey(created, calendar: calendar)
        var lastModel = "antigravity"
        for generation in generations {
            guard let chat = Protobuf.fields(generation).first(where: { $0.number == 1 })?.bytes else { continue }
            let fields = Protobuf.fields(chat)
            if let name = fields.first(where: { $0.number == 19 })?.bytes.flatMap({ String(data: $0, encoding: .utf8) }), !name.isEmpty {
                lastModel = name
            }
            guard let usage = fields.first(where: { $0.number == 4 })?.bytes else { continue }
            let values = Protobuf.fields(usage)
            func int(_ number: Int) -> Int { Int(clamping: values.first(where: { $0.number == number })?.value ?? 0) }
            let count = TokenCount(input: int(2), output: int(3), cacheRead: int(5), cacheWrite: int(4))
            guard count.total > 0 else { continue }
            add(&out, day, key("Antigravity", modelName(lastModel)), count)
        }
        return out
    }

    // MARK: Helpers

    static func add(_ out: inout [String: [String: TokenCount]], _ day: String, _ key: String, _ count: TokenCount) {
        out[day, default: [:]][key] = (out[day]?[key] ?? TokenCount()) + count
    }

    /// Each JSON object line; other lines are skipped.
    static func forEachLine(_ data: Data, _ body: ([String: Any]) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            autoreleasepool {
                if end > start, let object = try? JSONSerialization.jsonObject(with: data[start..<end]) as? [String: Any] { body(object) }
            }
            start = end + 1
        }
    }
}

/// Just enough protobuf to read a few fields: numbers, and nested messages or strings.
enum Protobuf {
    struct Field {
        var number: Int
        var value: UInt64?
        var bytes: Data?
    }

    static func fields(_ data: Data) -> [Field] {
        let bytes = [UInt8](data)
        var i = 0
        var out: [Field] = []
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint() else { return out }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return out }
                out.append(Field(number: number, value: value))
            case 1:
                guard i + 8 <= bytes.count else { return out }
                i += 8
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - i) else { return out }
                out.append(Field(number: number, bytes: Data(bytes[i..<i + Int(length)])))
                i += Int(length)
            case 5:
                guard i + 4 <= bytes.count else { return out }
                i += 4
            default:
                return out
            }
        }
        return out
    }
}

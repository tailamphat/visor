import AppKit
import VisorCore

/// Every token used, from each tool's own logs, into the ledger.
extension UsageService {

    nonisolated static var ledgerURL: URL {
        #if DEBUG
        HookServer.directory.appendingPathComponent("tokens-debug.json")
        #else
        HookServer.directory.appendingPathComponent("tokens.json")
        #endif
    }

    func loadLedger() {
        work.async {
            guard let data = try? Data(contentsOf: Self.ledgerURL),
                  let saved = try? JSONDecoder().decode(TokenLedger.self, from: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var merged = saved
                    merged.merge(self.ledger.days)
                    self.ledger = merged
                    self.model.tokenLedger = merged
                }
            }
        }
    }

    /// What a tool's logs say now; the ledger keeps the larger count for each day.
    func addTokens(_ fresh: [String: [String: TokenCount]]) {
        guard ledger.merge(fresh) else { return }
        model.tokenLedger = ledger
        let snapshot = ledger
        work.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.ledgerURL, options: .atomic)
        }
    }

    /// Copilot CLI's session store, read again only after it changes.
    func refreshCopilotTokens() {
        let known = copilotTokensStamp
        work.async {
            let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/session-store.db")
            let stamp = [db.path, db.path + "-wal"].compactMap {
                (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
            }.max()
            guard let stamp, stamp != known, let data = Self.sqlite(db.path, TokenLedger.copilotQuery),
                  let fresh = TokenLedger.daily(copilot: data) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.copilotTokensStamp = stamp
                    self.addTokens(fresh)
                }
            }
        }
    }

    /// Codex CLI, Gemini CLI and Antigravity CLI logs. Only files that changed
    /// since the last look are read again.
    func scanTokenLogs() {
        work.async {
            let fresh = autoreleasepool { Self.codexTokens().merging(Self.geminiTokens(), uniquingKeysWith: Self.sum)
                .merging(Self.antigravityTokens(), uniquingKeysWith: Self.sum) }
            guard !fresh.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.addTokens(fresh) } }
        }
    }

    nonisolated static func sum(_ a: [String: TokenCount], _ b: [String: TokenCount]) -> [String: TokenCount] {
        a.merging(b) { $0 + $1 }
    }

    /// A file's tokens, read again only when it changed (`stamp` covers a database's -wal too).
    nonisolated static func tokens(of path: String, stamp: Date, read: () -> [String: [String: TokenCount]]?) -> [String: [String: TokenCount]] {
        if let cached = tokenFiles[path], cached.stamp == stamp { return cached.days }
        guard let days = read() else { return tokenFiles[path]?.days ?? [:] }
        tokenFiles[path] = (stamp, days)
        return days
    }

    nonisolated static func modified(_ paths: String...) -> Date? {
        paths.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
    }

    nonisolated static func files(under root: URL, matching keep: (URL) -> Bool) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter(keep)
    }

    /// Every file's days added together.
    nonisolated static func total(_ parts: [[String: [String: TokenCount]]]) -> [String: [String: TokenCount]] {
        parts.reduce(into: [:]) { out, days in out.merge(days, uniquingKeysWith: sum) }
    }

    /// Codex rollouts: $CODEX_HOME (or ~/.codex)/sessions and archived_sessions.
    nonisolated static func codexTokens() -> [String: [String: TokenCount]] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let rollouts = ["sessions", "archived_sessions"].flatMap {
            files(under: home.appendingPathComponent($0)) { $0.pathExtension == "jsonl" }
        }
        return total(rollouts.map { url in
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var reader = codexReaders[url.path] ?? TokenLedger.CodexReader()
            // A file that shrank was rewritten: read it again from the start.
            if size < reader.offset { reader = TokenLedger.CodexReader() }
            if size > reader.offset, let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: reader.offset)
                if let data = try? handle.readToEnd() { reader.read(data) }
                codexReaders[url.path] = reader
            }
            return reader.days
        })
    }

    /// Gemini CLI chats: ~/.gemini/tmp/<project>/chats/*.json(l), and older session-*.json files.
    nonisolated static func geminiTokens() -> [String: [String: TokenCount]] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/tmp")
        let chats = files(under: root) { url in
            ["json", "jsonl"].contains(url.pathExtension)
                && (url.deletingLastPathComponent().lastPathComponent == "chats" || url.lastPathComponent.hasPrefix("session-"))
        }
        return total(chats.compactMap { url in
            guard let stamp = modified(url.path) else { return nil }
            return tokens(of: url.path, stamp: stamp) {
                (try? Data(contentsOf: url, options: .mappedIfSafe)).map { TokenLedger.daily(gemini: $0, fallback: stamp) }
            }
        })
    }

    /// Antigravity CLI conversations: ~/.gemini/antigravity-cli/conversations/*.db,
    /// opened read-only without touching agy's write-ahead log.
    nonisolated static func antigravityTokens() -> [String: [String: TokenCount]] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/conversations")
        let databases = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "db" } ?? []
        return total(databases.compactMap { url in
            guard let stamp = modified(url.path, url.path + "-wal") else { return nil }
            return tokens(of: url.path, stamp: stamp) {
                let uri = "file:\(url.path)?immutable=1"
                func blobs(_ query: String) -> [Data]? {
                    guard let data = sqlite(uri, query),
                          let rows = data.isEmpty ? [] : try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
                    return rows.compactMap { ($0["h"] as? String).flatMap(Data.init(hex:)) }
                }
                guard let created = blobs("SELECT hex(data) AS h FROM trajectory_metadata_blob LIMIT 1")?.first
                        .flatMap(TokenLedger.antigravityCreated) ?? modified(url.path),
                      let generations = blobs("SELECT hex(data) AS h FROM gen_metadata ORDER BY idx") else { return nil }
                return TokenLedger.daily(antigravity: generations, created: created)
            }
        })
    }

    /// OpenCode's tokens by day and model, all time.
    nonisolated static func readOpenCodeTokens() -> [String: [String: TokenCount]] {
        var out: [String: [String: TokenCount]] = [:]
        let dir = openCodeDataDir()
        for name in ["opencode.db", "opencode-next.db"] {
            let path = dir.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path),
                  let tablesData = sqlite(path, "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('message', 'session_message')"),
                  let tables = try? JSONSerialization.jsonObject(with: tablesData) as? [[String: Any]],
                  let query = TokenLedger.openCodeQuery(tables: Set(tables.compactMap { $0["name"] as? String })),
                  let data = sqlite(path, query), let days = TokenLedger.daily(openCode: data) else { continue }
            out.merge(days, uniquingKeysWith: sum)
        }
        return out
    }
}

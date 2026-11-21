import AppKit
import VisorCore

/// OpenCode's local usage and Go limits.
extension UsageService {


    struct OpenCodeRead {
        var usage: OpenCodeUsage?
        var error: String?
    }

    /// Local OpenCode usage from its SQLite database, plus Go limits when the
    /// user has a Go key. Only the last 30 days are queried, so sqlite3 answers
    /// in milliseconds even on a large database, so this is not the cost `agy` is.
    func refreshOpenCode() {
        guard model.shows(.openCode), !fetchingOpenCode else { return }
        if let attempt = openCodeAttempt, Date().timeIntervalSince(attempt) < 45 { return }
        openCodeAttempt = Date()
        fetchingOpenCode = true
        work.async {
            let local = Self.readOpenCodeUsage()
            let tokens = Self.readOpenCodeTokens()
            let go = Self.openCodeGoToken().flatMap { Self.fetchOpenCodeGo($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetchingOpenCode = false
                    self.model.openCode = local.usage
                    self.model.openCodeError = local.error
                    self.model.openCodeGo = go
                    if local.usage != nil { self.model.openCodeUpdated = Date() }
                    self.addTokens(tokens)
                    self.checkLimitsBack()
                }
            }
        }
    }

    /// OpenCode follows XDG: an explicit OPENCODE_DATA_DIR, then XDG_DATA_HOME,
    /// then ~/.local/share.
    nonisolated static func openCodeDataDir() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let dir = environment["OPENCODE_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        if let dir = environment["XDG_DATA_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("opencode")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode")
    }

    nonisolated static func readOpenCodeUsage() -> OpenCodeRead {
        let dir = openCodeDataDir()
        var rows: [OpenCodeRow] = []
        var foundDatabase = false
        var failed = false
        for name in ["opencode.db", "opencode-next.db"] {
            let path = dir.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            foundDatabase = true
            guard let tablesData = sqlite(path, "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('message', 'session_message')"),
                  let tables = try? JSONSerialization.jsonObject(with: tablesData) as? [[String: Any]],
                  let query = OpenCodeUsage.query(tables: Set(tables.compactMap { $0["name"] as? String }),
                                                  since: Date().addingTimeInterval(-30 * 86_400)) else {
                failed = true
                continue
            }
            guard let data = sqlite(path, query) else {
                failed = true
                continue
            }
            let parsed = data.isEmpty ? [] : OpenCodeUsage.parse(data)
            guard let parsed else {
                failed = true
                continue
            }
            rows.append(contentsOf: parsed)
        }
        guard foundDatabase else { return OpenCodeRead(usage: nil, error: nil) }
        guard !rows.isEmpty else {
            return OpenCodeRead(usage: nil, error: failed ? "Couldn't read OpenCode usage." : nil)
        }
        return OpenCodeRead(usage: OpenCodeUsage.make(from: rows),
                            error: failed ? "Couldn't read some OpenCode data." : nil)
    }

    nonisolated static func sqlite(_ path: String, _ query: String) -> Data? {
        Shell.run("/usr/bin/sqlite3", ["-json", path, query]).flatMap { $0.ok ? $0.data : nil }
    }

    /// OpenCode's auth file, written by `opencode auth login`.
    nonisolated static func openCodeGoToken() -> String? {
        let path = openCodeDataDir().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for id in ["opencode-go", "opencode"] {
            guard let entry = object[id] as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty else { continue }
            let type = entry["type"] as? String ?? "api"
            if type == "api" || type == "zen" { return key }
        }
        return nil
    }

    nonisolated static func fetchOpenCodeGo(_ token: String) -> OpenCodeGoUsage? {
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard case .ok(let data) = send(request) else { return nil }
        return OpenCodeGoUsage.parse(data)
    }
}

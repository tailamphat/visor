import AppKit
import VisorCore

/// Keeps the model's usage numbers fresh, all off the main thread:
/// - plan limits (5-hour session, weekly) from the Claude account Claude Code signed in with
/// - Copilot allowances from `gh` and Copilot CLI's own sign-in
/// - Antigravity quotas from `agy`, only while the Usage tab is looked at
/// - API-equivalent spend from Claude Code's local transcripts
@MainActor
final class UsageService {
    private let model: AppModel
    private let work = DispatchQueue(label: "visor.usage", qos: .utility)
    private let transcripts = TranscriptUsage()
    private var timers: [Timer] = []
    private var limitWatch = LimitWatch()
    /// Refreshes the plan just after a nearly used-up limit resets, rather than up to 2 minutes later.
    private var resetTimer: Timer?
    private var resetTimerFor: Date?
    /// A limit that had run out (or nearly) has reset.
    var onLimitBack: ((LimitReturn) -> Void)?
    private var fetching = false
    /// Read from the keychain on demand; Claude Code owns and refreshes it.
    private var token: (value: String, expires: Date)?
    /// A refused keychain prompt isn't asked again on the timer, only from
    /// "Allow access" under Connected accounts.
    private var claudeKeychainDenied = false
    private var copilotKeychainDenied = false
    /// Every token used, by day, tool and model; saved, so history outlives the tools' logs.
    private var ledger = TokenLedger()
    /// When Copilot's session store last changed, so it's only queried after it does.
    private var copilotTokensStamp: Date?
    /// Codex, Gemini CLI and Antigravity logs already read, by file: used on `work` only.
    private nonisolated(unsafe) static var tokenFiles: [String: (stamp: Date, days: [String: [String: TokenCount]])] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        model.claudeInstalled = HookInstaller.hasClaudeCode
        model.antigravityInstalled = Self.agyPath != nil
        model.openCodeInstalled = Self.openCodeInstalled
        model.copilotInstalled = Self.ghPath != nil || Self.copilotPath != nil
            || FileManager.default.fileExists(atPath: Self.copilotConfig.path) || !Self.editorAccounts().isEmpty
        loadLedger()
        scanTranscripts()
        refreshCopilotTokens()
        scanTokenLogs()
        refreshPlan()
        refreshOpenCode()
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scanTranscripts()
                self?.refreshCopilotTokens()
                self?.scanTokenLogs()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlan() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOpenCode() }
        })
        for timer in timers { timer.tolerance = 3 }
    }

    private func checkLimitsBack() {
        let readings = LimitReading.all(plan: model.plan, openCode: model.openCodeGo)
        for back in limitWatch.update(readings) { onLimitBack?(back) }
        // The soonest reset of a Claude limit that's nearly used up.
        let next = readings.filter { $0.key.hasPrefix("claude.") && $0.percentUsed >= LimitWatch.nearlyOut }
            .compactMap(\.resetsAt).filter { $0 > Date() }.min()
        guard next != resetTimerFor else { return }
        resetTimerFor = next
        resetTimer?.invalidate()
        resetTimer = next.map {
            Timer.scheduledTimer(withTimeInterval: $0.timeIntervalSinceNow + 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPlan() }
            }
        }
    }

    /// Called when the usage tab opens, so numbers are never stale when looked at.
    func refreshIfStale() {
        if Date().timeIntervalSince(model.planUpdated ?? .distantPast) > 45 { refreshPlan() } else { checkCopilotAccounts() }
        refreshAntigravity()
        refreshOpenCode()
    }

    /// A button under Connected accounts.
    func perform(_ action: ConnectionState.Action, for provider: ConnectionProvider) {
        switch action {
        case .allowAccess:
            if provider == .claude { claudeKeychainDenied = false; token = nil }
            if provider == .copilot { copilotKeychainDenied = false; copilotHostsRead = .distantPast }
            refresh(provider)
        case .refresh:
            if provider == .copilot { copilotHostsRead = .distantPast }
            if provider == .antigravity { antigravityAttempt = nil }
            if provider == .openCode { openCodeAttempt = nil }
            refresh(provider)
        case .signIn:
            Self.openInTerminal(provider.signInCommand(hasGH: Self.ghPath != nil))
        }
    }

    private func refresh(_ provider: ConnectionProvider) {
        switch provider {
        case .claude: refreshPlan()
        case .copilot: refreshCopilot()
        case .antigravity: refreshAntigravity()
        case .openCode: refreshOpenCode()
        }
    }

    /// Runs a sign-in command in Terminal through a `.command` file, which
    /// needs no Automation permission. The shell is a login shell, so the
    /// user's PATH finds the tool.
    private static func openInTerminal(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("visor-sign-in.command")
        let script = "#!/bin/zsh -l\nclear\n\(command)\n"
        guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    private func scanTranscripts() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let transcripts = transcripts
        let first = model.spend == nil
        work.async {
            let changed = transcripts.scan(root: root)
            // Recompute at least once a minute so "today" rolls over at midnight.
            let summary = SpendSummary.make(from: transcripts.records)
            let tokens = changed || first ? TokenLedger.daily(claude: transcripts.records) : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if changed || self.model.spend != summary { self.model.spend = summary }
                    if let tokens { self.addTokens(tokens) }
                }
            }
        }
    }

    // MARK: Tokens

    private nonisolated static var ledgerURL: URL {
        #if DEBUG
        HookServer.directory.appendingPathComponent("tokens-debug.json")
        #else
        HookServer.directory.appendingPathComponent("tokens.json")
        #endif
    }

    private func loadLedger() {
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
    private func addTokens(_ fresh: [String: [String: TokenCount]]) {
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

    private nonisolated static func sum(_ a: [String: TokenCount], _ b: [String: TokenCount]) -> [String: TokenCount] {
        a.merging(b) { $0 + $1 }
    }

    /// A file's tokens, read again only when it changed (`stamp` covers a database's -wal too).
    private nonisolated static func tokens(of path: String, stamp: Date, read: () -> [String: [String: TokenCount]]?) -> [String: [String: TokenCount]] {
        if let cached = tokenFiles[path], cached.stamp == stamp { return cached.days }
        guard let days = read() else { return tokenFiles[path]?.days ?? [:] }
        tokenFiles[path] = (stamp, days)
        return days
    }

    private nonisolated static func modified(_ paths: String...) -> Date? {
        paths.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
    }

    private nonisolated static func files(under root: URL, matching keep: (URL) -> Bool) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter(keep)
    }

    /// Every file's days added together.
    private nonisolated static func total(_ parts: [[String: [String: TokenCount]]]) -> [String: [String: TokenCount]] {
        parts.reduce(into: [:]) { out, days in out.merge(days, uniquingKeysWith: sum) }
    }

    /// Codex rollouts: $CODEX_HOME (or ~/.codex)/sessions and archived_sessions.
    private nonisolated static func codexTokens() -> [String: [String: TokenCount]] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let rollouts = ["sessions", "archived_sessions"].flatMap {
            files(under: home.appendingPathComponent($0)) { $0.pathExtension == "jsonl" }
        }
        return total(rollouts.compactMap { url in
            guard let stamp = modified(url.path) else { return nil }
            return tokens(of: url.path, stamp: stamp) {
                (try? Data(contentsOf: url, options: .mappedIfSafe)).map { TokenLedger.daily(codex: $0) }
            }
        })
    }

    /// Gemini CLI chats: ~/.gemini/tmp/<project>/chats/*.json(l), and older session-*.json files.
    private nonisolated static func geminiTokens() -> [String: [String: TokenCount]] {
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
    private nonisolated static func antigravityTokens() -> [String: [String: TokenCount]] {
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
    private nonisolated static func readOpenCodeTokens() -> [String: [String: TokenCount]] {
        var out: [String: [String: TokenCount]] = [:]
        let dir = openCodeDataDir()
        for name in ["opencode.db", "opencode-next.db"] {
            let path = dir.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path),
                  let tablesData = sqlite(path, "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('message', 'session_message')"),
                  let tables = try? JSONSerialization.jsonObject(with: tablesData) as? [[String: Any]],
                  let query = TokenLedger.openCodeQuery(tables: Set(tables.compactMap { $0["name"] as? String })),
                  let data = sqlite(path, query), let days = TokenLedger.daily(openCode: data) else { continue }
            for (day, entries) in days {
                for (key, count) in entries { out[day, default: [:]][key] = (out[day]?[key] ?? TokenCount()) + count }
            }
        }
        return out
    }

    func refreshPlan() {
        refreshCopilot()
        guard model.shows(.claude), !fetching else { return }
        fetching = true
        let cached = token
        let allowKeychain = !claudeKeychainDenied
        // Every 15 minutes, and whenever the sign-in is read again (a new token).
        let wantsProfile = Date().timeIntervalSince(profileRead) > 15 * 60 || cached.map { $0.expires < Date() } ?? true
        work.async {
            var lookup: KeychainLookup?
            var profileName: String?
            let result = Self.fetchPlan(cached: cached, allowKeychain: allowKeychain, lookup: &lookup) { token in
                // The live plan name: the saved sign-in keeps the plan Claude Code signed in with.
                if wantsProfile { profileName = Self.fetchProfilePlan(token: token) }
            }
            let usesAPIKey = lookup == .missing && Self.claudeUsesAPIKey()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetching = false
                    if let lookup {
                        if lookup == .denied { self.claudeKeychainDenied = true }
                        self.model.claudeLookup = lookup
                        self.model.claudeUsesAPIKey = usesAPIKey
                    }
                    if let profileName {
                        self.profileName = profileName
                        self.profileRead = Date()
                        self.model.planName = profileName
                    }
                    switch result {
                    case .success(let fetched):
                        self.token = fetched.token
                        self.model.plan = fetched.plan
                        if let name = self.profileName ?? fetched.planName { self.model.planName = name }
                        self.model.planError = nil
                        self.model.planUpdated = Date()
                        self.checkLimitsBack()
                    case .failure(let error):
                        self.token = nil
                        self.model.planError = error.message
                    }
                }
            }
        }
    }

    // MARK: Copilot

    private var fetchingCopilot = false

    /// Copilot allowances for every GitHub host `gh` is signed in to (github.com
    /// and company *.ghe.com), keeping plans with premium requests to count.
    /// The token comes from `gh` each time; Visor never stores it.
    private func refreshCopilot() {
        guard model.shows(.copilot), !fetchingCopilot else { return }
        let gh = Self.ghPath
        fetchingCopilot = true
        let allowKeychain = !copilotKeychainDenied
        // Signed-in hosts are re-read every 30 minutes, tokens only when GitHub
        // rejects one; both stay in memory only. Saves launching gh three
        // times on every refresh.
        // A different active account (gh auth switch, a new Copilot CLI
        // sign-in) drops both, since the old account's token still works.
        let cachedHosts = Date().timeIntervalSince(copilotHostsRead) < 1800 ? copilotHosts : nil
        let cachedTokens = copilotTokens
        let knownAccounts = copilotAccounts
        work.async {
            let accounts = Self.copilotAccountsFingerprint()
            let switched = accounts != knownAccounts
            let knownHosts = switched ? nil : cachedHosts
            let knownTokens = switched ? [:] : cachedTokens
            let hosts = knownHosts ?? gh.map { CopilotUsage.signedInHosts(fromStatus: Self.run($0, ["auth", "status"]) ?? "") } ?? []
            // Copilot CLI signs in on its own; use it for hosts gh doesn't know.
            let cliAccounts = (try? String(contentsOf: Self.copilotConfig, encoding: .utf8)).map(CopilotCLIAccount.parse) ?? []
            var cliByHost: [String: CopilotCLIAccount] = [:]
            var cliHosts: [String] = []
            for account in cliAccounts where !hosts.contains(account.host) && cliByHost[account.host] == nil {
                cliByHost[account.host] = account
                cliHosts.append(account.host)
            }
            // Editor plugins (JetBrains, Neovim, Xcode) keep their own sign-in, token included.
            let editorAccounts = Self.editorAccounts()
            var editorByHost: [String: CopilotEditorAccount] = [:]
            for account in editorAccounts where !hosts.contains(account.host) && cliByHost[account.host] == nil {
                editorByHost[account.host] = account
                cliHosts.append(account.host)
            }
            var tokens = knownTokens
            var found: [CopilotUsage] = []
            var problems: [CopilotProblem] = []
            var denied = false
            for host in hosts + cliHosts {
                guard let base = CopilotUsage.apiBase(for: host) else { continue }
                // One retry with a fresh token if the remembered one is refused.
                for attempt in 0..<2 {
                    if attempt == 1 || tokens[host] == nil {
                        if let account = editorByHost[host] {
                            tokens[host] = account.token
                        } else if let account = cliByHost[host] {
                            guard allowKeychain else { break }
                            let read = Self.keychainPassword(service: "copilot-cli", account: account.keychainAccount)
                            if read.lookup == .denied { denied = true }
                            tokens[host] = read.value
                        } else if let gh {
                            tokens[host] = Self.run(gh, ["auth", "token", "--hostname", host])?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    guard let token = tokens[host], !token.isEmpty else {
                        if !denied { problems.append(.noToken(host: host)) }
                        break
                    }
                    var request = URLRequest(url: base.appendingPathComponent("copilot_internal/user"))
                    request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("Visor", forHTTPHeaderField: "User-Agent")
                    request.timeoutInterval = 15
                    let response = Self.send(request)
                    if case .status(let code) = response, code == 401, attempt == 0 { continue }
                    // Every account that answers is kept, with or without premium requests;
                    // one that doesn't says why under Connected accounts.
                    switch response {
                    case .ok(let data):
                        if let usage = CopilotUsage.parse(data, host: host, login: cliByHost[host]?.login ?? editorByHost[host]?.login ?? "") {
                            found.append(usage)
                        } else {
                            problems.append(.unreadable(host: host))
                        }
                    case .status(0): problems.append(.offline(host: host))
                    case .status(let code): problems.append(.refused(host: host, status: code))
                    }
                    break
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetchingCopilot = false
                    self.copilotAccounts = accounts
                    if knownHosts == nil {
                        self.copilotHosts = hosts
                        self.copilotHostsRead = Date()
                    }
                    if denied { self.copilotKeychainDenied = true }
                    self.model.copilotDenied = denied || (self.copilotKeychainDenied && found.isEmpty)
                    self.model.copilotAccounts = Set(hosts + cliAccounts.map(\.host) + editorAccounts.map(\.host)).count
                    self.model.copilotProblems = problems
                    self.copilotTokens = tokens
                    // Company plans first.
                    let sorted = found.sorted { ($0.host == "github.com" ? 1 : 0) < ($1.host == "github.com" ? 1 : 0) }
                    if sorted != self.model.copilot { self.model.copilot = sorted }
                }
            }
        }
    }

    private var copilotHosts: [String] = []
    private var copilotHostsRead = Date.distantPast
    private var copilotTokens: [String: String] = [:]
    /// Who was signed in at the last read, nil before the first.
    private var copilotAccounts: String?

    /// Opening the Usage tab between refreshes: two small file reads, and a
    /// refresh only if the active account changed.
    private func checkCopilotAccounts() {
        guard model.shows(.copilot), !fetchingCopilot, let known = copilotAccounts else { return }
        work.async {
            guard Self.copilotAccountsFingerprint() != known else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshCopilot() } }
        }
    }

    private nonisolated static func copilotAccountsFingerprint() -> String {
        GitHubAccounts.fingerprint(ghHosts: try? String(contentsOf: ghHostsFile, encoding: .utf8),
                                   copilotConfig: try? String(contentsOf: copilotConfig, encoding: .utf8))
            + editorAccounts().map { "\neditor \($0.host) \($0.login)" }.joined()
    }

    /// Copilot editor sign-ins: apps.json, or the older hosts.json.
    private nonisolated static func editorAccounts() -> [CopilotEditorAccount] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/github-copilot")
        for name in ["apps.json", "hosts.json"] {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                let accounts = CopilotEditorAccount.parse(data)
                if !accounts.isEmpty { return accounts }
            }
        }
        return []
    }

    // MARK: OpenCode

    private var fetchingOpenCode = false
    private var openCodeAttempt: Date?

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
    private nonisolated static func openCodeDataDir() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let dir = environment["OPENCODE_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        if let dir = environment["XDG_DATA_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("opencode")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode")
    }

    private nonisolated static func readOpenCodeUsage() -> OpenCodeRead {
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

    private nonisolated static func sqlite(_ path: String, _ query: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", path, query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// OpenCode's auth file, written by `opencode auth login`.
    private nonisolated static func openCodeGoToken() -> String? {
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

    private nonisolated static func fetchOpenCodeGo(_ token: String) -> OpenCodeGoUsage? {
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard case .ok(let data) = send(request) else { return nil }
        return OpenCodeGoUsage.parse(data)
    }

    // MARK: Antigravity

    private var fetchingAntigravity = false
    private var antigravityAttempt: Date?

    /// Antigravity's weekly quotas, from its own CLI. Print mode takes a few
    /// seconds and a couple of hundred MB, so it runs only when the Usage tab
    /// opens and the last reading is over two minutes old.
    func refreshAntigravity() {
        guard model.shows(.antigravity), let agy = Self.agyPath, !fetchingAntigravity else { return }
        if let attempt = antigravityAttempt, Date().timeIntervalSince(attempt) < 120 { return }
        antigravityAttempt = Date()
        fetchingAntigravity = true
        model.antigravityLoading = true
        work.async {
            let result = Self.fetchAntigravity(agy)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetchingAntigravity = false
                    self.model.antigravityLoading = false
                    switch result {
                    case .success(let usage):
                        if self.model.antigravity != usage { self.model.antigravity = usage }
                        self.model.antigravityError = nil
                        self.model.antigravityUpdated = Date()
                    case .failure(let error):
                        self.model.antigravityError = error.message
                    }
                }
            }
        }
    }

    private nonisolated static let agyPath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    struct AntigravityError: Error { var message: String }

    private nonisolated static func fetchAntigravity(_ agy: String) -> Result<AntigravityUsage, AntigravityError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: agy)
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        environment["VISOR_USAGE_PROBE"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return .failure(AntigravityError(message: "Antigravity isn't available."))
        }
        // Stop a stuck CLI from holding the usage queue.
        let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeout.schedule(deadline: .now() + 30)
        timeout.setEventHandler { process.terminate() }
        timeout.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else {
            return .failure(AntigravityError(message: "Run agy and sign in to see Antigravity limits."))
        }
        guard let usage = AntigravityUsage.parse(data) else {
            return .failure(AntigravityError(message: "Couldn't read Antigravity usage."))
        }
        return .success(usage)
    }

    private nonisolated static let ghPath = tool("gh")
    private nonisolated static let copilotPath = tool("copilot")
    private nonisolated static var copilotConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/config.json")
    }

    /// gh's hosts.yml: GH_CONFIG_DIR, then XDG_CONFIG_HOME/gh, then ~/.config/gh.
    private nonisolated static var ghHostsFile: URL {
        let environment = ProcessInfo.processInfo.environment
        let dir: URL
        if let path = environment["GH_CONFIG_DIR"], !path.isEmpty {
            dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if let path = environment["XDG_CONFIG_HOME"], !path.isEmpty {
            dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("gh")
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gh")
        }
        return dir.appendingPathComponent("hosts.yml")
    }

    private nonisolated static func tool(_ name: String) -> String? {
        ToolLocator.candidates(name, home: FileManager.default.homeDirectoryForCurrentUser.path)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static var openCodeInstalled: Bool {
        tool("opencode") != nil || FileManager.default.fileExists(atPath: openCodeDataDir().path)
    }

    /// Runs a command and returns its output (stdout and stderr; `gh auth status` writes to stderr).
    private nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    struct PlanError: Error { var message: String }
    struct Fetched {
        var plan: PlanUsage
        var planName: String?
        var token: (value: String, expires: Date)
    }

    /// The plan name from `/api/oauth/profile`, kept between its 15-minute reads.
    private var profileName: String?
    private var profileRead = Date.distantPast

    private nonisolated static func fetchProfilePlan(token: String) -> String? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard case .ok(let data) = send(request) else { return nil }
        return ClaudePlan.name(fromProfile: data)
    }

    /// `lookup` is set when the sign-in was read again (not on a cached token).
    /// `withToken` runs once the token is known, before the usage request,
    /// so the plan name can be read even when usage is unavailable.
    private nonisolated static func fetchPlan(cached: (value: String, expires: Date)?, allowKeychain: Bool,
                                              lookup: inout KeychainLookup?,
                                              withToken: (String) -> Void = { _ in }) -> Result<Fetched, PlanError> {
        var credentials: Credentials?
        if cached == nil || cached!.expires < Date() {
            let read = readCredentials(allowKeychain: allowKeychain)
            lookup = read.lookup
            credentials = read.credentials
            guard credentials != nil else {
                return .failure(PlanError(message: read.lookup == .denied
                    ? "Visor wasn't allowed to read Claude Code's sign-in. Allow it under Connected accounts."
                    : "Sign in to Claude Code to see your plan limits."))
            }
        }
        let token = credentials.map { ($0.token, $0.expires) } ?? cached!
        withToken(token.0)
        switch request(token: token.0) {
        case .ok(let data):
            guard let plan = PlanUsage.parse(data) else { return .failure(PlanError(message: "Couldn't read plan usage.")) }
            return .success(Fetched(plan: plan, planName: credentials?.planName ?? nil, token: token))
        case .status(let status) where status == 401 && credentials == nil:
            // Claude Code may have refreshed the token since we read it.
            return fetchPlan(cached: nil, allowKeychain: allowKeychain, lookup: &lookup)
        case .status(let status):
            return .failure(PlanError(message: status == 401 ? "Claude Code's sign-in expired. Run claude to refresh it."
                                                             : "Plan usage unavailable (\(status))."))
        }
    }

    typealias Credentials = ClaudeCredentials.Parsed

    /// Claude Code keeps its OAuth credentials in the login keychain, or in
    /// `.credentials.json` when the keychain can't be used. Reading through
    /// /usr/bin/security avoids a keychain prompt for this app.
    private nonisolated static func readCredentials(allowKeychain: Bool) -> (credentials: Credentials?, lookup: KeychainLookup) {
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        var lookup = KeychainLookup.denied
        if allowKeychain {
            let read = keychainPassword(service: ClaudeCredentials.keychainService(configDir: configDir), account: nil)
            lookup = read.lookup
            if let value = read.value, let parsed = ClaudeCredentials.parse(Data(value.utf8)) { return (parsed, .found) }
        }
        let file = ClaudeCredentials.file(home: FileManager.default.homeDirectoryForCurrentUser.path, configDir: configDir)
        if let data = try? Data(contentsOf: file), let parsed = ClaudeCredentials.parse(data) { return (parsed, .found) }
        return (nil, lookup == .found ? .missing : lookup)
    }

    /// Only asked when there's no OAuth sign-in, to tell "use an API key" from "signed out".
    private nonisolated static func claudeUsesAPIKey() -> Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        return (try? Data(contentsOf: file)).map(ClaudeCredentials.usesAPIKey) ?? false
    }

    private nonisolated static func keychainPassword(service: String, account: String?) -> (value: String?, lookup: KeychainLookup) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service] + (account.map { ["-a", $0] } ?? []) + ["-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, .denied) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lookup = KeychainLookup(securityExitStatus: process.terminationStatus)
        guard lookup == .found else { return (nil, lookup) }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (value.isEmpty ? nil : value, lookup)
    }

    enum Response { case ok(Data), status(Int) }

    private nonisolated static func send(_ request: URLRequest) -> Response {
        let done = DispatchSemaphore(value: 0)
        var result = Response.status(0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = status == 200 && data != nil ? .ok(data!) : .status(status)
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private nonisolated static func request(token: String) -> Response {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let done = DispatchSemaphore(value: 0)
        var result = Response.status(0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = status == 200 && data != nil ? .ok(data!) : .status(status)
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}

private extension Data {
    /// Bytes from sqlite's hex(): "0A1F..." -> [0x0A, 0x1F, ...].
    init?(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 65...70: v = c - 55
            case 97...102: v = c - 87
            default: return nil
            }
            if let h = high { bytes.append(h << 4 | v); high = nil } else { high = v }
        }
        self.init(bytes)
    }
}

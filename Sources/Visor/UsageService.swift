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
    private var fetching = false
    /// Read from the keychain on demand; Claude Code owns and refreshes it.
    private var token: (value: String, expires: Date)?
    /// A refused keychain prompt isn't asked again on the timer, only from
    /// "Allow access" under Connected accounts.
    private var claudeKeychainDenied = false
    private var copilotKeychainDenied = false

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        model.antigravityInstalled = Self.agyPath != nil
        model.openCodeInstalled = Self.openCodeInstalled
        model.copilotInstalled = Self.ghPath != nil || Self.copilotPath != nil
            || FileManager.default.fileExists(atPath: Self.copilotConfig.path)
        scanTranscripts()
        refreshPlan()
        refreshOpenCode()
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanTranscripts() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlan() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOpenCode() }
        })
        for timer in timers { timer.tolerance = 3 }
    }

    /// Called when the usage tab opens, so numbers are never stale when looked at.
    func refreshIfStale() {
        if Date().timeIntervalSince(model.planUpdated ?? .distantPast) > 45 { refreshPlan() }
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
        work.async {
            let changed = transcripts.scan(root: root)
            // Recompute at least once a minute so "today" rolls over at midnight.
            let summary = SpendSummary.make(from: transcripts.records)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if changed || self.model.spend != summary { self.model.spend = summary }
                }
            }
        }
    }

    func refreshPlan() {
        refreshCopilot()
        guard model.shows(.claude), !fetching else { return }
        fetching = true
        let cached = token
        let allowKeychain = !claudeKeychainDenied
        work.async {
            var lookup: KeychainLookup?
            let result = Self.fetchPlan(cached: cached, allowKeychain: allowKeychain, lookup: &lookup)
            let usesAPIKey = lookup == .missing && Self.claudeUsesAPIKey()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetching = false
                    if let lookup {
                        if lookup == .denied { self.claudeKeychainDenied = true }
                        self.model.claudeLookup = lookup
                        self.model.claudeUsesAPIKey = usesAPIKey
                    }
                    switch result {
                    case .success(let fetched):
                        self.token = fetched.token
                        self.model.plan = fetched.plan
                        if let name = fetched.planName { self.model.planName = name }
                        self.model.planError = nil
                        self.model.planUpdated = Date()
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
        let knownHosts = Date().timeIntervalSince(copilotHostsRead) < 1800 ? copilotHosts : nil
        let knownTokens = copilotTokens
        work.async {
            let hosts = knownHosts ?? gh.map { CopilotUsage.signedInHosts(fromStatus: Self.run($0, ["auth", "status"]) ?? "") } ?? []
            // Copilot CLI signs in on its own; use it for hosts gh doesn't know.
            let cliAccounts = (try? String(contentsOf: Self.copilotConfig, encoding: .utf8)).map(CopilotCLIAccount.parse) ?? []
            var cliByHost: [String: CopilotCLIAccount] = [:]
            var cliHosts: [String] = []
            for account in cliAccounts where !hosts.contains(account.host) && cliByHost[account.host] == nil {
                cliByHost[account.host] = account
                cliHosts.append(account.host)
            }
            var tokens = knownTokens
            var found: [CopilotUsage] = []
            var denied = false
            for host in hosts + cliHosts {
                guard let base = CopilotUsage.apiBase(for: host) else { continue }
                // One retry with a fresh token if the remembered one is refused.
                for attempt in 0..<2 {
                    if attempt == 1 || tokens[host] == nil {
                        if let account = cliByHost[host] {
                            guard allowKeychain else { break }
                            let read = Self.keychainPassword(service: "copilot-cli", account: account.keychainAccount)
                            if read.lookup == .denied { denied = true }
                            tokens[host] = read.value
                        } else if let gh {
                            tokens[host] = Self.run(gh, ["auth", "token", "--hostname", host])?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    guard let token = tokens[host], !token.isEmpty else { break }
                    var request = URLRequest(url: base.appendingPathComponent("copilot_internal/user"))
                    request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("Visor", forHTTPHeaderField: "User-Agent")
                    request.timeoutInterval = 15
                    let response = Self.send(request)
                    if case .status(let code) = response, code == 401, attempt == 0 { continue }
                    if case .ok(let data) = response, let usage = CopilotUsage.parse(data, host: host), usage.isTracked {
                        found.append(usage)
                    }
                    break
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetchingCopilot = false
                    if knownHosts == nil {
                        self.copilotHosts = hosts
                        self.copilotHostsRead = Date()
                    }
                    if denied { self.copilotKeychainDenied = true }
                    self.model.copilotDenied = denied || (self.copilotKeychainDenied && found.isEmpty)
                    self.model.copilotAccounts = Set(hosts + cliAccounts.map(\.host)).count
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
            let go = Self.openCodeGoToken().flatMap { Self.fetchOpenCodeGo($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetchingOpenCode = false
                    self.model.openCode = local.usage
                    self.model.openCodeError = local.error
                    self.model.openCodeGo = go
                    if local.usage != nil { self.model.openCodeUpdated = Date() }
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

    /// `lookup` is set when the sign-in was read again (not on a cached token).
    private nonisolated static func fetchPlan(cached: (value: String, expires: Date)?, allowKeychain: Bool,
                                              lookup: inout KeychainLookup?) -> Result<Fetched, PlanError> {
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

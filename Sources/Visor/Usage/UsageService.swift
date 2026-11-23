import AppKit
import VisorCore

/// Keeps the model's usage numbers fresh, all off the main thread:
/// - plan limits (5-hour session, weekly) from the Claude account Claude Code signed in with
/// - Copilot allowances from `gh` and Copilot CLI's own sign-in
/// - Antigravity quotas from `agy`, only while the Usage tab is looked at
/// - API-equivalent spend from Claude Code's local transcripts
@MainActor
final class UsageService {
    let model: AppModel
    let work = DispatchQueue(label: "visor.usage", qos: .utility)
    let transcripts = TranscriptUsage()
    var timers: [Timer] = []
    var limitWatch = LimitWatch()
    /// Refreshes the plan just after a nearly used-up limit resets, rather than up to 2 minutes later.
    var resetTimer: Timer?
    var resetTimerFor: Date?
    /// A limit that had run out (or nearly) has reset.
    var onLimitBack: ((LimitReturn) -> Void)?
    var fetching = false
    /// Read from the keychain on demand; Claude Code owns and refreshes it.
    var token: (value: String, expires: Date)?
    /// A refused keychain prompt isn't asked again on the timer, only from
    /// "Allow access" under Connected accounts.
    var claudeKeychainDenied = false
    var copilotKeychainDenied = false
    /// Every token used, by day, tool and model; saved, so history outlives the tools' logs.
    var ledger = TokenLedger()
    /// When Copilot's session store last changed, so it's only queried after it does.
    var copilotTokensStamp: Date?
    /// Codex, Gemini CLI and Antigravity logs already read, by file: used on `work` only.
    nonisolated(unsafe) static var tokenFiles: [String: (stamp: Date, days: [String: [String: TokenCount]])] = [:]
    /// Codex rollouts only grow: each is read on from where the last read stopped. Used on `work` only.
    nonisolated(unsafe) static var codexReaders: [String: TokenLedger.CodexReader] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        model.claudeInstalled = HookInstaller.hasClaudeCode
        model.antigravityInstalled = Self.agyPath != nil
        model.openCodeInstalled = Self.openCodeInstalled
        model.copilotInstalled = Self.ghPath != nil || Self.copilotPath != nil
            || FileManager.default.fileExists(atPath: Self.copilotConfig.path) || !Self.editorAccounts().isEmpty
        findUnmeteredAgents()
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
            MainActor.assumeIsolated {
                self?.refreshPlan()
                self?.findUnmeteredAgents()
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOpenCode() }
        })
        for timer in timers { timer.tolerance = 3 }
    }

    /// Agents a limit handoff can offer without a limit reading, so one installed
    /// while Visor runs is offered too. A few file checks, off the main thread.
    func findUnmeteredAgents() {
        work.async {
            let unmetered = [("codex", "Codex CLI"), ("gemini", "Gemini CLI")].filter { Self.tool($0.0) != nil }.map(\.1)
                + (Self.openCodeInstalled ? ["OpenCode"] : [])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if self.model.unmeteredAgents != unmetered { self.model.unmeteredAgents = unmetered } }
            }
        }
    }

    func checkLimitsBack() {
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

    func refresh(_ provider: ConnectionProvider) {
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
    static func openInTerminal(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("visor-sign-in.command")
        let script = "#!/bin/zsh -l\nclear\n\(command)\n"
        guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    func scanTranscripts() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let transcripts = transcripts
        let first = model.spend == nil
        work.async {
            let changed = transcripts.scan(root: root)
            // Recompute at least once a minute so "today" rolls over at midnight.
            let summary = SpendSummary.make(days: transcripts.spendDays)
            let tokens = changed || first ? transcripts.tokenDays : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if changed || self.model.spend != summary { self.model.spend = summary }
                    if let tokens { self.addTokens(tokens) }
                }
            }
        }
    }


    var fetchingCopilot = false
    var copilotHosts: [String] = []
    var copilotHostsRead = Date.distantPast
    var copilotTokens: [String: String] = [:]
    /// Who was signed in at the last read, nil before the first.
    var copilotAccounts: String?
    var fetchingOpenCode = false
    var openCodeAttempt: Date?
    var fetchingAntigravity = false
    var antigravityAttempt: Date?
    /// The plan name from `/api/oauth/profile`, kept between its 15-minute reads.
    var profileName: String?
    var profileRead = Date.distantPast

    nonisolated static let ghPath = tool("gh")
    nonisolated static let copilotPath = tool("copilot")
    nonisolated static var copilotConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/config.json")
    }

    /// gh's hosts.yml: GH_CONFIG_DIR, then XDG_CONFIG_HOME/gh, then ~/.config/gh.
    nonisolated static var ghHostsFile: URL {
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

    nonisolated static func tool(_ name: String) -> String? { Shell.which(name) }

    nonisolated static var openCodeInstalled: Bool {
        tool("opencode") != nil || FileManager.default.fileExists(atPath: openCodeDataDir().path)
    }

    /// Runs a command and returns its output (stdout and stderr; `gh auth status` writes to stderr).
    nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
        Shell.run(path, arguments, mergeStderr: true)?.text
    }


    enum Response { case ok(Data), status(Int) }

    nonisolated static func send(_ request: URLRequest) -> Response {
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

    nonisolated static func request(token: String) -> Response {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return send(request)
    }
}

import AppKit
import VisorCore

/// Claude plan limits from the account Claude Code signed in with.
extension UsageService {
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


    struct PlanError: Error { var message: String }
    struct Fetched {
        var plan: PlanUsage
        var planName: String?
        var token: (value: String, expires: Date)
    }


    nonisolated static func fetchProfilePlan(token: String) -> String? {
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
    nonisolated static func fetchPlan(cached: (value: String, expires: Date)?, allowKeychain: Bool,
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
    nonisolated static func readCredentials(allowKeychain: Bool) -> (credentials: Credentials?, lookup: KeychainLookup) {
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
    nonisolated static func claudeUsesAPIKey() -> Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        return (try? Data(contentsOf: file)).map(ClaudeCredentials.usesAPIKey) ?? false
    }

    nonisolated static func keychainPassword(service: String, account: String?) -> (value: String?, lookup: KeychainLookup) {
        let arguments = ["find-generic-password", "-s", service] + (account.map { ["-a", $0] } ?? []) + ["-w"]
        guard let output = Shell.run("/usr/bin/security", arguments) else { return (nil, .denied) }
        let lookup = KeychainLookup(securityExitStatus: output.status)
        guard lookup == .found else { return (nil, lookup) }
        let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value.isEmpty ? nil : value, lookup)
    }
}

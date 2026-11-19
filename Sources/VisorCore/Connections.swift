import CryptoKit
import Foundation

/// The AI tools Visor reads usage from, as listed under Connected accounts.
public enum ConnectionProvider: String, CaseIterable, Sendable {
    case claude, copilot, antigravity, openCode

    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .copilot: return "GitHub Copilot"
        case .antigravity: return "Antigravity"
        case .openCode: return "OpenCode"
        }
    }

    /// The agent name its mark and quota use.
    public var agent: String {
        switch self {
        case .claude: return "Claude Code"
        case .copilot: return "Copilot CLI"
        case .antigravity: return "Antigravity"
        case .openCode: return "OpenCode"
        }
    }

    /// What "Sign in…" runs in Terminal.
    public func signInCommand(hasGH: Bool) -> String {
        switch self {
        case .claude: return "claude"
        case .copilot: return hasGH ? "gh auth login" : "copilot"
        case .antigravity: return "agy"
        case .openCode: return "opencode auth login"
        }
    }

    /// Hidden providers, as kept in UserDefaults.
    public static func hidden(from stored: [String]) -> Set<ConnectionProvider> {
        Set(stored.compactMap(ConnectionProvider.init(rawValue:)))
    }

    public static func store(_ hidden: Set<ConnectionProvider>) -> [String] {
        hidden.map(\.rawValue).sorted()
    }
}

/// What a keychain read through `/usr/bin/security` found.
public enum KeychainLookup: Equatable, Sendable {
    case found, missing, denied

    /// 44 is errSecItemNotFound; anything else that fails means the prompt was
    /// refused or the keychain couldn't be used.
    public init(securityExitStatus status: Int32) {
        switch status {
        case 0: self = .found
        case 44: self = .missing
        default: self = .denied
        }
    }
}

/// Where Claude Code keeps its sign-in: the login keychain, or a plain file
/// when the keychain can't be used.
public enum ClaudeCredentials {
    public struct Parsed: Equatable, Sendable {
        public var token: String
        public var expires: Date
        public var planName: String?
    }

    /// "Claude Code-credentials", plus "-" and 8 hex digits of the config
    /// folder's SHA-256 when `CLAUDE_CONFIG_DIR` is set, like Claude Code.
    public static func keychainService(configDir: String?) -> String {
        guard let dir = configDir, !dir.isEmpty else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    public static func file(home: String, configDir: String?) -> URL {
        let dir = configDir.flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".claude")
        return URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
    }

    public static func parse(_ data: Data) -> Parsed? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        let plan = (oauth["subscriptionType"] as? String).map { "Claude " + $0.capitalized }
        return Parsed(token: token, expires: Date(timeIntervalSince1970: expiresMs / 1000), planName: plan)
    }

    /// Claude Code signed in with an API key (`~/.claude.json`), which has no plan limits.
    public static func usesAPIKey(claudeJSON data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (object["primaryApiKey"] as? String).map { !$0.isEmpty } ?? false
    }
}

/// An account Copilot CLI is signed in to. Its token sits in the login
/// keychain under service "copilot-cli", account "https://<host>:<login>".
public struct CopilotCLIAccount: Equatable, Sendable {
    public var host: String
    public var login: String

    public init(host: String, login: String) {
        self.host = host
        self.login = login
    }

    public var keychainAccount: String { "https://\(host):\(login)" }

    /// `loggedInUsers` from `~/.copilot/config.json`, which starts with `//` comments.
    public static func parse(config: String) -> [CopilotCLIAccount] {
        let json = config.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let users = object["loggedInUsers"] as? [[String: Any]] else { return [] }
        let accounts = users.compactMap(account)
        // The account it last signed in with is the one in use: first, so it wins its host.
        guard let last = (object["lastLoggedInUser"] as? [String: Any]).flatMap(account),
              accounts.contains(last) else { return accounts }
        return [last] + accounts.filter { $0 != last }
    }

    /// The account Copilot CLI last signed in with.
    public static func last(config: String) -> CopilotCLIAccount? {
        let json = config.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return (object?["lastLoggedInUser"] as? [String: Any]).flatMap(account)
    }

    private static func account(_ user: [String: Any]) -> CopilotCLIAccount? {
        guard let url = user["host"] as? String, let login = user["login"] as? String,
              let host = URL(string: url)?.host ?? Optional(url), !host.isEmpty else { return nil }
        return CopilotCLIAccount(host: host, login: login)
    }
}

/// A Copilot sign-in made by an editor plugin (JetBrains, Neovim, Xcode, older
/// VS Code): `~/.config/github-copilot/apps.json`, keyed "host:appId", or the
/// older `hosts.json`, keyed by host. The token sits in the file itself.
public struct CopilotEditorAccount: Equatable, Sendable {
    public var host: String
    public var login: String
    public var token: String

    public init(host: String, login: String, token: String) {
        self.host = host
        self.login = login
        self.token = token
    }

    /// One account per host, sorted by host.
    public static func parse(_ data: Data) -> [CopilotEditorAccount] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var byHost: [String: CopilotEditorAccount] = [:]
        for (key, value) in object {
            guard let entry = value as? [String: Any], let token = entry["oauth_token"] as? String, !token.isEmpty else { continue }
            let host = String(key.split(separator: ":").first ?? "")
            guard !host.isEmpty, byHost[host] == nil else { continue }
            byHost[host] = CopilotEditorAccount(host: host, login: entry["user"] as? String ?? "", token: token)
        }
        return byHost.values.sorted { $0.host < $1.host }
    }
}

/// Which GitHub account is in use on each host, so a switch (`gh auth switch`,
/// or signing in to Copilot CLI as someone else) is noticed without a restart.
public enum GitHubAccounts {
    /// The active `user` of each host in gh's hosts.yml. Every signed-in
    /// account sits under `users`; the active one is also the host's `user`.
    public static func active(ghHosts: String) -> [String: String] {
        var result: [String: String] = [:]
        var host: String?
        for line in ghHosts.split(separator: "\n") {
            if !line.hasPrefix(" "), line.hasSuffix(":") {
                host = String(line.dropLast())
            } else if let host, line.hasPrefix("    user:"), !line.hasPrefix("     ") {
                result[host] = line.dropFirst("    user:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    /// The active accounts in one string: different after a switch, the same otherwise.
    public static func fingerprint(ghHosts: String?, copilotConfig: String?) -> String {
        var parts = active(ghHosts: ghHosts ?? "").map { "gh \($0.key) \($0.value)" }.sorted()
        if let last = copilotConfig.flatMap(CopilotCLIAccount.last(config:)) {
            parts.append("cli \(last.host) \(last.login)")
        }
        return parts.joined(separator: "\n")
    }
}

/// Where command-line tools are installed, since an app doesn't get the shell's PATH.
public enum ToolLocator {
    public static func candidates(_ name: String, home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin",
         home + "/.local/bin", home + "/bin", home + "/.nix-profile/bin", "/run/current-system/sw/bin",
         home + "/.local/share/mise/shims", home + "/.asdf/shims"]
            .map { $0 + "/" + name }
    }
}

/// Why one Copilot account's usage couldn't be read.
public enum CopilotProblem: Equatable, Sendable {
    case noToken(host: String)
    case refused(host: String, status: Int)
    case unreadable(host: String)
    case offline(host: String)

    public var text: String {
        switch self {
        case .noToken(let host): return "\(host): no sign-in token found"
        case .refused(let host, let status): return "\(host): GitHub refused the request (\(status))"
        case .unreadable(let host): return "\(host): couldn't read GitHub's answer"
        case .offline(let host): return "\(host): couldn't reach GitHub"
        }
    }
}

/// A row under Connected accounts: whether Visor can read a tool's usage, and why not.
public enum ConnectionState: Equatable, Sendable {
    case connected(String)
    case checking
    case notInstalled
    case notSignedIn
    case denied
    case apiKey
    case failed(String)

    public enum Action: Equatable, Sendable { case allowAccess, signIn, refresh }
    public enum Tone: Sendable { case good, warning, bad, neutral }

    public var text: String {
        switch self {
        case .connected(let detail): return detail
        case .checking: return "Checking…"
        case .notInstalled: return "Not installed"
        case .notSignedIn: return "Not signed in"
        case .denied: return "Keychain access was denied"
        case .apiKey: return "Uses an API key, no plan limits"
        case .failed(let reason): return reason
        }
    }

    public var action: Action? {
        switch self {
        case .connected, .failed: return .refresh
        case .notSignedIn: return .signIn
        case .denied: return .allowAccess
        case .checking, .notInstalled, .apiKey: return nil
        }
    }

    public var tone: Tone {
        switch self {
        case .connected: return .good
        case .notSignedIn, .failed, .apiKey: return .warning
        case .denied: return .bad
        case .checking, .notInstalled: return .neutral
        }
    }

    /// `lookup` is nil until the first read finishes.
    public static func claude(lookup: KeychainLookup?, usesAPIKey: Bool, planLoaded: Bool,
                              planName: String?, error: String?) -> ConnectionState {
        if planLoaded { return .connected((planName ?? "Claude") + " plan") }
        switch lookup {
        case nil: return .checking
        case .denied: return .denied
        case .missing: return usesAPIKey ? .apiKey : .notSignedIn
        case .found: return error.map(ConnectionState.failed) ?? .checking
        }
    }

    /// `accounts`: signed-in accounts across gh and Copilot CLI; `problems`: why
    /// any of them couldn't be read, so the row says what happened.
    public static func copilot(installed: Bool, accounts: Int, usage: [CopilotUsage], denied: Bool,
                               problems: [CopilotProblem] = []) -> ConnectionState {
        if !usage.isEmpty {
            let read = usage.map { "\($0.login.isEmpty ? "Signed in" : $0.login) on \($0.host)" }
            return .connected((read + problems.map(\.text)).joined(separator: " · "))
        }
        if denied { return .denied }
        if !installed { return .notInstalled }
        if accounts == 0 { return .notSignedIn }
        return .failed(problems.isEmpty ? "GitHub sent no Copilot usage" : problems.map(\.text).joined(separator: " · "))
    }

    public static func antigravity(installed: Bool, loaded: Bool, error: String?) -> ConnectionState {
        if !installed { return .notInstalled }
        if loaded { return .connected("Weekly limits") }
        guard let error else { return .checking }
        return error.contains("sign in") ? .notSignedIn : .failed(error)
    }

    public static func openCode(installed: Bool, local: Bool, go: Bool) -> ConnectionState {
        if !installed { return .notInstalled }
        switch (go, local) {
        case (true, true): return .connected("Go plan and local usage")
        case (true, false): return .connected("Go plan")
        case (false, true): return .connected("Local usage")
        case (false, false): return .failed("No usage recorded yet")
        }
    }
}

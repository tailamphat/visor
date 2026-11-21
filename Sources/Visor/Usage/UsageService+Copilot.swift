import AppKit
import VisorCore

/// Copilot allowances from `gh` and Copilot CLI's own sign-in.
extension UsageService {


    /// Copilot allowances for every GitHub host `gh` is signed in to (github.com
    /// and company *.ghe.com), keeping plans with premium requests to count.
    /// The token comes from `gh` each time; Visor never stores it.
    func refreshCopilot() {
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


    /// Opening the Usage tab between refreshes: two small file reads, and a
    /// refresh only if the active account changed.
    func checkCopilotAccounts() {
        guard model.shows(.copilot), !fetchingCopilot, let known = copilotAccounts else { return }
        work.async {
            guard Self.copilotAccountsFingerprint() != known else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshCopilot() } }
        }
    }

    nonisolated static func copilotAccountsFingerprint() -> String {
        GitHubAccounts.fingerprint(ghHosts: try? String(contentsOf: ghHostsFile, encoding: .utf8),
                                   copilotConfig: try? String(contentsOf: copilotConfig, encoding: .utf8))
            + editorAccounts().map { "\neditor \($0.host) \($0.login)" }.joined()
    }

    /// Copilot editor sign-ins: apps.json, or the older hosts.json.
    nonisolated static func editorAccounts() -> [CopilotEditorAccount] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/github-copilot")
        for name in ["apps.json", "hosts.json"] {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                let accounts = CopilotEditorAccount.parse(data)
                if !accounts.isEmpty { return accounts }
            }
        }
        return []
    }
}

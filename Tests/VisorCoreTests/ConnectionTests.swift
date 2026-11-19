import Foundation
import Testing
@testable import VisorCore

@Suite("Claude credentials")
struct ClaudeCredentialsTests {
    @Test func defaultKeychainService() {
        #expect(ClaudeCredentials.keychainService(configDir: nil) == "Claude Code-credentials")
        #expect(ClaudeCredentials.keychainService(configDir: "") == "Claude Code-credentials")
    }

    @Test func customConfigDirAddsAHashSuffix() {
        // Claude Code: "-" + the first 8 hex digits of sha256(config dir).
        #expect(ClaudeCredentials.keychainService(configDir: "/Users/me/.claude-work") == "Claude Code-credentials-1e91dd84")
    }

    @Test func credentialsFileDefaultsToTheHomeFolder() {
        #expect(ClaudeCredentials.file(home: "/Users/me", configDir: nil).path == "/Users/me/.claude/.credentials.json")
        #expect(ClaudeCredentials.file(home: "/Users/me", configDir: "/Users/me/.claude-work").path == "/Users/me/.claude-work/.credentials.json")
    }

    @Test func parsesTheOAuthBlock() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"t0k","expiresAt":1793458000000,"subscriptionType":"max"}}"#
        let parsed = try #require(ClaudeCredentials.parse(Data(json.utf8)))
        #expect(parsed.token == "t0k")
        #expect(parsed.expires == Date(timeIntervalSince1970: 1_793_458_000))
        #expect(parsed.planName == "Claude Max")
    }

    @Test func noOAuthBlockIsNotACredential() {
        #expect(ClaudeCredentials.parse(Data(#"{"other":1}"#.utf8)) == nil)
        #expect(ClaudeCredentials.parse(Data("not json".utf8)) == nil)
    }

    @Test("security's exit status says found, missing or refused", arguments: [
        (Int32(0), KeychainLookup.found), (Int32(44), .missing), (Int32(51), .denied), (Int32(128), .denied),
    ])
    func keychainLookup(status: Int32, lookup: KeychainLookup) {
        #expect(KeychainLookup(securityExitStatus: status) == lookup)
    }

    @Test func apiKeyAccountsAreSpotted() {
        #expect(ClaudeCredentials.usesAPIKey(claudeJSON: Data(#"{"primaryApiKey":"sk-x","numStartups":3}"#.utf8)))
        #expect(!ClaudeCredentials.usesAPIKey(claudeJSON: Data(#"{"numStartups":3}"#.utf8)))
        #expect(!ClaudeCredentials.usesAPIKey(claudeJSON: Data(#"{"primaryApiKey":""}"#.utf8)))
    }
}

@Suite("Copilot CLI accounts")
struct CopilotCLIAccountsTests {
    let config = """
    // User settings belong in settings.json.
    // This file is managed automatically.
    {
      "lastLoggedInUser": { "host": "https://acme.ghe.com", "login": "octocat" },
      "loggedInUsers": [
        { "host": "https://acme.ghe.com", "login": "octocat" },
        { "host": "https://github.com", "login": "monalisa" }
      ]
    }
    """

    @Test func readsSignedInAccountsPastTheComments() {
        let accounts = CopilotCLIAccount.parse(config: config)
        #expect(accounts == [CopilotCLIAccount(host: "acme.ghe.com", login: "octocat"),
                             CopilotCLIAccount(host: "github.com", login: "monalisa")])
    }

    /// Two accounts on one host: the one Copilot CLI last signed in with comes first.
    @Test func lastSignedInAccountComesFirst() {
        let switched = """
        {
          "lastLoggedInUser": { "host": "https://github.com", "login": "hubot" },
          "loggedInUsers": [
            { "host": "https://github.com", "login": "monalisa" },
            { "host": "https://acme.ghe.com", "login": "octocat" },
            { "host": "https://github.com", "login": "hubot" }
          ]
        }
        """
        #expect(CopilotCLIAccount.parse(config: switched) == [
            CopilotCLIAccount(host: "github.com", login: "hubot"),
            CopilotCLIAccount(host: "github.com", login: "monalisa"),
            CopilotCLIAccount(host: "acme.ghe.com", login: "octocat"),
        ])
    }

    @Test func keychainAccountIsTheHostURLAndLogin() {
        #expect(CopilotCLIAccount(host: "acme.ghe.com", login: "octocat").keychainAccount == "https://acme.ghe.com:octocat")
    }

    @Test func noAccountsWhenSignedOut() {
        #expect(CopilotCLIAccount.parse(config: "// managed\n{\"firstLaunchAt\":\"x\"}").isEmpty)
        #expect(CopilotCLIAccount.parse(config: "").isEmpty)
    }

    @Test func ghIsLookedForBeyondHomebrew() {
        let places = ToolLocator.candidates("gh", home: "/Users/me")
        #expect(places.first == "/opt/homebrew/bin/gh")
        #expect(places.contains("/opt/local/bin/gh"))
        #expect(places.contains("/Users/me/.local/bin/gh"))
        #expect(places.contains("/Users/me/.nix-profile/bin/gh"))
    }
}

@Suite("Connection states")
struct ConnectionStateTests {
    @Test func claudeStates() {
        #expect(ConnectionState.claude(lookup: .found, usesAPIKey: false, planLoaded: true, planName: "Claude Max", error: nil)
            == .connected("Claude Max plan"))
        #expect(ConnectionState.claude(lookup: .denied, usesAPIKey: false, planLoaded: false, planName: nil, error: nil) == .denied)
        #expect(ConnectionState.claude(lookup: .missing, usesAPIKey: true, planLoaded: false, planName: nil, error: nil) == .apiKey)
        #expect(ConnectionState.claude(lookup: .missing, usesAPIKey: false, planLoaded: false, planName: nil, error: nil) == .notSignedIn)
        #expect(ConnectionState.claude(lookup: .found, usesAPIKey: false, planLoaded: false, planName: nil, error: "Plan usage unavailable (500).")
            == .failed("Plan usage unavailable (500)."))
        #expect(ConnectionState.claude(lookup: nil, usesAPIKey: false, planLoaded: false, planName: nil, error: nil) == .checking)
    }

    @Test func copilotStates() {
        let pro = CopilotUsage(login: "octocat", plan: "pro", host: "github.com", premiumEntitlement: 300, premiumRemaining: 100,
                               premiumUnlimited: false, overagePermitted: false, overageUsed: 0,
                               chatUnlimited: true, completionsUnlimited: true, resetsAt: nil)
        #expect(ConnectionState.copilot(installed: true, accounts: 1, usage: [pro], denied: false) == .connected("octocat on github.com"))
        #expect(ConnectionState.copilot(installed: false, accounts: 0, usage: [], denied: false) == .notInstalled)
        #expect(ConnectionState.copilot(installed: true, accounts: 0, usage: [], denied: false) == .notSignedIn)
        #expect(ConnectionState.copilot(installed: true, accounts: 1, usage: [], denied: true) == .denied)
        #expect(ConnectionState.copilot(installed: true, accounts: 1, usage: [], denied: false) == .failed("GitHub sent no Copilot usage"))
        // Why it failed, per account, instead of a guess.
        #expect(ConnectionState.copilot(installed: true, accounts: 2, usage: [], denied: false,
                                        problems: [.refused(host: "github.com", status: 403), .noToken(host: "acme.ghe.com")])
                == .failed("github.com: GitHub refused the request (403) · acme.ghe.com: no sign-in token found"))
        // A plan without premium requests is still a connected account.
        let free = CopilotUsage(login: "me", plan: "free", host: "github.com", premiumEntitlement: 0, premiumRemaining: 0,
                                premiumUnlimited: false, overagePermitted: false, overageUsed: 0,
                                chatUnlimited: false, completionsUnlimited: false, resetsAt: nil)
        #expect(ConnectionState.copilot(installed: true, accounts: 1, usage: [free], denied: false) == .connected("me on github.com"))
        // One account read, another not: both said.
        #expect(ConnectionState.copilot(installed: true, accounts: 2, usage: [free], denied: false, problems: [.refused(host: "acme.ghe.com", status: 403)])
                == .connected("me on github.com · acme.ghe.com: GitHub refused the request (403)"))
    }

    @Test func copilotProblemsSayWhatHappened() {
        #expect(CopilotProblem.noToken(host: "github.com").text == "github.com: no sign-in token found")
        #expect(CopilotProblem.refused(host: "github.com", status: 404).text == "github.com: GitHub refused the request (404)")
        #expect(CopilotProblem.unreadable(host: "github.com").text == "github.com: couldn't read GitHub's answer")
        #expect(CopilotProblem.offline(host: "github.com").text == "github.com: couldn't reach GitHub")
    }

    @Test func antigravityAndOpenCodeStates() {
        #expect(ConnectionState.antigravity(installed: false, loaded: false, error: nil) == .notInstalled)
        #expect(ConnectionState.antigravity(installed: true, loaded: true, error: nil) == .connected("Weekly limits"))
        #expect(ConnectionState.antigravity(installed: true, loaded: false, error: "Run agy and sign in to see Antigravity limits.") == .notSignedIn)
        #expect(ConnectionState.antigravity(installed: true, loaded: false, error: nil) == .checking)
        #expect(ConnectionState.openCode(installed: false, local: false, go: false) == .notInstalled)
        #expect(ConnectionState.openCode(installed: true, local: true, go: true) == .connected("Go plan and local usage"))
        #expect(ConnectionState.openCode(installed: true, local: true, go: false) == .connected("Local usage"))
        #expect(ConnectionState.openCode(installed: true, local: false, go: false) == .failed("No usage recorded yet"))
    }

    @Test func eachStateSaysWhatToDo() {
        #expect(ConnectionState.denied.action == .allowAccess)
        #expect(ConnectionState.notSignedIn.action == .signIn)
        #expect(ConnectionState.connected("x").action == .refresh)
        #expect(ConnectionState.notInstalled.action == nil)
        #expect(ConnectionState.denied.text == "Keychain access was denied")
        #expect(ConnectionState.apiKey.text == "Uses an API key, no plan limits")
    }

    @Test func signInCommands() {
        #expect(ConnectionProvider.claude.signInCommand(hasGH: false) == "claude")
        #expect(ConnectionProvider.copilot.signInCommand(hasGH: true) == "gh auth login")
        #expect(ConnectionProvider.copilot.signInCommand(hasGH: false) == "copilot")
        #expect(ConnectionProvider.antigravity.signInCommand(hasGH: false) == "agy")
        #expect(ConnectionProvider.openCode.signInCommand(hasGH: false) == "opencode auth login")
    }

    @Test func hiddenProvidersRoundTrip() {
        let hidden: Set<ConnectionProvider> = [.copilot, .openCode]
        #expect(ConnectionProvider.hidden(from: ConnectionProvider.store(hidden)) == hidden)
        #expect(ConnectionProvider.hidden(from: ["nonsense"]).isEmpty)
        #expect(ConnectionProvider.copilot.agent == "Copilot CLI")
    }
}

@Suite("Active GitHub accounts")
struct ActiveGitHubAccountsTests {
    let hosts = """
    github.com:
        git_protocol: https
        users:
            monalisa:
            hubot:
        user: hubot
    acme.ghe.com:
        users:
            octocat:
        user: octocat
    """

    /// gh keeps every signed-in account under `users` and the active one in `user`.
    @Test func readsTheActiveUserOfEachHost() {
        #expect(GitHubAccounts.active(ghHosts: hosts) == ["github.com": "hubot", "acme.ghe.com": "octocat"])
        #expect(GitHubAccounts.active(ghHosts: "").isEmpty)
    }

    /// `gh auth switch` or a new Copilot CLI sign-in changes the fingerprint;
    /// rewriting the same accounts doesn't.
    @Test func fingerprintChangesWhenTheActiveAccountDoes() {
        let config = #"{"lastLoggedInUser":{"host":"https://acme.ghe.com","login":"octocat"},"loggedInUsers":[]}"#
        let before = GitHubAccounts.fingerprint(ghHosts: hosts, copilotConfig: config)
        #expect(before == GitHubAccounts.fingerprint(ghHosts: hosts, copilotConfig: config))
        let switched = hosts.replacingOccurrences(of: "user: hubot", with: "user: monalisa")
        #expect(before != GitHubAccounts.fingerprint(ghHosts: switched, copilotConfig: config))
        let otherCLI = config.replacingOccurrences(of: "octocat", with: "hubot")
        #expect(before != GitHubAccounts.fingerprint(ghHosts: hosts, copilotConfig: otherCLI))
        #expect(GitHubAccounts.fingerprint(ghHosts: nil, copilotConfig: nil) == "")
    }
}

/// Copilot in JetBrains, Neovim, Xcode and older VS Code signs in on its own and
/// keeps the token in ~/.config/github-copilot/apps.json (or hosts.json).
@Suite("Copilot editor sign-in")
struct CopilotEditorAccountTests {
    @Test func readsAppsJSON() {
        let apps = #"""
        {"github.com:Iv1.b507a08c87ecfe98":{"user":"monalisa","oauth_token":"ghu_one","githubAppId":"Iv1.b507a08c87ecfe98"},
         "acme.ghe.com:Iv1.b507a08c87ecfe98":{"user":"octocat","oauth_token":"ghu_two","githubAppId":"Iv1.b507a08c87ecfe98"}}
        """#
        let accounts = CopilotEditorAccount.parse(Data(apps.utf8))
        #expect(accounts == [CopilotEditorAccount(host: "acme.ghe.com", login: "octocat", token: "ghu_two"),
                             CopilotEditorAccount(host: "github.com", login: "monalisa", token: "ghu_one")])
    }

    @Test func readsOlderHostsJSON() {
        let hosts = #"{"github.com":{"user":"monalisa","oauth_token":"gho_old"}}"#
        #expect(CopilotEditorAccount.parse(Data(hosts.utf8)) == [CopilotEditorAccount(host: "github.com", login: "monalisa", token: "gho_old")])
    }

    @Test func skipsEntriesWithoutAToken() {
        #expect(CopilotEditorAccount.parse(Data(#"{"github.com:x":{"user":"monalisa"}}"#.utf8)).isEmpty)
        #expect(CopilotEditorAccount.parse(Data("not json".utf8)).isEmpty)
    }
}

import Foundation
import Testing
@testable import VisorCore

@Suite("Release radar")
struct ReleaseRadarTests {
    func tool(_ name: String) throws -> ReleaseTool {
        try #require(ReleaseTool.all.first { $0.name == name })
    }

    func v(_ text: String) throws -> ToolVersion { try #require(ToolVersion(text)) }

    // Trimmed real shapes, confirmed with read-only GETs on 2026-11-22 (evidence/2a/feeds.txt).
    let npmDoc = Data(#"{"name":"@anthropic-ai/claude-code","version":"2.1.330","description":"Use Claude, Anthropic's AI assistant, right from your terminal.","bin":{"claude":"cli.js"},"dist":{"tarball":"https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-2.1.330.tgz"}}"#.utf8)
    let formulaDoc = Data(#"{"name":"opencode","full_name":"opencode","desc":"AI coding agent, built for the terminal","homepage":"https://opencode.ai","versions":{"stable":"2.3.2","head":null,"bottle":true},"revision":0}"#.utf8)
    let caskDoc = Data(#"{"token":"claude-code","name":["Claude Code"],"homepage":"https://www.anthropic.com/claude-code","version":"2.1.323","auto_updates":true}"#.utf8)
    func githubDoc(tag: String, draft: Bool = false, prerelease: Bool = false, body: String = "## What's changed\n\n- Added a thing") -> Data {
        let object: [String: Any] = ["tag_name": tag, "name": tag, "draft": draft, "prerelease": prerelease,
                                     "html_url": "https://evil.example/x", "published_at": "2026-11-21T18:00:00Z", "body": body]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// The tools Visor knows, by the names the Agents tab uses.
    @Test func catalogCoversKnownTools() throws {
        let withFeeds = ReleaseTool.all.filter { !$0.isSkipped }.map(\.name)
        #expect(withFeeds == ["Claude Code", "Copilot CLI", "Codex CLI", "Gemini CLI", "OpenCode"])
        #expect(Set(ReleaseTool.all.map(\.id)).count == ReleaseTool.all.count)
        let claude = try tool("Claude Code")
        #expect(claude.binary == "claude" && claude.npmPackage == "@anthropic-ai/claude-code")
        #expect(claude.brew == .cask("claude-code") && claude.github == ReleaseTool.GitHub(repo: "anthropics/claude-code", tagPrefix: "v"))
        #expect(try tool("Codex CLI").github?.tagPrefix == "rust-v")
        #expect(try tool("Gemini CLI").brew == .formula("gemini-cli"))
        #expect(try tool("OpenCode").github?.repo == "anomalyco/opencode")
    }

    /// Antigravity CLI has no public feed: no source, no command.
    @Test func antigravityIsSkipped() throws {
        let agy = try tool("Antigravity CLI")
        #expect(agy.isSkipped && agy.npmPackage == nil && agy.brew == nil && agy.github == nil)
        for method in InstallMethod.allCases {
            #expect(agy.updateCommand(method) == nil && agy.versionURL(for: method) == nil)
        }
        #expect(agy.installMethod(path: "/Users/me/.local/bin/agy", home: "/Users/me") == nil)
    }

    /// Each CLI's own `--version` wording (Codex and Gemini from their docs, not live).
    @Test func parsesInstalledVersions() throws {
        #expect(ToolVersion(output: "2.1.311 (Claude Code)\n")?.description == "2.1.311")
        #expect(ToolVersion(output: "GitHub Copilot CLI 1.0.107.\nRun 'copilot update' to check for updates.\n")?.description == "1.0.107")
        #expect(ToolVersion(output: "1.19.5\n")?.description == "1.19.5")
        #expect(ToolVersion(output: "codex-cli 0.63.0\n")?.description == "0.63.0")
        #expect(ToolVersion(output: "0.18.4")?.description == "0.18.4")
        #expect(ToolVersion(output: "v1.0.0-beta.2.")?.description == "1.0.0-beta.2")
        #expect(ToolVersion(output: "(node:4242) Warning: Node.js v18.0.0 is not supported\n2.1.311 (Claude Code)\n")?.description == "2.1.311")
        #expect(ToolVersion(output: "command not found: codex") == nil)
        #expect(ToolVersion(output: "") == nil)
    }

    /// Semver order: numbers by value, a prerelease below its release, tag prefixes only via the catalog.
    @Test func comparesVersions() throws {
        #expect(try v("2.1.311") < v("2.1.312"))
        #expect(try v("1.0.9") < v("1.0.10"))
        #expect(try v("1.0.0-beta.1") < v("1.0.0"))
        #expect(try v("1.0.0-beta.2") < v("1.0.0-beta.10"))
        #expect(try v("1.0.0-alpha") < v("1.0.0-beta"))
        #expect(try v("0.9.99") < v("1.0.0"))
        #expect(ToolVersion(tag: "rust-v0.63.0", prefix: "rust-v") == (try v("0.63.0")))
        #expect(ToolVersion(tag: "v0.63.0", prefix: "rust-v") == nil)
        #expect(ToolVersion("1.0.0/../x") == nil && ToolVersion("1.0") == nil && ToolVersion(" 1.0.0") == nil)
        #expect(ToolVersion("1.0.0-" + String(repeating: "a", count: 60)) == nil)
    }

    @Test func parsesNpmLatest() throws {
        #expect(ReleaseFeed.npmLatest(npmDoc)?.description == "2.1.330")
        #expect(ReleaseFeed.npmLatest(Data(#"{"name":"x"}"#.utf8)) == nil)
        #expect(ReleaseFeed.npmLatest(Data(#"{"version":"latest; rm -rf ~"}"#.utf8)) == nil)
        #expect(ReleaseFeed.npmLatest(Data("not json".utf8)) == nil)
    }

    @Test func parsesBrewFormulaAndCask() throws {
        #expect(ReleaseFeed.brewFormula(formulaDoc)?.description == "2.3.2")
        #expect(ReleaseFeed.brewCask(caskDoc)?.description == "2.1.323")
        #expect(ReleaseFeed.brewCask(Data(#"{"token":"copilot-cli","version":"1.0.108,abc123"}"#.utf8))?.description == "1.0.108")
        #expect(ReleaseFeed.brewCask(Data(#"{"token":"x","version":"latest"}"#.utf8)) == nil)
    }

    /// Tag and body only; drafts, prereleases and other prefixes are ignored. No link is read.
    @Test func parsesGithubRelease() throws {
        let release = try #require(ReleaseFeed.githubRelease(githubDoc(tag: "v2.1.312"), tagPrefix: "v"))
        #expect(release.version.description == "2.1.312" && release.notes == "## What's changed\n\n- Added a thing")
        #expect(ReleaseFeed.githubRelease(githubDoc(tag: "v2.1.312", draft: true), tagPrefix: "v") == nil)
        #expect(ReleaseFeed.githubRelease(githubDoc(tag: "v2.1.312", prerelease: true), tagPrefix: "v") == nil)
        #expect(ReleaseFeed.githubRelease(githubDoc(tag: "desktop-v2.1.312"), tagPrefix: "v") == nil)
        #expect(ReleaseFeed.githubRelease(githubDoc(tag: "rust-v0.171.0"), tagPrefix: "rust-v")?.version.description == "0.171.0")
        #expect(Mirror(reflecting: release).children.map(\.label) == ["version", "notes"])
    }

    @Test func topThreeChanges() throws {
        let body = """
        ## What's changed

        - Added sign-in to organizations: after `claude auth login`, Claude Code applies the **organization's** settings
          - a nested detail that is not a change
        * Fixed [a crash](https://github.com/x/y/pull/1) when resizing (#62106, #61888)
        * chore(release): bump version to 0.70.0-nightly by @gemini-cli-robot in https://github.com/google-gemini/gemini-cli/pull/30223
        * Changelog for v0.68.0 by @gemini-cli-robot in https://github.com/google-gemini/gemini-cli/pull/30224
        * fix(cli): preserve Unicode prompts by @someone in https://github.com/google-gemini/gemini-cli/pull/29915
        - \(String(repeating: "Long change ", count: 20))
        - A fifth change
        """
        let changes = ReleaseNotes.topChanges(body)
        #expect(changes.count == 3)
        #expect(changes[0] == "Added sign-in to organizations: after claude auth login, Claude Code applies the organization's settings")
        #expect(changes[1] == "Fixed a crash when resizing")
        #expect(changes[2] == "fix(cli): preserve Unicode prompts")
        let long = ReleaseNotes.topChanges("- " + String(repeating: "Long change ", count: 20))
        #expect(long.count == 1 && long[0].count == 120 && long[0].hasSuffix("…"))
        #expect(ReleaseNotes.topChanges("1. First\n2. Second", limit: 5) == ["First", "Second"])
    }

    /// Hostile bodies: lines that would make the cleanup regexes backtrack, invisible
    /// characters, piles of combining marks, a huge body. Bounded and quick.
    @Test func hostileNotes() {
        let start = Date()
        let spaces = "- a" + String(repeating: " ", count: 200_000) + "x"
        let brackets = "- " + String(repeating: "[", count: 200_000)
        let credit = "- a" + String(repeating: " by @x in", count: 30_000)
        let many = String(repeating: "- [a](b) `c` **d** (#1, #2)\n", count: 100_000)
        for body in [spaces, brackets, credit, many, String(repeating: "x", count: 5_000_000)] {
            #expect(ReleaseNotes.topChanges(body).allSatisfy { $0.unicodeScalars.count <= 120 })
        }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(ReleaseNotes.topChanges("- Fixed\u{1B}[31m red \u{202E}evil\u{200B} text") == ["Fixed [31m red evil text"])
        let marks = ReleaseNotes.topChanges("- " + String(repeating: "e\u{301}", count: 300))
        #expect(marks.count == 1 && marks[0].unicodeScalars.count <= 120)
        let padded = Data((#"{"version":"1.0.0","pad":""# + String(repeating: "x", count: ReleaseFeed.maxAnswer) + #""}"#).utf8)
        #expect(ReleaseFeed.npmLatest(padded) == nil)
        #expect(ReleaseFeed.npmLatest(Data(#"{"version":"1.0.0"}"#.utf8)) != nil)
    }

    @Test func emptyNotes() {
        #expect(ReleaseNotes.topChanges("") == [])
        #expect(ReleaseNotes.topChanges("## What's changed\n\n### Fixes\n") == [])
        #expect(ReleaseNotes.topChanges("2026-11-18\n\nFixes and changes") == [])
    }

    /// From the resolved binary path; a brew path only counts for the tool's own brew name.
    @Test func detectsInstallMethod() throws {
        let home = "/Users/me"
        let claude = try tool("Claude Code"), opencode = try tool("OpenCode"), gemini = try tool("Gemini CLI")
        #expect(claude.installMethod(path: "/opt/homebrew/Caskroom/claude-code/2.1.311/claude", home: home) == .brew)
        #expect(opencode.installMethod(path: "/opt/homebrew/Cellar/opencode/1.19.5/bin/opencode", home: home) == .brew)
        #expect(gemini.installMethod(path: "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js", home: home) == .npm)
        #expect(claude.installMethod(path: "/Users/me/.local/bin/claude", home: home) == .native)
        #expect(claude.installMethod(path: "/Users/me/.local/share/claude/versions/2.1.311", home: home) == .native)
        #expect(opencode.installMethod(path: "/Users/me/.opencode/bin/opencode", home: home) == .native)
        #expect(claude.installMethod(path: "/usr/local/bin/foo", home: home) == nil)
        // Wrong brew kind or name, bun and pnpm globals: unknown, so no command that installs a second copy.
        #expect(opencode.installMethod(path: "/opt/homebrew/Caskroom/opencode/1.0/opencode", home: home) == nil)
        #expect(claude.installMethod(path: "/opt/homebrew/Caskroom/other/1.0/claude", home: home) == nil)
        #expect(gemini.installMethod(path: "/Users/me/.bun/install/global/node_modules/@google/gemini-cli/dist/index.js", home: home) == nil)
        #expect(gemini.installMethod(path: "/Users/me/Library/pnpm/global/5/node_modules/@google/gemini-cli/dist/index.js", home: home) == nil)
        #expect(try tool("Codex CLI").installMethod(path: "/Users/me/.local/bin/codex", home: home) == nil)
        // Claude's old local install has its own node_modules: native, not npm.
        #expect(claude.installMethod(path: "/Users/me/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js", home: home) == .native)
        #expect(gemini.installMethod(path: "/Users/me/.config/yarn/global/node_modules/@google/gemini-cli/dist/index.js", home: home) == nil)
        #expect(gemini.installMethod(path: "/Users/me/.nvm/versions/node/v22.1.0/lib/node_modules/@google/gemini-cli/dist/index.js", home: home) == .npm)
        #expect(gemini.installMethod(path: "/opt/homebrew/lib/node_modules/other/node_modules/@google/gemini-cli/x.js", home: home) == nil)
    }

    /// The only strings 2c may type into Terminal.
    @Test func updateCommandsAreFixed() throws {
        let table: [String: [InstallMethod: String]] = [
            "Claude Code": [.npm: "npm install -g @anthropic-ai/claude-code@latest", .brew: "brew upgrade --cask claude-code", .native: "claude update"],
            "Copilot CLI": [.npm: "npm install -g @github/copilot@latest", .brew: "brew upgrade --cask copilot-cli", .native: "copilot update"],
            "Codex CLI": [.npm: "npm install -g @openai/codex@latest", .brew: "brew upgrade --cask codex"],
            "Gemini CLI": [.npm: "npm install -g @google/gemini-cli@latest", .brew: "brew upgrade gemini-cli"],
            "OpenCode": [.npm: "npm install -g opencode-ai@latest", .brew: "brew upgrade opencode", .native: "opencode upgrade"],
            "Antigravity CLI": [:],
        ]
        #expect(Set(table.keys) == Set(ReleaseTool.all.map(\.name)))
        for item in ReleaseTool.all {
            for method in InstallMethod.allCases {
                #expect(item.updateCommand(method) == table[item.name]?[method], "\(item.name) \(method)")
            }
        }
    }

    @Test func offersOnlyNewer() throws {
        let claude = try tool("Claude Code")
        let notes = "- One\n- Two\n- Three\n- Four"
        #expect(ReleaseRadar.update(tool: claude, installed: try v("2.1.330"), method: .npm, latest: try v("2.1.330"), notes: notes) == nil)
        #expect(ReleaseRadar.update(tool: claude, installed: try v("2.1.331"), method: .npm, latest: try v("2.1.330"), notes: notes) == nil)
        let update = try #require(ReleaseRadar.update(tool: claude, installed: try v("2.1.311"), method: .brew, latest: try v("2.1.323"), notes: notes))
        #expect(update == ReleaseUpdate(toolID: "claude", name: "Claude Code", installed: try v("2.1.311"), latest: try v("2.1.323"),
                                        changes: ["One", "Two", "Three"], command: "brew upgrade --cask claude-code"))
        // No notes: still offered, without changes. A prerelease latest is never offered.
        #expect(ReleaseRadar.update(tool: claude, installed: try v("2.1.311"), method: .npm, latest: try v("2.1.323"), notes: nil)?.changes == [])
        #expect(ReleaseRadar.update(tool: claude, installed: try v("2.1.311"), method: .npm, latest: try v("2.2.0-beta.1"), notes: nil) == nil)
        // A skipped tool or a channel without a feed is never offered.
        #expect(ReleaseRadar.update(tool: try tool("Antigravity CLI"), installed: try v("1.5.3"), method: .native, latest: try v("9.0.0"), notes: nil) == nil)
    }

    /// The version to compare comes from the install's own channel, so the command installs what was offered.
    @Test func usesInstallChannel() throws {
        let opencode = try tool("OpenCode")
        #expect(opencode.versionURL(for: .brew)?.absoluteString == "https://formulae.brew.sh/api/formula/opencode.json")
        #expect(opencode.versionURL(for: .npm)?.absoluteString == "https://registry.npmjs.org/opencode-ai/latest")
        #expect(opencode.versionURL(for: .native)?.absoluteString == "https://api.github.com/repos/anomalyco/opencode/releases/latest")
        #expect(try tool("Claude Code").versionURL(for: .brew)?.absoluteString == "https://formulae.brew.sh/api/cask/claude-code.json")
        #expect(try tool("Codex CLI").versionURL(for: .native) == nil)
        #expect(opencode.latest(from: formulaDoc, method: .brew)?.description == "2.3.2")
        #expect(try tool("Claude Code").latest(from: npmDoc, method: .npm)?.description == "2.1.330")
        #expect(opencode.latest(from: githubDoc(tag: "v1.19.6"), method: .native)?.description == "1.19.6")
    }

    @Test func feedURLsUseAllowedHostsOnly() throws {
        var urls: [URL] = []
        for item in ReleaseTool.all {
            for method in InstallMethod.allCases { urls += [item.versionURL(for: method)].compactMap { $0 } }
            urls += [item.notesURL(version: try v("1.2.3-beta.1"))].compactMap { $0 }
        }
        #expect(urls.count == 18)
        for url in urls {
            #expect(url.scheme == "https" && ReleaseFeed.allowedHosts.contains(url.host ?? ""), "\(url)")
            #expect(url.query == nil && url.fragment == nil && url.user == nil && url.port == nil)
        }
        #expect(ReleaseFeed.allowedHosts == ["registry.npmjs.org", "api.github.com", "formulae.brew.sh"])
        #expect(try tool("Claude Code").versionURL(for: .npm)?.absoluteString == "https://registry.npmjs.org/@anthropic-ai%2Fclaude-code/latest")
        #expect(try tool("Codex CLI").notesURL(version: try v("0.171.0"))?.absoluteString
                == "https://api.github.com/repos/openai/codex/releases/tags/rust-v0.171.0")
        #expect(ReleaseFeed.url("https://example.com/x") == nil && ReleaseFeed.url("http://api.github.com/x") == nil)
    }
}

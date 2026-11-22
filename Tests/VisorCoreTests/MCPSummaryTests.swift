import Foundation
import Testing
@testable import VisorCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// A finished tool call from `provider` in `cwd`.
private func call(_ tool: String, failed: Bool = false, cwd: String = "/Users/me/web-shop", provider: String = "claude") -> HookMessage {
    let key = provider == "copilot" ? "toolName" : "tool_name"
    let session = provider == "copilot" ? "sessionId" : "session_id"
    return hook(failed ? "PostToolUseFailure" : "PostToolUse", provider: provider,
                #"{"\#(session)":"s1","cwd":"\#(cwd)","\#(key)":"\#(tool)"}"#)
}

private func ref(_ name: String, _ agent: String = "Claude Code") -> MCPServerRef {
    MCPServerRef(agent: agent, scope: .global, name: name)
}

/// The summary for `configured` servers after `calls`, all at `now` minus their index in seconds.
private func summary(_ configured: [MCPServerRef], _ calls: [HookMessage]) -> MCPSummary? {
    var stats = MCPStats()
    let names = Set(configured.map(\.name))
    for (i, message) in calls.enumerated() { stats.record(message, configured: names, at: now - Double(calls.count - i)) }
    return MCPSummary.make(health: stats.health(configured: configured, now: now), failures: stats.failureSummary(now: now))
}

@Suite("MCP summary")
struct MCPSummaryTests {
    @Test func lineNamesWorstFailure() throws {
        let configured = [ref("figma"), ref("api-docs"), ref("acme-docs"), ref("playwright")]
        let calls = [call("mcp__figma__get_screenshot", failed: true), call("mcp__figma__get_screenshot", failed: true),
                     call("mcp__figma__get_screenshot", failed: true),
                     call("mcp__api-docs__search", failed: true, cwd: "/Users/me/api"),
                     call("mcp__acme-docs__search")]
        let s = try #require(summary(configured, calls))
        #expect(s.count == 4)
        #expect(s.failing)
        #expect(s.detail == "figma failed 3x in web-shop")
        #expect(s.line == "MCP 4 · figma failed 3x in web-shop")
    }

    @Test func lineWithoutFailures() throws {
        let all = try #require(summary([ref("figma"), ref("acme-docs")], [call("mcp__figma__x"), call("mcp__acme-docs__y")]))
        #expect(all.line == "MCP 2 · all working")
        #expect(!all.failing)
        let some = try #require(summary([ref("figma"), ref("acme-docs"), ref("playwright"), ref("octocat-tracker")],
                                        [call("mcp__figma__x"), call("mcp__acme-docs__y")]))
        #expect(some.line == "MCP 4 · 2 working, 2 configured")
    }

    @Test func lineWhenNothingSeen() throws {
        let s = try #require(summary([ref("figma"), ref("acme-docs"), ref("playwright")], []))
        #expect(s.count == 3)
        #expect(s.line == "MCP 3 configured")
        #expect(!s.failing)
    }

    @Test func hiddenWhenNoServers() {
        #expect(summary([], []) == nil)
        #expect(summary([], [call("Bash")]) == nil)
    }

    @Test func rowsCarryAgentsStateTools() throws {
        let configured = [ref("figma"), ref("acme-docs"), ref("acme-docs", "Copilot CLI"), ref("playwright")]
        let calls = [call("mcp__figma__get_metadata"), call("mcp__figma__get_screenshot"), call("mcp__figma__get_screenshot"),
                     call("mcp__figma__get_design_context"), call("mcp__figma__get_design_context"), call("mcp__figma__get_design_context"),
                     call("mcp__figma__whoami"),
                     call("mcp__figma__get_screenshot", failed: true), call("mcp__figma__get_screenshot", failed: true),
                     call("mcp__figma__get_screenshot", failed: true),
                     call("acme-docs-get_page", provider: "copilot"),
                     call("mcp__unlisted__x", failed: true, cwd: ""), call("mcp__unlisted__x", failed: true, cwd: "")]
        let s = try #require(summary(configured, calls))
        let figma = try #require(s.rows.first { $0.server == "figma" })
        #expect(figma.stateText == "failed 3x in web-shop")
        #expect(figma.tools == ["get_screenshot", "get_design_context", "get_metadata"])
        #expect(figma.agents == ["Claude Code"])
        let docs = try #require(s.rows.first { $0.server == "acme-docs" })
        #expect(docs.agents == ["Claude Code", "Copilot CLI"])
        #expect(docs.stateText == "working")
        #expect(docs.tools == ["get_page"])
        let playwright = try #require(s.rows.first { $0.server == "playwright" })
        #expect(playwright.tools.isEmpty)
        #expect(playwright.stateText == "configured")
        // Seen only in events, with no known project.
        let unlisted = try #require(s.rows.first { $0.server == "unlisted" })
        #expect(unlisted.stateText == "failed 2x")
        #expect(unlisted.agents == ["Claude Code"])
    }

    @Test func rowsOrderedFailingWorkingConfigured() throws {
        let configured = ["b-conf", "a-conf", "d-work", "c-work", "f-fail", "e-fail"].map { ref($0) }
        let calls = [call("mcp__d-work__x"), call("mcp__c-work__x"),
                     call("mcp__f-fail__x", failed: true), call("mcp__e-fail__x", failed: true)]
        let s = try #require(summary(configured, calls))
        #expect(s.rows.map(\.server) == ["e-fail", "f-fail", "c-work", "d-work", "a-conf", "b-conf"])
    }

    @Test func rowsCappedWithMore() throws {
        let s = try #require(summary((1...9).map { ref("server-\($0)") }, []))
        #expect(s.rows.count == MCPSummary.maxRows)
        #expect(s.rows.count == 6)
        #expect(s.more == 3)
        #expect(s.count == 9)
    }

    @Test func fileAgentServersStayConfigured() throws {
        let configured = [ref("octocat-tracker", "Codex CLI"), ref("figma"), ref("acme-docs", "OpenCode")]
        let calls = [call("mcp__figma__x", failed: true), call("mcp__figma__x", failed: true)]
        let s = try #require(summary(configured, calls))
        let tracker = try #require(s.rows.first { $0.server == "octocat-tracker" })
        #expect(tracker.state == .configured)
        #expect(tracker.stateText == "configured")
        #expect(tracker.agents == ["Codex CLI"])
        #expect(s.rows.first { $0.server == "acme-docs" }?.stateText == "configured")
        let texts = s.rows.map(\.stateText) + [s.line, s.detail]
        #expect(!texts.contains { $0.localizedCaseInsensitiveContains("disconnected") })
    }

    @Test func sameOrderCallsGiveEqualSummary() {
        let configured = [ref("figma")]
        let two = [call("mcp__figma__a"), call("mcp__figma__a"), call("mcp__figma__b")]
        let five = two + [call("mcp__figma__a"), call("mcp__figma__a")]
        #expect(summary(configured, two) == summary(configured, five))
        let overtaken = two + [call("mcp__figma__b"), call("mcp__figma__b")]
        #expect(summary(configured, two) != summary(configured, overtaken))
    }

    @Test func listHeightMatchesRows() throws {
        let three = try #require(summary([ref("a"), ref("b"), ref("c")], []))
        let top: Double = 12 + 16  // padding and header
        #expect(three.listHeight == top + 3 * 28)
        let nine = try #require(summary((1...9).map { ref("s\($0)") }, []))
        #expect(nine.listHeight == top + 6 * 28 + 16)  // six rows and "+3 more"
    }

    @Test func pathsCoverEveryFileRead() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("visor-mcp-\(UUID().uuidString)")
        let project = home.appendingPathComponent("acme-web").path
        let files = [".claude.json", ".copilot/mcp-config.json", ".codex/config.toml", ".gemini/settings.json",
                     ".gemini/config/mcp_config.json", ".config/opencode/opencode.json", ".config/opencode/opencode.jsonc"]
            .map { home.appendingPathComponent($0).path }
            + [".mcp.json", ".gemini/settings.json", "opencode.json", "opencode.jsonc"].map { (project as NSString).appendingPathComponent($0) }
        for (i, path) in files.enumerated() {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let text = path.hasSuffix(".toml") ? "[mcp_servers.s\(i)]\n"
                : path.contains("opencode") ? #"{"mcp": {"s\#(i)": {}}}"# : #"{"mcpServers": {"s\#(i)": {}}}"#
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
        // Every file holds its own server, so every file is read.
        #expect(MCPConfig.read(home: home, projects: [project]).count == 11)
        let paths = Set(MCPConfig.paths(home: home, projects: [project]))
        for path in files { #expect(paths.contains(path), "\(path)") }
    }

    @Test func stampChangesWhenFileChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("visor-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("a.json").path, b = folder.appendingPathComponent("b.json").path
        FileManager.default.createFile(atPath: a, contents: Data("{}".utf8))
        let first = MCPConfigStamp.of(paths: [a, b])
        #expect(first == MCPConfigStamp.of(paths: [a, b]))
        #expect(first.entries[b] == nil)
        FileManager.default.createFile(atPath: a, contents: Data(#"{"mcpServers": {}}"#.utf8))
        let rewritten = MCPConfigStamp.of(paths: [a, b])
        #expect(rewritten != first)
        FileManager.default.createFile(atPath: b, contents: Data("{}".utf8))
        #expect(MCPConfigStamp.of(paths: [a, b]) != rewritten)
    }
}

@Suite("MCP gate fixes")
struct MCPGateFixTests {
    @Test func projectFoldersSkipProtectedAndOutsideHome() {
        let cwds = ["/Users/me/acme-web", "/Users/me/Documents/shop", "/Users/me/Desktop", "/Users/me/Downloads/x",
                    "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/p", "/Volumes/ext/p", "/net/host/p",
                    "/Network/p", "/Users/other/p", "/Users/meow/p", "/Users/me", "relative/p", "/Users/me/acme-web"]
        #expect(MCPConfig.projectFolders(cwds, home: "/Users/me") == ["/Users/me", "/Users/me/acme-web"])
    }

    @Test func projectFoldersKeepTheMostRecent() {
        // Most recent first: the 64 newest stay, whatever their names.
        let cwds = (0..<70).map { "/Users/me/p\(String(format: "%02d", 69 - $0))" }
        let kept = MCPConfig.projectFolders(cwds, home: "/Users/me")
        #expect(kept.count == MCPConfig.maxProjects)
        #expect(kept.contains("/Users/me/p69") && !kept.contains("/Users/me/p00"))
    }

    @Test func readSkipsProtectedProjectFolders() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("visor-mcp-\(UUID().uuidString)")
        let shop = home.appendingPathComponent("Documents/shop")
        try? FileManager.default.createDirectory(at: shop, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: shop.appendingPathComponent(".mcp.json").path, contents: Data(#"{"mcpServers": {"figma": {}}}"#.utf8))
        #expect(MCPConfig.read(home: home, projects: [shop.path]).isEmpty)
        #expect(!MCPConfig.paths(home: home, projects: [shop.path]).contains { $0.hasPrefix(shop.path) })
    }

    @Test func rejectsFormatCharactersInNames() {
        #expect(!MCPConfig.isValidName("evil\u{202E}txt.exe"))
        #expect(!MCPConfig.isValidName("fig\u{200B}ma"))
        #expect(MCPConfig.isValidName("acme-docs"))
    }

    @Test func longProjectNamesAreShortened() throws {
        let long = String(repeating: "a", count: 30) + "-middle-" + String(repeating: "z", count: 30)
        let s = try #require(summary([ref("figma")], [call("mcp__figma__x", failed: true, cwd: "/Users/me/" + long)]))
        let text = try #require(s.rows.first?.stateText)
        #expect(text.hasPrefix("failed 1x in aaaa"))
        #expect(text.hasSuffix("zzzz"))
        #expect(text.contains("…"))
        #expect(text.count <= "failed 1x in ".count + MCPSummary.maxProjectLength)
    }

    /// A name configured only by a file agent but called (and failing) through Claude Code:
    /// the failure is real and the row shows both marks, so it is not "known only from file-agent configs".
    @Test func sharedNameShowsTheCallingAgent() throws {
        let s = try #require(summary([ref("octocat-tracker", "Codex CLI")],
                                     [call("mcp__octocat-tracker__x", failed: true), call("mcp__octocat-tracker__x", failed: true)]))
        let row = try #require(s.rows.first)
        #expect(row.agents == ["Claude Code", "Codex CLI"])
        #expect(row.stateText == "failed 2x in web-shop")
    }
}

@Suite("MCP refresh")
struct MCPRefreshTests {
    @Test func launchReadsOnceThenOnlyStats() {
        var refresh = MCPRefresh()
        refresh.want(folders: ["/Users/me/web-shop"])
        let step1 = refresh.request()
        #expect(step1 == .check(folders: ["/Users/me/web-shop"], last: nil))
        // start() asks while the first read runs: queued, not a second forced read.
        let step2 = refresh.request()
        #expect(step2 == nil)
        let stamp = MCPConfigStamp(entries: ["/Users/me/.claude.json": .init(size: 10, seconds: 1, nanoseconds: 0)])
        let step3 = refresh.finished(folders: ["/Users/me/web-shop"], stamp: stamp)
        #expect(step3 == .check(folders: ["/Users/me/web-shop"], last: stamp))
        let step4 = refresh.finished(folders: ["/Users/me/web-shop"], stamp: stamp)
        #expect(step4 == nil)
    }

    @Test func newFoldersForceARead() {
        var refresh = MCPRefresh()
        let stamp = MCPConfigStamp()
        refresh.want(folders: ["/Users/me/a"])
        _ = refresh.request()
        _ = refresh.finished(folders: ["/Users/me/a"], stamp: stamp)
        let step5 = refresh.request()
        #expect(step5 == .check(folders: ["/Users/me/a"], last: stamp))
        _ = refresh.finished(folders: ["/Users/me/a"], stamp: stamp)
        let step6 = refresh.want(folders: ["/Users/me/a", "/Users/me/b"])
        #expect(step6)
        let step7 = !refresh.want(folders: ["/Users/me/a", "/Users/me/b"])
        #expect(step7)
        let step8 = refresh.request()
        #expect(step8 == .check(folders: ["/Users/me/a", "/Users/me/b"], last: nil))
    }

    @Test func foldersChangedDuringAReadForceTheNext() {
        var refresh = MCPRefresh()
        refresh.want(folders: ["/Users/me/a"])
        _ = refresh.request()
        refresh.want(folders: ["/Users/me/b"])
        let step9 = refresh.request()
        #expect(step9 == nil)
        let step10 = refresh.finished(folders: ["/Users/me/a"], stamp: MCPConfigStamp())
        #expect(step10 == .check(folders: ["/Users/me/b"], last: nil))
    }
}

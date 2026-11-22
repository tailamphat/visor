import Foundation
import Testing
@testable import VisorCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A tool hook event for `tool` in `cwd`.
private func toolEvent(_ event: String, _ tool: String, cwd: String = "/Users/me/web-shop",
                       provider: String = "claude", extra: String = "") -> HookMessage {
    let key = provider == "copilot" ? "toolName" : "tool_name"
    let session = provider == "copilot" ? "sessionId" : "session_id"
    return hook(event, provider: provider, #"{"\#(session)":"s1","cwd":"\#(cwd)","\#(key)":"\#(tool)"\#(extra)}"#)
}

@Suite("MCP stats")
struct MCPStatsTests {
    @Test func parsesClaudeToolNames() {
        #expect(MCPTool.parse("mcp__figma__get_screenshot", provider: "claude") == MCPTool(server: "figma", tool: "get_screenshot"))
        #expect(MCPTool.parse("mcp__claude_ai_Figma__x", provider: "claude") == MCPTool(server: "claude_ai_Figma", tool: "x"))
        #expect(MCPTool.parse("mcp__acme-docs__search__deep", provider: "antigravity") == MCPTool(server: "acme-docs", tool: "search__deep"))
        #expect(MCPTool.parse("mcp__bad", provider: "claude") == nil)
        #expect(MCPTool.parse("mcp____x", provider: "claude") == nil)
        #expect(MCPTool.parse("mcp__figma__", provider: "claude") == nil)
    }

    @Test func parsesCopilotToolNamesAgainstConfig() {
        let configured: Set<String> = ["mcp-acme", "mcp"]
        #expect(MCPTool.parse("mcp-acme-confluence_get_page", provider: "copilot", configured: configured)
            == MCPTool(server: "mcp-acme", tool: "confluence_get_page"))
        #expect(MCPTool.parse("mcp-search", provider: "copilot", configured: configured) == MCPTool(server: "mcp", tool: "search"))
        #expect(MCPTool.parse("postman-getUser", provider: "copilot", configured: configured) == nil)
        #expect(MCPTool.parse("mcp__figma__x", provider: "copilot") == MCPTool(server: "figma", tool: "x"))
        // Copilot's dashed names only count for Copilot.
        #expect(MCPTool.parse("mcp-acme-x", provider: "claude", configured: configured) == nil)
    }

    @Test func ignoresBuiltInTools() {
        var stats = MCPStats()
        for tool in ["Bash", "Read", "Task"] {
            let changed = stats.record(toolEvent("PostToolUse", tool), at: t0)
            #expect(!changed)
        }
        #expect(stats == MCPStats())
    }

    @Test func postToolUseMarksWorking() throws {
        var stats = MCPStats()
        let changed = stats.record(toolEvent("PostToolUse", "mcp__figma__get_screenshot"), at: t0)
        #expect(changed)
        let figma = try #require(stats.servers["figma"])
        #expect(figma.lastWorking == t0 && figma.lastFailed == nil)
        #expect(figma.tools == ["get_screenshot": 1])
        #expect(figma.projects["/Users/me/web-shop"]?.calls == 1)
    }

    @Test func failureCountsPerProject() throws {
        var stats = MCPStats()
        for i in 0..<3 {
            stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x"), at: t0 + Double(i))
        }
        stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x", cwd: "/Users/me/api"), at: t0)
        let figma = try #require(stats.servers["figma"])
        #expect(figma.failures(in: "/Users/me/web-shop", now: t0 + 10) == 3)
        #expect(figma.failures(in: "/Users/me/api", now: t0 + 10) == 1)
        #expect(figma.tools["x"] == 4 && figma.lastWorking == nil)
    }

    @Test func preToolUseIsIgnored() {
        var stats = MCPStats()
        let changed = stats.record(toolEvent("PreToolUse", "mcp__figma__x"), at: t0)
        #expect(!changed)
        #expect(stats.servers.isEmpty)
    }

    @Test func failuresOutsideWindowDropOut() throws {
        var stats = MCPStats()
        let now = t0 + 25 * 3600
        stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x"), at: t0)
        stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x"), at: now - 3600)
        let figma = try #require(stats.servers["figma"])
        #expect(figma.failures(in: "/Users/me/web-shop", now: now) == 1)
        #expect(figma.failures(now: now) == 1)
    }

    @Test func failureSummaryNamesProject() {
        var stats = MCPStats()
        for i in 0..<3 { stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x"), at: t0 + Double(i)) }
        stats.record(toolEvent("PostToolUseFailure", "mcp__acme-docs__x", cwd: "/Users/me/api"), at: t0)
        let summary = stats.failureSummary(now: t0 + 60)
        #expect(summary.first == MCPFailure(server: "figma", count: 3, project: "web-shop"))
        #expect(summary.count == 2)
    }

    @Test func topToolsSortedByCount() {
        var stats = MCPStats()
        for (tool, count) in [("d", 1), ("c", 2), ("b", 2), ("a", 5)] {
            for _ in 0..<count { stats.record(toolEvent("PostToolUse", "mcp__figma__\(tool)"), at: t0) }
        }
        #expect(stats.topTools(server: "figma") == [MCPToolCount(tool: "a", calls: 5), MCPToolCount(tool: "b", calls: 2),
                                                    MCPToolCount(tool: "c", calls: 2)])
        #expect(stats.topTools(server: "none").isEmpty)
    }

    @Test func healthJoinsConfigAndStats() {
        var stats = MCPStats()
        stats.record(toolEvent("PostToolUse", "mcp__acme-docs__x"), at: t0)
        stats.record(toolEvent("PostToolUse", "mcp__figma__x"), at: t0)
        stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x"), at: t0 + 1)
        stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x"), at: t0 + 2)
        stats.record(toolEvent("PostToolUse", "mcp__claude_ai_Figma__x"), at: t0)
        let configured = [
            MCPServerRef(agent: "Claude Code", scope: .global, name: "figma"),
            MCPServerRef(agent: "Claude Code", scope: .global, name: "acme-docs"),
            MCPServerRef(agent: "Codex CLI", scope: .global, name: "octocat-tracker"),
        ]
        let health = Dictionary(uniqueKeysWithValues: stats.health(configured: configured, now: t0 + 60).map { ($0.server, $0) })
        #expect(health["octocat-tracker"]?.state == .configured)
        #expect(health["octocat-tracker"]?.agents == ["Codex CLI"])
        #expect(health["acme-docs"]?.state == .working)
        #expect(health["figma"]?.state == .failing(2))
        #expect(health["claude_ai_Figma"]?.state == .working)
        #expect(health["claude_ai_Figma"]?.configured == false)
        #expect(health["figma"]?.configured == true)
    }

    @Test func capsServersToolsProjects() throws {
        var stats = MCPStats()
        for i in 0..<40 { stats.record(toolEvent("PostToolUse", "mcp__s\(i)__x"), at: t0 + Double(i)) }
        #expect(stats.servers.count == MCPStats.maxServers)
        #expect(stats.servers["s0"] == nil && stats.servers["s39"] != nil)

        for _ in 0..<5 { stats.record(toolEvent("PostToolUse", "mcp__s39__hot"), at: t0 + 99) }
        for i in 0..<20 { stats.record(toolEvent("PostToolUse", "mcp__s39__t\(i)"), at: t0 + 100) }
        #expect(try #require(stats.servers["s39"]).tools.count == MCPStats.maxTools)
        #expect(stats.servers["s39"]?.tools["hot"] == 5)

        for i in 0..<20 { stats.record(toolEvent("PostToolUse", "mcp__s39__x", cwd: "/Users/me/p\(i)"), at: t0 + 200 + Double(i)) }
        let s39 = try #require(stats.servers["s39"])
        #expect(s39.projects.count == MCPStats.maxProjects)
        #expect(s39.projects["/Users/me/p19"] != nil)

        for i in 0..<25 { stats.record(toolEvent("PostToolUseFailure", "mcp__s39__x"), at: t0 + 300 + Double(i)) }
        let shop = try #require(stats.servers["s39"]?.projects["/Users/me/web-shop"])
        #expect(shop.failedAt.count == MCPStats.maxFailures)
        #expect(shop.failedAt.first == t0 + 305 && shop.failedAt.last == t0 + 324)
    }

    @Test func storesNoPayloadValues() {
        var stats = MCPStats()
        let extra = #","tool_input":{"query":"SECRET-MARKER"},"tool_response":{"text":"SECRET-MARKER"},"error":"SECRET-MARKER""#
        stats.record(toolEvent("PostToolUse", "mcp__figma__x", extra: extra), at: t0)
        stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x", extra: extra), at: t0)
        #expect(!String(describing: stats).contains("SECRET-MARKER"))
        #expect(!String(reflecting: stats).contains("SECRET-MARKER"))
    }

    @Test func joinsClaudeSanitisedNames() {
        var stats = MCPStats()
        stats.record(toolEvent("PostToolUse", "mcp__acme_docs__search"), at: t0)
        stats.record(toolEvent("PostToolUse", "mcp__claude_ai_Acme_Docs__x"), at: t0)
        let configured = [MCPServerRef(agent: "Claude Code", scope: .global, name: "acme.docs"),
                          MCPServerRef(agent: "Codex CLI", scope: .global, name: "claude.ai Acme Docs")]
        let health = stats.health(configured: configured, now: t0 + 60)
        #expect(health.map(\.server) == ["acme.docs", "claude.ai Acme Docs"])
        #expect(health.allSatisfy { $0.state == .working && $0.configured })
        #expect(health.first?.topTools == [MCPToolCount(tool: "search", calls: 1)])
    }

    @Test func oldFailureLastIsConfiguredNotWorking() {
        var stats = MCPStats()
        stats.record(toolEvent("PostToolUse", "mcp__figma__x"), at: t0)
        stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x"), at: t0 + 1)
        let health = stats.health(configured: [], now: t0 + 2 * MCPStats.window)
        #expect(health.first?.state == .configured)
    }

    @Test func doubleUnderscoreNamesUseConfiguredServers() {
        #expect(MCPTool.parse("mcp__acme__docs__search", provider: "claude", configured: ["acme__docs"])
            == MCPTool(server: "acme__docs", tool: "search"))
        #expect(MCPTool.parse("mcp__acme__docs__search", provider: "claude") == MCPTool(server: "acme", tool: "docs__search"))
        // Configured names are matched after Claude's sanitising.
        #expect(MCPTool.parse("mcp__acme_x__docs__search", provider: "claude", configured: ["acme.x__docs"])
            == MCPTool(server: "acme_x__docs", tool: "search"))
    }

    @Test func summarySkipsUnknownProject() {
        var stats = MCPStats()
        stats.record(hook("PostToolUseFailure", #"{"session_id":"s1","tool_name":"mcp__figma__x"}"#), at: t0)
        stats.record(toolEvent("PostToolUseFailure", "mcp__figma__x"), at: t0)
        #expect(stats.failureSummary(now: t0 + 1) == [MCPFailure(server: "figma", count: 1, project: "web-shop")])
    }

    @Test func badCwdIsStoredAsUnknown() {
        var stats = MCPStats()
        let long = "/" + String(repeating: "a", count: 1100)
        for cwd in ["relative/path", long, "/Users/me/evil\\u202Eppa", "/Users/me/a\\nb"] {
            stats.record(toolEvent("PostToolUse", "mcp__figma__x", cwd: cwd), at: t0)
        }
        #expect(stats.servers["figma"].map { Array($0.projects.keys) } == [""])
    }
}

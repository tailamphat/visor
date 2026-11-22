import Foundation
import Testing
@testable import VisorCore

/// A throwaway home folder with config files written into it.
private struct FakeHome {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("visor-mcp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes `text` at `path`, relative to the home unless it starts with "/".
    func write(_ path: String, _ text: String) {
        writeData(path, Data(text.utf8))
    }

    func writeData(_ path: String, _ data: Data) {
        let file = file(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
    }

    func file(_ path: String) -> URL { url.appendingPathComponent(path) }

    /// A project folder inside the fake home.
    func project(_ name: String) -> String { url.appendingPathComponent(name).path }
}

private func names(_ refs: [MCPServerRef], agent: String, scope: MCPServerRef.Scope? = nil) -> [String] {
    refs.filter { $0.agent == agent && (scope == nil || $0.scope == scope) }.map(\.name).sorted()
}

@Suite("MCP config")
struct MCPConfigTests {
    @Test func claudeGlobalAndProject() {
        let home = FakeHome()
        let web = "/Users/me/acme-web"
        home.write(".claude.json", """
        {"numStartups": 3,
         "mcpServers": {"figma": {"type": "http", "url": "https://example.com/mcp"},
                        "acme-docs": {"command": "npx", "args": ["acme-docs"]}},
         "projects": {"\(web)": {"mcpServers": {"octocat-tracker": {"command": "tracker"}}},
                      "/Users/me/empty": {"allowedTools": []}}}
        """)
        let refs = MCPConfig.read(home: home.url, projects: [])
        #expect(names(refs, agent: "Claude Code", scope: .global) == ["acme-docs", "figma"])
        #expect(names(refs, agent: "Claude Code", scope: .project(web)) == ["octocat-tracker"])
        #expect(refs.count == 3)
    }

    @Test func claudeMcpJsonHonoursDisabled() {
        let home = FakeHome()
        let shop = home.project("web-shop")
        home.write("web-shop/.mcp.json", #"{"mcpServers": {"acme-docs": {"command": "a"}, "figma": {"command": "b"}}}"#)
        home.write(".claude.json", #"{"projects": {"\#(shop)": {"disabledMcpjsonServers": ["figma"]}}}"#)
        let refs = MCPConfig.read(home: home.url, projects: [shop])
        #expect(names(refs, agent: "Claude Code", scope: .project(shop)) == ["acme-docs"])
    }

    @Test func copilotServers() {
        let home = FakeHome()
        home.write(".copilot/mcp-config.json", """
        {"mcpServers": {"mcp-acme": {"type": "local", "command": "x", "tools": ["*"]}, "octocat-tracker": {"type": "http"}}}
        """)
        let refs = MCPConfig.read(home: home.url, projects: [])
        #expect(names(refs, agent: "Copilot CLI", scope: .global) == ["mcp-acme", "octocat-tracker"])
    }

    @Test func codexTomlHeadersOnly() {
        let home = FakeHome()
        home.write(".codex/config.toml", """
        model = "gpt-5"
        x = "[mcp_servers.fake]"

        [mcp_servers.figma]
        command = "npx"

        [mcp_servers.figma.env]
        TOKEN = "abc"

        [mcp_servers."acme docs"]
        url = "https://example.com"

        [profiles.x]
        model = "o3"
        """)
        let refs = MCPConfig.read(home: home.url, projects: [])
        #expect(names(refs, agent: "Codex CLI", scope: .global) == ["acme docs", "figma"])
    }

    @Test func geminiGlobalAndProject() {
        let home = FakeHome()
        let api = home.project("api")
        home.write(".gemini/settings.json", #"{"theme": "dark", "mcpServers": {"figma": {"httpUrl": "https://x"}}}"#)
        home.write("api/.gemini/settings.json", #"{"mcpServers": {"acme-docs": {"command": "a"}}}"#)
        let refs = MCPConfig.read(home: home.url, projects: [api])
        #expect(names(refs, agent: "Gemini CLI", scope: .global) == ["figma"])
        #expect(names(refs, agent: "Gemini CLI", scope: .project(api)) == ["acme-docs"])
    }

    @Test func antigravityEmptyFileIsNone() {
        let home = FakeHome()
        home.write(".gemini/config/mcp_config.json", "")
        #expect(names(MCPConfig.read(home: home.url, projects: []), agent: "Antigravity").isEmpty)
        home.write(".gemini/config/mcp_config.json", #"{"mcpServers": {"octocat-tracker": {"command": "t"}}}"#)
        #expect(names(MCPConfig.read(home: home.url, projects: []), agent: "Antigravity") == ["octocat-tracker"])
    }

    @Test func openCodeJsonc() {
        let home = FakeHome()
        let api = home.project("api")
        home.write(".config/opencode/opencode.jsonc", """
        {
          // my servers
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "figma": {"type": "remote", "url": "https://x"},
          },
        }
        """)
        home.write("api/opencode.json", #"{"mcp": {"acme-docs": {"type": "local", "command": ["a"]}}}"#)
        let refs = MCPConfig.read(home: home.url, projects: [api])
        #expect(names(refs, agent: "OpenCode", scope: .global) == ["figma"])
        #expect(names(refs, agent: "OpenCode", scope: .project(api)) == ["acme-docs"])
    }

    @Test func resultHoldsNamesOnly() {
        let home = FakeHome()
        let secret = #"{"command": "SECRET-MARKER", "args": ["SECRET-MARKER"], "env": {"K": "SECRET-MARKER"}, "headers": {"Authorization": "SECRET-MARKER"}, "url": "https://SECRET-MARKER"}"#
        home.write(".claude.json", #"{"mcpServers": {"figma": \#(secret)}, "oauthAccount": {"token": "SECRET-MARKER"}}"#)
        home.write(".copilot/mcp-config.json", #"{"mcpServers": {"figma": \#(secret)}}"#)
        home.write(".gemini/settings.json", #"{"mcpServers": {"figma": \#(secret)}}"#)
        home.write(".codex/config.toml", "[mcp_servers.figma]\ncommand = \"SECRET-MARKER\"\n[mcp_servers.figma.env]\nK = \"SECRET-MARKER\"\n")
        let refs = MCPConfig.read(home: home.url, projects: [])
        #expect(refs.count == 4)
        #expect(!String(describing: refs).contains("SECRET-MARKER"))
        #expect(!String(reflecting: refs).contains("SECRET-MARKER"))
    }

    @Test func oversizeAndMalformedFilesGiveNothing() {
        let home = FakeHome()
        var big = Data(#"{"mcpServers": {"figma": {}}, "pad": ""#.utf8)
        big.append(Data(repeating: UInt8(ascii: "a"), count: MCPConfig.maxFileSize))
        big.append(Data(#""}"#.utf8))
        home.writeData(".claude.json", big)
        home.write(".copilot/mcp-config.json", #"{"mcpServers": {"figma": {"#)
        home.write(".gemini/settings.json", #"{"mcpServers": {"acme-docs": {}}}"#)
        let refs = MCPConfig.read(home: home.url, projects: [])
        #expect(refs.map(\.agent) == ["Gemini CLI"])
        #expect(refs.map(\.name) == ["acme-docs"])
    }

    @Test func rejectsBadNames() {
        let long = String(repeating: "a", count: 65)
        let ok = String(repeating: "b", count: 64)
        let data = Data(#"{"mcpServers": {"\#(long)": {}, "bad\nname": {}, "\#(ok)": {}, "": {}}}"#.utf8)
        #expect(MCPConfig.serverNames(data, key: "mcpServers") == [ok])
    }

    @Test func codexTomlOtherForms() {
        let data = Data("""
        notes = \"\"\"
        [mcp_servers.inside_string]
        \"\"\"
        mcp_servers.root-one.command = "x"
        [ mcp_servers . spaced ]
        command = "y"
        [mcp_servers]
        inline = { command = "z" }
        dotted.command = "w"
        "quoted key".url = "https://x"
        [other]
        not_a_server = 1
        """.utf8)
        #expect(MCPConfig.codexTOML(data) == ["dotted", "inline", "quoted key", "root-one", "spaced"])
    }

    @Test func codexTomlLongLineIsFast() {
        var line = "[mcp_servers.a." + String(repeating: " ", count: 1_000_000)
        line += "\n[mcp_servers.figma]\n"
        let start = Date()
        #expect(MCPConfig.codexTOML(Data(line.utf8)) == ["figma"])
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func followsSymlinksAndSkipsFifos() throws {
        let home = FakeHome()
        home.write("dotfiles/settings.json", #"{"mcpServers": {"figma": {}}}"#)
        try FileManager.default.createDirectory(at: home.file(".gemini"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.file(".gemini/settings.json"), withDestinationURL: home.file("dotfiles/settings.json"))
        try FileManager.default.createDirectory(at: home.file(".copilot"), withIntermediateDirectories: true)
        #expect(mkfifo(home.file(".copilot/mcp-config.json").path, 0o600) == 0)
        let refs = MCPConfig.read(home: home.url, projects: [])
        #expect(refs.map(\.agent) == ["Gemini CLI"] && refs.map(\.name) == ["figma"])
    }

    @Test func capsServersAndProjectsPerFile() {
        let home = FakeHome()
        let many = (0..<100).map { #""s\#($0)": {}"# }.joined(separator: ",")
        let projects = (0..<100).map { #""/Users/me/p\#($0)": {"mcpServers": {"figma": {}}}"# }.joined(separator: ",")
        home.write(".claude.json", #"{"mcpServers": {\#(many)}, "projects": {\#(projects)}}"#)
        let refs = MCPConfig.read(home: home.url, projects: [])
        #expect(refs.filter { $0.scope == .global }.count == MCPConfig.maxServersPerFile)
        #expect(refs.filter { $0.scope != .global }.count == MCPConfig.maxProjects)
    }
}

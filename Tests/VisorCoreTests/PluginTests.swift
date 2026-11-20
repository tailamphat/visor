import Foundation
import Testing
@testable import VisorCore

/// Stands in for Visor: answers requests and records what the plugin shows.
final class FakeHost: PluginHost, @unchecked Sendable {
    var outputs: [PluginOutput] = []
    var peeks: [PluginPeek] = []
    var logs: [String] = []
    var errors: [String] = []
    var requests: [PluginRequest] = []
    var saved: Data?
    var response = PluginResponse(status: 200, body: Data(#"{"ok":true,"items":[1,2]}"#.utf8), headers: [:], cached: false)
    var repoList: [PluginRepo] = []

    var responder: ((PluginRequest) -> PluginResponse)?

    func request(_ request: PluginRequest) -> PluginResponse {
        requests.append(request)
        return responder?(request) ?? response
    }
    func secret(_ name: String, host: String?) -> String? { name == "token" ? "s3cret-\(host ?? "none")" : nil }
    func repos() -> [PluginRepo] { repoList }
    func log(_ line: String) { logs.append(line) }
    func show(_ output: PluginOutput) { outputs.append(output) }
    func peek(_ peek: PluginPeek) { peeks.append(peek) }
    func failed(_ message: String) { errors.append(message) }
    func saveStore(_ data: Data) { saved = data }
}

@Suite("Plugin manifest")
struct PluginManifestTests {
    @Test func readsAManifest() throws {
        let json = #"""
        {"id":"github","name":"GitHub","version":"1.0.0","icon":"arrow.triangle.branch",
         "hosts":["api.github.com","*.ghe.com"],"secrets":{"token":"gh auth token --hostname {host}"},
         "settings":{"repos":[]}}
        """#
        let m = try PluginManifest.parse(Data(json.utf8))
        #expect(m.id == "github" && m.name == "GitHub" && m.main == "main.lua")
        #expect(m.secrets["token"] == "gh auth token --hostname {host}")
        #expect(m.allows(URL(string: "https://api.github.com/repos/a/b")!))
        #expect(m.allows(URL(string: "https://acme.ghe.com/api/v3/user")!))
        #expect(!m.allows(URL(string: "https://ghe.com/x")!), "the wildcard needs a subdomain")
        #expect(!m.allows(URL(string: "https://evil.example/x")!))
        #expect(!m.allows(URL(string: "http://api.github.com/x")!), "https only")
    }

    @Test func rejectsBadIDs() {
        #expect(throws: PluginError.self) { try PluginManifest.parse(Data(#"{"id":"../x","name":"X"}"#.utf8)) }
        #expect(throws: PluginError.self) { try PluginManifest.parse(Data(#"{"name":"X"}"#.utf8)) }
    }
}

@Suite("Lua plugins")
struct LuaPluginTests {
    func plugin(_ source: String, hosts: [String] = ["api.github.com"], store: Data? = nil, settings: [String: Any] = [:]) throws -> (LuaPlugin, FakeHost) {
        let manifest = PluginManifest(id: "test", name: "Test", hosts: hosts, secrets: ["token": "gh auth token"])
        let host = FakeHost()
        let p = try LuaPlugin(manifest: manifest, source: source, host: host, store: store, settings: settings)
        return (p, host)
    }

    /// Nothing that reaches the file system, other programs or Lua's internals.
    @Test func sandbox() throws {
        let (p, host) = try plugin("""
        local gone = {}
        for _, name in ipairs({"io", "require", "dofile", "loadfile", "load", "debug", "package", "collectgarbage"}) do
          if _G[name] ~= nil then table.insert(gone, name) end
        end
        if os.execute or os.remove or os.getenv then table.insert(gone, "os") end
        visor.log("left:" .. table.concat(gone, ","), type(os.time()), string.format("%d", 3))
        """)
        try p.start()
        #expect(host.logs == ["left: number 3"])
        #expect(host.errors.isEmpty)
    }

    @Test func badgePanelAndPeek() throws {
        let (p, host) = try plugin("""
        visor.badge({ icon = "xmark", count = 2, state = "bad", help = "2 failed" })
        visor.panel({
          { title = "Builds", rows = {
              { title = "visor · main · test", detail = "failed", status = "bad", url = "https://github.com/x", time = 1700000000 },
              { title = "api · main · build", status = "good" } } } })
        visor.peek({ title = "CI failed on main", subtitle = "visor", state = "bad" })
        """)
        try p.start()
        let out = try #require(host.outputs.last)
        #expect(out.badge == PluginBadge(icon: "xmark", count: 2, state: .bad, help: "2 failed"))
        #expect(out.sections.count == 1 && out.sections[0].title == "Builds")
        #expect(out.sections[0].rows[0] == PluginRow(title: "visor · main · test", detail: "failed", status: .bad,
                                                     url: URL(string: "https://github.com/x"), time: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(out.sections[0].rows[1].status == .good)
        #expect(host.peeks == [PluginPeek(title: "CI failed on main", subtitle: "visor", state: .bad, icon: nil)])
        // Clearing the badge.
        try p.run("visor.badge(nil)")
        #expect(host.outputs.last?.badge == nil)
    }

    /// `every` runs once right away, then on the interval, never more often than 30 s.
    @Test func every() throws {
        let (p, host) = try plugin("""
        n = 0
        visor.every(5, function() n = n + 1; visor.log("tick " .. n) end)
        """)
        try p.start()
        #expect(p.timers.count == 1 && p.timers[0].interval == 30, "clamped to 30 s")
        #expect(host.logs == ["tick 1"])
        try p.fire(p.timers[0].id)
        #expect(host.logs == ["tick 1", "tick 2"])
    }

    @Test func http() throws {
        let (p, host) = try plugin("""
        local r = visor.http.get("https://api.github.com/user", { headers = { Accept = "application/json" }, auth = "token" })
        visor.log(r.status, tostring(r.json.ok), #r.json.items, tostring(r.cached))
        local ok, err = pcall(visor.http.get, "https://evil.example/")
        visor.log(tostring(ok), err)
        """)
        try p.start()
        #expect(host.logs.first == "200 true 2 false")
        #expect(host.logs.last?.contains("isn't allowed") == true, "hosts outside the manifest are refused")
        #expect(host.requests.count == 1)
        #expect(host.requests[0].headers["Accept"] == "application/json")
        #expect(host.requests[0].headers["Authorization"] == "Bearer s3cret-api.github.com", "auth fills in the secret for that host")
    }

    @Test func secretsAndRepos() throws {
        let (p, host) = try plugin("""
        visor.log(visor.secret("token", "acme.ghe.com"), tostring(visor.secret("nope")))
        local r = visor.repos()[1]
        visor.log(r.host, r.owner, r.name, r.branch)
        """)
        host.repoList = [PluginRepo(host: "github.com", owner: "octocat", name: "visor", branch: "main", path: "/Users/me/visor")]
        try p.start()
        #expect(host.logs == ["s3cret-acme.ghe.com nil", "github.com octocat visor main"])
    }

    /// A loop that never ends is stopped, and the plugin keeps working.
    @Test func runawayCodeIsStopped() throws {
        let (p, host) = try plugin("function spin() while true do end end")
        try p.start()
        #expect(throws: PluginError.self) { try p.run("spin()") }
        try p.run("visor.log('still here')")
        #expect(host.logs == ["still here"])
    }

    @Test func storeIsKept() throws {
        let (p, host) = try plugin("visor.store.count = (visor.store.count or 0) + 1", store: Data(#"{"count":4}"#.utf8))
        try p.start()
        let saved = try #require(host.saved)
        #expect((try JSONSerialization.jsonObject(with: saved) as? [String: Any])?["count"] as? Int == 5)
    }

    /// Saved 0 and 1 come back as numbers, true and false as booleans.
    @Test func storedNumbersStayNumbers() throws {
        let (p, host) = try plugin("visor.log(math.type(visor.store.one), math.type(visor.store.zero), tostring(visor.store.yes), visor.store.half)",
                                   store: Data(#"{"one":1,"zero":0,"yes":true,"half":0.5}"#.utf8))
        try p.start()
        #expect(host.logs == ["integer integer true 0.5"])
    }

    @Test func jsonAndSettings() throws {
        let (p, host) = try plugin("""
        local t = visor.json.decode('{"a":[1,2,{"b":"c"}],"n":null}')
        visor.log(t.a[3].b, #t.a, visor.json.encode({ x = 1 }), visor.settings.repos[1])
        """, settings: ["repos": ["octocat/visor"]])
        try p.start()
        #expect(host.logs == [#"c 3 {"x":1} octocat/visor"#])
    }

    @Test func errorsAreReported() throws {
        let (p, host) = try plugin("visor.every(60, function() error('boom') end)")
        try p.start()
        #expect(host.errors.count == 1 && host.errors[0].contains("boom"))
        #expect(throws: PluginError.self) { _ = try LuaPlugin(manifest: PluginManifest(id: "x", name: "X"), source: "this is not lua", host: host) }
    }
}

@Suite("Git repos for plugins")
struct PluginRepoTests {
    @Test func remotes() {
        #expect(PluginRepo.parseRemote("git@github.com:octocat/visor.git").map { [$0.0, $0.1, $0.2] } == ["github.com", "octocat", "visor"])
        #expect(PluginRepo.parseRemote("https://acme.ghe.com/team/api").map { [$0.0, $0.1, $0.2] } == ["acme.ghe.com", "team", "api"])
        #expect(PluginRepo.parseRemote("ssh://git@github.com/octocat/visor.git").map { [$0.0, $0.1, $0.2] } == ["github.com", "octocat", "visor"])
        #expect(PluginRepo.parseRemote("/local/path") == nil)
    }

    @Test func configAndHead() {
        let config = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = git@github.com:someone/else.git
        [remote "origin"]
        \turl = git@github.com:octocat/visor.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        #expect(PluginRepo.originURL(gitConfig: config) == "git@github.com:octocat/visor.git")
        #expect(PluginRepo.branch(head: "ref: refs/heads/feat/billing\n") == "feat/billing")
        #expect(PluginRepo.branch(head: "3f2a9c0d\n") == nil, "detached")
    }
}

@Suite("Plugin secrets")
struct PluginSecretTests {
    /// Only tools that read a saved sign-in, never anything that changes your Mac.
    @Test func allowedCommands() {
        #expect(PluginSecrets.command("gh auth token --hostname {host}", host: "acme.ghe.com") == ["gh", "auth", "token", "--hostname", "acme.ghe.com"])
        #expect(PluginSecrets.command("gh auth token", host: nil) == ["gh", "auth", "token"])
        #expect(PluginSecrets.command("op read op://Dev/GitHub/token", host: nil) == ["op", "read", "op://Dev/GitHub/token"])
        #expect(PluginSecrets.command("security find-generic-password -s my-api -w", host: nil) != nil)
        #expect(PluginSecrets.command("security delete-generic-password -s x", host: nil) == nil)
        #expect(PluginSecrets.command("rm -rf ~", host: nil) == nil)
        #expect(PluginSecrets.command("gh api -X DELETE /repos/a/b", host: nil) == nil, "gh only for auth token")
        #expect(PluginSecrets.command("gh auth token --hostname {host}", host: "x; rm -rf ~") == nil, "hosts are checked")
    }
}

@Suite("Example plugins")
struct ExamplePluginTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Plugins")

    func load(_ id: String, host: FakeHost, store: Data? = nil) throws -> LuaPlugin {
        let folder = Self.root.appendingPathComponent(id)
        let manifest = try PluginManifest.parse(Data(contentsOf: folder.appendingPathComponent("plugin.json")))
        let source = try String(contentsOf: folder.appendingPathComponent(manifest.main), encoding: .utf8)
        return try LuaPlugin(manifest: manifest, source: source, host: host, store: store)
    }

    @Test func hello() throws {
        let host = FakeHost()
        host.repoList = [PluginRepo(host: "github.com", owner: "octocat", name: "visor", branch: "main", path: "/Users/me/visor")]
        let p = try load("hello", host: host)
        try p.start()
        #expect(host.errors.isEmpty)
        #expect(host.peeks.first?.title == "Hello from a plugin")
        #expect(host.outputs.last?.sections.first?.rows.first?.title == "octocat/visor")
        #expect(host.outputs.last?.badge?.count == 1)
    }

    /// A failed run on the agent's branch: a red badge, a peek once, the run first in the panel.
    @Test func github() throws {
        let host = FakeHost()
        host.repoList = [PluginRepo(host: "acme.ghe.com", owner: "team", name: "api", branch: "feat/x", path: "/Users/me/api")]
        host.responder = { request in
            let url = request.url.absoluteString
            if url.contains("/actions/runs") {
                let body = #"{"workflow_runs":[{"id":11,"workflow_id":1,"name":"test","head_branch":"feat/x","status":"completed","conclusion":"failure","html_url":"https://acme.ghe.com/team/api/actions/runs/11","updated_at":"2026-11-20T08:00:00Z"},{"id":12,"workflow_id":2,"name":"lint","head_branch":"feat/x","status":"completed","conclusion":"success","html_url":"https://acme.ghe.com/team/api/actions/runs/12","updated_at":"2026-11-20T07:00:00Z"},{"id":10,"workflow_id":1,"name":"test","head_branch":"feat/x","status":"completed","conclusion":"success","html_url":"x","updated_at":"2026-11-19T07:00:00Z"}]}"#
                return PluginResponse(status: 200, body: Data(body.utf8), headers: [:], cached: false)
            }
            let prs = #"{"items":[{"number":482,"title":"Add webhooks","repository_url":"https://api.github.com/repos/octocat/visor","html_url":"https://github.com/octocat/visor/pull/482","updated_at":"2026-11-20T06:00:00Z"}]}"#
            return PluginResponse(status: 200, body: Data(prs.utf8), headers: [:], cached: false)
        }
        let p = try load("github", host: host)
        try p.start()
        #expect(host.errors.isEmpty, "\(host.errors)")
        #expect(host.requests.contains { $0.url.absoluteString.hasPrefix("https://acme.ghe.com/api/v3/repos/team/api/actions/runs") && $0.url.absoluteString.contains("branch=feat%2Fx") })
        #expect(host.requests.filter { $0.url.host == "acme.ghe.com" }.allSatisfy { $0.headers["Authorization"] == "Bearer s3cret-acme.ghe.com" })
        #expect(host.requests.filter { $0.url.host == "api.github.com" }.allSatisfy { $0.headers["Authorization"] == "Bearer s3cret-github.com" },
                "the token for github.com, not api.github.com")
        let out = try #require(host.outputs.last)
        #expect(out.badge == PluginBadge(icon: "xmark.octagon.fill", count: nil, state: .bad, help: "1 failed workflow runs"))
        #expect(out.sections.map(\.title) == ["Actions", "Review requested"])
        #expect(out.sections[0].rows.map(\.title) == ["api · feat/x · test", "api · feat/x · lint"], "newest run per workflow, failures first")
        #expect(out.sections[1].rows.first?.title == "#482 Add webhooks")
        #expect(host.peeks.count == 1)
        // The same failure again: no second peek.
        try p.fire(p.timers[0].id)
        #expect(host.peeks.count == 1)
    }
}

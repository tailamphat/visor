import Foundation
import Testing
@testable import VisorCore

/// Plugin authors pick Visor's design system by name: components as pieces,
/// colours as palette names, text on the type scale. Never hex, points or pixels.
@Suite("Plugin design system")
struct PluginDesignTests {
    func view(_ lua: String) throws -> (PluginNode?, FakeHost) {
        let host = FakeHost()
        let p = try LuaPlugin(manifest: PluginManifest(id: "d", name: "D"), source: "local ui = visor.ui\n" + lua, host: host)
        try p.start()
        return (host.outputs.last?.view, host)
    }

    @Test func decodesDesignPieces() throws {
        let (node, host) = try view("""
        visor.view(ui.stack {
          ui.banner { tint = "warning", badge = "Freeze", title = "Release freeze at 17:00", text = "3 PRs open", dismiss = "hide",
                      ui.text { "a" } },
          ui.badge { "v2.4.1", tint = "good" },
          ui.badge { "draft" },
          ui.header { "Recent", badge = "3" },
          ui.header { "Production" },
          ui.buttons { ui.button { "Go", action = "go", style = "secondary" }, ui.button { "Open", action = "open", style = "primary" } },
        })
        """)
        #expect(host.errors.isEmpty, "\(host.errors)")
        guard case .stack(let parts)? = node else { Issue.record("no stack"); return }
        #expect(parts.count == 6)
        #expect(parts[0] == .banner(PluginBanner(tint: .warning, badge: "Freeze", title: "Release freeze at 17:00", text: "3 PRs open",
                                                 dismiss: "hide", children: [.text("a", style: .body, state: nil)])))
        #expect(parts[1] == .badge("v2.4.1", tint: .good))
        #expect(parts[2] == .badge("draft", tint: nil))
        #expect(parts[3] == .header("Recent", badge: "3"))
        #expect(parts[4] == .header("Production", badge: nil))
        #expect(parts[5] == .buttons([PluginButton(title: "Go", action: "go", url: nil, primary: false),
                                      PluginButton(title: "Open", action: "open", url: nil, primary: true)]))
    }

    /// Only text and status colours are offered, each a real palette token;
    /// the approval buttons' colours mean "approve" in Visor and stay out.
    @Test func colourNamesArePaletteTokens() {
        let palette = Set(DesignScale.palette.map(\.name))
        for colour in PluginColor.allCases {
            #expect(palette.contains(colour.rawValue), "\(colour.rawValue) isn't a palette token")
            #expect(colour.hex == UInt32(DesignScale.palette.first { $0.name == colour.rawValue }!.value))
        }
        for hidden in ["mint", "rose", "allowText", "alwaysText", "denyText", "surface", "raised", "accentTrack"] {
            #expect(PluginColor(name: hidden) == nil, "\(hidden) shouldn't be offered")
        }
        #expect(PluginColor(name: "STUCK") == .stuck)
        #expect(PluginColor(name: "textmuted") == .textMuted)
    }

    @Test func colourWinsOverState() throws {
        let (node, _) = try view("""
        visor.view(ui.stack {
          ui.text { "x", state = "bad", color = "question" },
          ui.stat { value = "3", label = "l", color = "STUCK" },
          ui.meter { title = "m", value = 0.5, color = "claude" },
          ui.chips { { "c", color = "clash" }, "plain" },
          ui.bars { values = { 1, { 2, color = "good" } } },
        })
        """)
        guard case .stack(let parts)? = node else { Issue.record("no stack"); return }
        #expect(parts[0] == .text("x", style: .body, state: .bad, color: .question))
        #expect(parts[1] == .stat(value: "3", label: "l", state: nil, large: false, pending: false, color: .stuck))
        #expect(parts[2] == .meter(title: "m", value: 0.5, text: "50%", caption: "", state: nil, pending: false, color: .claude))
        #expect(parts[3] == .chips([PluginChip(text: "c", state: nil, color: .clash), PluginChip(text: "plain", state: nil)]))
        #expect(parts[4] == .bars(values: [1, 2], states: [nil, nil], labels: [], pending: false, colors: [nil, .good]))
    }

    @Test func textSizesAreTypeScaleSteps() throws {
        let steps = Set(DesignScale.typeScale.map(\.name))
        for step in PluginTypeStep.allCases { #expect(steps.contains(step.rawValue)) }
        #expect(PluginTypeStep.allCases.count == DesignScale.typeScale.count)
        let (node, _) = try view("""
        visor.view(ui.stack {
          ui.text { "h", style = "headline" },
          ui.text { "f", style = "footnote" },
          ui.text { "s", size = "lg", weight = "semibold" },
          ui.text { "d", size = "DISPLAY", weight = "Bold" },
        })
        """)
        guard case .stack(let parts)? = node else { Issue.record("no stack"); return }
        #expect(parts[0] == .text("h", style: .headline, state: nil))
        #expect(parts[1] == .text("f", style: .footnote, state: nil))
        #expect(parts[2] == .text("s", style: .body, state: nil, size: .lg, weight: .semibold))
        #expect(parts[3] == .text("d", style: .body, state: nil, size: .display, weight: .bold))
    }

    /// Anything that isn't a known name falls back to the default look, quietly.
    @Test func unknownTokensFallBack() throws {
        let (node, host) = try view("""
        visor.view(ui.stack {
          ui.text { "a", color = "hotpink", size = "huge", weight = "black", style = "fancy" },
          ui.text { "b", color = "#FF0000", size = 14, weight = 700 },
          ui.text { "c", color = 12, size = true, weight = {} },
          ui.badge { "d", tint = {} },
          ui.banner { tint = "#FF0000", title = 5, badge = true, dismiss = 3 },
          ui.stat { value = "1", label = "x", color = true },
        })
        """)
        #expect(host.errors.isEmpty, "\(host.errors)")
        guard case .stack(let parts)? = node else { Issue.record("no stack"); return }
        #expect(parts[0] == .text("a", style: .body, state: nil))
        #expect(parts[1] == .text("b", style: .body, state: nil))
        #expect(parts[2] == .text("c", style: .body, state: nil))
        #expect(parts[3] == .badge("d", tint: nil))
        #expect(parts[4] == .banner(PluginBanner(tint: nil, badge: nil, title: "5", text: "", dismiss: nil, children: [])))
        #expect(parts[5] == .stat(value: "1", label: "x", state: nil, large: false, pending: false))
    }

    /// New pieces are rationed like the rest.
    @Test func bannerIsRationed() throws {
        let long = String(repeating: "x", count: 500)
        let (node, _) = try view("""
        local many = { title = "t" }
        for i = 1, 400 do many[i] = ui.text { "x" .. i } end
        local deep = ui.text { "bottom" }
        for i = 1, 12 do deep = ui.banner { title = "d" .. i, deep } end
        visor.view(ui.stack {
          deep,
          ui.badge { "\(long)" },
          ui.header { "\(long)", badge = "\(long)" },
          ui.banner { title = "\(long)", text = "\(long)", badge = "\(long)", dismiss = "\(long)" },
          ui.banner(many),
        })
        """)
        guard let node, case .stack(let parts) = node else { Issue.record("no stack"); return }
        #expect(PluginNode.count(node) <= PluginNode.maxNodes)
        func depth(_ n: PluginNode) -> Int {
            switch n {
            case .stack(let c), .columns(let c), .stats(let c): return 1 + (c.map(depth).max() ?? 0)
            case .banner(let b): return 1 + (b.children.map(depth).max() ?? 0)
            default: return 1
            }
        }
        #expect(depth(node) <= PluginNode.maxDepth)
        guard parts.count == 5 else { Issue.record("parts \(parts.count)"); return }
        #expect(parts[1] == .badge(String(long.prefix(40)), tint: nil))
        #expect(parts[2] == .header(String(long.prefix(80)), badge: String(long.prefix(40))))
        guard case .banner(let b) = parts[3] else { Issue.record("no banner"); return }
        #expect(b.title.count == 300 && b.text.count == 300 && b.badge?.count == 40)
        // A cut handler name would match no handler: a too-long dismiss shows no x.
        #expect(b.dismiss == nil)
    }

    /// Badges take numbers like every other text field ("a count").
    @Test func numericBadgesAndExactDismiss() throws {
        let name = String(repeating: "h", count: 100)
        let (node, _) = try view("""
        visor.view(ui.stack {
          ui.header { "Pull requests", badge = 3 },
          ui.banner { title = "t", badge = 12, dismiss = "\(name)" },
        })
        """)
        guard case .stack(let parts)? = node, parts.count == 2 else { Issue.record("no stack"); return }
        #expect(parts[0] == .header("Pull requests", badge: "3"))
        guard case .banner(let b) = parts[1] else { Issue.record("no banner"); return }
        #expect(b.badge == "12")
        #expect(b.dismiss == name)
    }

    /// Plugin piece sizes sit on the scale, or are named component constants.
    @Test func pieceMeasurementsSitOnTheScale() {
        #expect(!PluginPieces.measurements.isEmpty)
        for m in PluginPieces.measurements {
            guard let scale = m.scale else { continue }
            #expect(scale.contains { abs($0.value - m.value) < 1e-9 }, "\(m.name) = \(m.value) is off its scale")
        }
    }

    /// Old trees decode exactly as before (the plugin API keeps working).
    @Test func oldFieldsUnchanged() throws {
        let (node, _) = try view("""
        visor.view(ui.stack { ui.text { "t", style = "caption", state = "good" }, ui.chips { { "c", state = "warn" } } })
        """)
        #expect(node == .stack([.text("t", style: .caption, state: .good), .chips([PluginChip(text: "c", state: .warn)])]))
    }
}

@Suite("Focus plugin design")
struct FocusDesignTests {
    @Test func usesDesignPieces() throws {
        let host = FakeHost()
        let p = try ExamplePluginTests().load("focus", host: host)
        try p.start()
        #expect(host.errors.isEmpty, "\(host.errors)")
        func parts() -> [PluginNode] { if case .stack(let parts)? = host.outputs.last?.view { return parts }; return [] }
        func hasHeader(_ node: PluginNode) -> Bool {
            switch node {
            case .header: return true
            case .stack(let c), .columns(let c): return c.contains(where: hasHeader)
            default: return false
            }
        }
        #expect(parts().contains(where: hasHeader))
        func banner() -> PluginBanner? {
            for part in parts() { if case .banner(let b) = part { return b } }
            return nil
        }
        #expect(banner() == nil)
        // A session that has just ended shows the break banner.
        try p.run("visor.store.endsAt = os.time() - 1")
        try p.act("length", value: "25")
        #expect(banner()?.tint == .good)
        #expect(banner()?.dismiss == "dismissBreak")
        try p.act("dismissBreak", value: nil)
        #expect(banner() == nil)
        #expect(host.errors.isEmpty, "\(host.errors)")
    }
}

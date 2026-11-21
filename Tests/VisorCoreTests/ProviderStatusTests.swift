import Foundation
import Testing
@testable import VisorCore

@Suite("Provider status")
struct ProviderStatusTests {
    func page(components: [(String, String)], incidents: String = "[]") -> Data {
        let list = components.map { #"{"id":"\#($0.0)","name":"\#($0.0)","status":"\#($0.1)","updated_at":"2026-11-21T06:00:00.000Z"}"# }
        return Data(#"{"page":{"url":"https://status.claude.com"},"status":{"indicator":"none"},"components":[\#(list.joined(separator: ","))],"incidents":\#(incidents)}"#.utf8)
    }

    /// All operational: nothing to say.
    @Test func quietWhenFine() throws {
        let data = page(components: [("Claude Code", "operational"), ("claude.ai", "operational")])
        #expect(try ProviderStatus.incident(in: data, watching: ProviderStatus.claude.components) == nil)
    }

    /// An open incident on a component you use: its title, how bad, since when, its link.
    @Test func openIncident() throws {
        let incidents = #"[{"id":"inc1","name":"Elevated errors on Claude Code","status":"investigating","impact":"major","created_at":"2026-11-21T07:02:00.000Z","shortlink":"https://stspg.io/abc","components":[{"name":"Claude Code"}]}]"#
        let data = page(components: [("Claude Code", "partial_outage")], incidents: incidents)
        let found = try #require(try ProviderStatus.incident(in: data, watching: ProviderStatus.claude.components))
        #expect(found.title == "Elevated errors on Claude Code" && found.severity == .major && found.id == "inc1")
        #expect(found.link == "https://stspg.io/abc")
        #expect(found.since == ISO8601DateFormatter.withFraction.date(from: "2026-11-21T07:02:00.000Z"))
    }

    /// An incident on parts you don't use stays quiet; minor impact is minor.
    @Test func onlyYourComponents() throws {
        let other = #"[{"id":"inc2","name":"claude.ai is slow","status":"monitoring","impact":"minor","created_at":"2026-11-21T07:02:00.000Z","components":[{"name":"claude.ai"}]}]"#
        #expect(try ProviderStatus.incident(in: page(components: [("claude.ai", "degraded_performance")], incidents: other),
                                            watching: ProviderStatus.claude.components) == nil)
        let copilot = #"[{"id":"inc3","name":"Copilot: degraded performance","status":"monitoring","impact":"minor","created_at":"2026-11-21T06:40:00.000Z","components":[{"name":"Copilot"}]}]"#
        let found = try ProviderStatus.incident(in: page(components: [("Copilot", "degraded_performance")], incidents: copilot),
                                                watching: ProviderStatus.copilot.components)
        #expect(found?.severity == .minor)
    }

    /// A component marked down without an incident written yet still counts.
    @Test func componentDownWithoutIncident() throws {
        let found = try ProviderStatus.incident(in: page(components: [("Claude API (api.anthropic.com)", "major_outage")]),
                                                watching: ProviderStatus.claude.components)
        #expect(found?.title == "Claude API: major outage" && found?.severity == .major)
        #expect(try ProviderStatus.incident(in: page(components: [("Claude Code", "under_maintenance")]),
                                            watching: ProviderStatus.claude.components) == nil, "planned maintenance isn't an incident")
    }
}

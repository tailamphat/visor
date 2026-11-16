import Testing
@testable import VisorCore

@Suite("About")
struct AboutTests {
    @Test func linksInOrder() {
        #expect(About.links.map(\.title) == ["Website", "GitHub", "Report an issue"])
        #expect(About.links.map(\.url.absoluteString) == ["https://tailamphat.github.io/visor/",
                                                          "https://github.com/tailamphat/visor",
                                                          "https://github.com/tailamphat/visor/issues/new"])
    }
}

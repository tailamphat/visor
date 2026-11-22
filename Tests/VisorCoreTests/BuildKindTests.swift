import Testing
@testable import VisorCore

@Suite("Build kind")
struct BuildKindTests {
    @Test func releaseOnlyWhenStamped() {
        #expect(BuildKind.isRelease(info: ["VisorRelease": "YES"]))
        #expect(BuildKind.isRelease(info: ["VisorRelease": true]))
        #expect(!BuildKind.isRelease(info: ["VisorRelease": "NO"]))
        #expect(!BuildKind.isRelease(info: [:]))
        #expect(!BuildKind.isRelease(info: nil))
    }

    @Test func menuTitle() {
        #expect(BuildKind.menuTitle(version: "0.9.0", commit: "abc1234", worktree: "ai-tools-4a")
            == "Visor (local build) \u{00B7} 0.9.0 \u{00B7} abc1234 \u{00B7} ai-tools-4a")
        #expect(BuildKind.menuTitle(version: nil, commit: "abc1234", worktree: nil)
            == "Visor (local build) \u{00B7} dev \u{00B7} abc1234")
    }
}

import Foundation
import Testing
@testable import VisorCore

@Suite("Browser extension bridge")
struct BrowserBridgeTests {
    /// Native messaging: each message is a 4-byte little-endian length, then JSON.
    @Test func framesAndUnframes() throws {
        let one = Data(#"{"type":"tabs"}"#.utf8), two = Data(#"{"a":1}"#.utf8)
        var buffer = NativeMessaging.frame(one) + NativeMessaging.frame(two)
        #expect(buffer.prefix(4) == Data([15, 0, 0, 0]))
        let partial = buffer.suffix(3)
        buffer.removeLast(3)
        #expect(try NativeMessaging.unframe(&buffer) == [one], "the second is still arriving")
        buffer.append(partial)
        #expect(try NativeMessaging.unframe(&buffer) == [two])
        #expect(buffer.isEmpty)
    }

    /// A length past the limit means a corrupt stream: refused, rather than waiting for gigabytes.
    @Test func refusesHugeLengths() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0x7F]) + Data("{}".utf8)
        #expect(throws: NativeMessaging.TooLong.self) { try NativeMessaging.unframe(&buffer) }
    }

    /// The extension sends every media tab; the playing one wins, else the latest.
    @Test func picksThePlayingTab() {
        let line = #"""
        {"type":"tabs","tabs":[
          {"id":"7","at":2000,"p":false,"r":4,"t":12,"d":200,"title":"Paused - YouTube","url":"https://www.youtube.com/watch?v=abc"},
          {"id":"9","at":1000,"p":true,"r":4,"t":30,"d":180,"title":"Song","artist":"Band","art":"https://x/a.jpg","url":"https://music.youtube.com/watch?v=x"}]}
        """#
        let tabs = BrowserBridge.tabs(Data(line.utf8))
        #expect(tabs?.count == 2)
        let pick = BrowserBridge.pick(tabs ?? [])
        #expect(pick?.media.tab == "9")
        #expect(pick?.media.playing == true)
        #expect(pick?.media.site == "YouTube Music")
        #expect(BrowserBridge.pick(Array(tabs!.prefix(1)))?.media.title == "Paused")
        #expect(BrowserBridge.tabs(Data(#"{"type":"tabs","tabs":[]}"#.utf8)) == [])
        #expect(BrowserBridge.tabs(Data(#"{"type":"hello"}"#.utf8)) == nil)
    }

    @Test func commandLine() {
        let line = BrowserBridge.command(.next, tab: "9")
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: String]
        #expect(object == ["type": "command", "tab": "9", "command": "next"])
        #expect(line.last == 0x0A)
    }

    /// Chromium browsers name the extension by id; Firefox and Zen by its gecko id.
    @Test func hostManifests() throws {
        let chromium = try #require(JSONSerialization.jsonObject(with: BrowserBridge.manifest(path: "/A/visor-bridge", firefox: false)) as? [String: Any])
        #expect(chromium["name"] as? String == BrowserBridge.hostName)
        #expect(chromium["path"] as? String == "/A/visor-bridge")
        #expect(chromium["type"] as? String == "stdio")
        #expect(chromium["allowed_origins"] as? [String] == ["chrome-extension://\(BrowserBridge.chromiumID)/"])
        let firefox = try #require(JSONSerialization.jsonObject(with: BrowserBridge.manifest(path: "/A/visor-bridge", firefox: true)) as? [String: Any])
        #expect(firefox["allowed_extensions"] as? [String] == [BrowserBridge.geckoID])
        #expect(firefox["allowed_origins"] == nil)
    }

    /// Manifests go where each installed browser looks for them.
    @Test func hostDirectories() {
        let support = "/Users/me/Library/Application Support"
        let present: Set<String> = ["\(support)/Google/Chrome", "\(support)/Dia/User Data", "\(support)/Mozilla"]
        let dirs = BrowserBridge.hostDirectories(support: support) { present.contains($0) }
        #expect(dirs.contains { $0.path == "\(support)/Google/Chrome/NativeMessagingHosts" && !$0.firefox })
        #expect(dirs.contains { $0.path == "\(support)/Dia/User Data/NativeMessagingHosts" && !$0.firefox })
        #expect(dirs.contains { $0.path == "\(support)/Mozilla/NativeMessagingHosts" && $0.firefox })
        #expect(!dirs.contains { $0.path.contains("Brave") })
    }
}

@Suite("Background tab playback")
struct BackgroundPlaybackTests {
    /// Dia holds back media in a background tab: play() "succeeds" but time stands still.
    @Test func startedOnlyWhenTimeMoves() {
        #expect(BrowserMedia.started(from: 100, probe: #"{"p":true,"t":100.9}"#))
        #expect(!BrowserMedia.started(from: 100, probe: #"{"p":true,"t":100.01}"#), "frozen")
        #expect(!BrowserMedia.started(from: 100, probe: #"{"p":false,"t":100.9}"#), "paused again")
        #expect(BrowserMedia.started(from: 100, probe: #""{\"p\":true,\"t\":101}""#), "Dia quotes the JSON once more")
        #expect(!BrowserMedia.started(from: 100, probe: ""))
    }

    @Test func onlyDiaCanFlashATab() {
        #expect(BrowserMedia.canFocusTab("company.thebrowser.dia"))
        #expect(!BrowserMedia.canFocusTab("com.google.Chrome"))
    }
}

import Foundation
import JavaScriptCore
import Testing
@testable import NotchboardCore

@Suite("Bar items")
struct BarItemTests {
    @Test func droppedFilesAndLinks() throws {
        let app = try #require(BarItem.dropped(URL(fileURLWithPath: "/Applications/Safari.app"), isDirectory: true))
        #expect(app.kind == .app && app.name == "Safari" && app.target == "/Applications/Safari.app")
        let folder = try #require(BarItem.dropped(URL(fileURLWithPath: "/Users/me/Work"), isDirectory: true))
        #expect(folder.kind == .folder && folder.name == "Work")
        let file = try #require(BarItem.dropped(URL(fileURLWithPath: "/Users/me/Q4 report.pdf"), isDirectory: false))
        #expect(file.kind == .file && file.name == "Q4 report.pdf")
        let link = try #require(BarItem.dropped(URL(string: "https://www.github.com/octocat")!, isDirectory: false))
        #expect(link.kind == .link && link.name == "github.com" && link.target == "https://www.github.com/octocat")
        #expect(BarItem.dropped(URL(string: "mailto:a@b.c")!, isDirectory: false) == nil)
    }

    @Test("Web addresses dragged as text", arguments: [
        ("https://github.com/octocat", "https://github.com/octocat"),
        ("github.com/octocat/acme", "https://github.com/octocat/acme"),
    ])
    func linkFromText(text: String, target: String) {
        #expect(BarItem.link(fromText: text)?.target == target)
    }

    @Test func linkFromTextTakesTheFirstLineTrimmed() {
        #expect(BarItem.link(fromText: "  www.apple.com \nsecond line")?.name == "apple.com")
    }

    @Test("Text that isn't a web address", arguments: ["localhost:8765/#features", "hello world", "notes.txt2"])
    func notLinks(text: String) {
        #expect(BarItem.link(fromText: text) == nil)
    }

    @Test func widgetsAndShortcuts() {
        #expect(BarItem.widget(.cpu).widget == .cpu && BarItem.shortcut("Deploy").target == "Deploy")
    }
}

@Suite("Bar layout")
struct BarLayoutTests {
    @Test func addMoveRemoveAndSave() throws {
        let app = BarItem.dropped(URL(fileURLWithPath: "/Applications/Safari.app"), isDirectory: true)!
        let folder = BarItem.dropped(URL(fileURLWithPath: "/Users/me/Work"), isDirectory: true)!
        let file = BarItem.dropped(URL(fileURLWithPath: "/Users/me/Q4 report.pdf"), isDirectory: false)!
        let link = BarItem.dropped(URL(string: "https://www.github.com/octocat")!, isDirectory: false)!

        var bar = BarLayout()
        let added = [bar.add(app), bar.add(folder), bar.add(file)]
        #expect(added == [true, true, true])
        let again = bar.add(BarItem.dropped(URL(fileURLWithPath: "/Applications/Safari.app"), isDirectory: true)!)
        #expect(!again, "the same app twice is refused")
        bar.move(file.id, to: 0)
        #expect(bar.items.map(\.name) == ["Q4 report.pdf", "Safari", "Work"])
        bar.move(file.id, to: 9)
        #expect(bar.items.last?.id == file.id, "moving past the end lands last")
        bar.add(link, at: 1)
        #expect(bar.items[1].id == link.id)
        bar.remove(app.id)
        #expect(!bar.items.contains { $0.id == app.id })
        let data = try JSONEncoder().encode(bar)
        #expect(try JSONDecoder().decode(BarLayout.self, from: data) == bar)
    }
}

@Suite("Browser media")
struct BrowserMediaTests {
    @Test func parsesTheProbe() throws {
        let json = #"{"p":true,"t":61.5,"d":200,"title":"Song","artist":"Band","album":"","art":"https://x/a.jpg","url":"https://www.youtube.com/watch?v=abc123"}"#
        let media = try #require(BrowserMedia.parse(json, tab: "1"))
        #expect(media.playing && media.position == 61.5 && media.duration == 200)
        #expect(media.title == "Song" && media.artist == "Band" && media.site == "YouTube")
        #expect(media.artworkURL?.absoluteString == "https://x/a.jpg", "Media Session artwork wins")
    }

    @Test func pageTitleFallback() throws {
        let bare = try #require(BrowserMedia.parse(#"{"p":false,"t":0,"d":0,"title":"(3) Lofi beats - YouTube","url":"https://www.youtube.com/watch?v=XYZ&t=4"}"#, tab: "2"))
        #expect(bare.title == "Lofi beats")
        #expect(bare.artworkURL?.absoluteString == "https://i.ytimg.com/vi/XYZ/hqdefault.jpg")
        #expect(BrowserMedia.parse("", tab: "3") == nil)
        #expect(BrowserMedia.fromTitle("Mix - YouTube", url: "https://music.youtube.com/watch?v=q", tab: "4", playing: true)?.site == "YouTube Music")
    }

    @Test func mediaSitesAndAppleScriptSafety() {
        #expect(BrowserMedia.isMediaSite("https://www.youtube.com/watch?v=1") && !BrowserMedia.isMediaSite("https://github.com"))
        #expect(!BrowserMedia.probe.contains("\""), "no double quotes, so it fits in AppleScript")
    }

    /// Runs the page scripts against a fake YouTube page in JavaScriptCore.
    @Test func pageScriptsAgainstAFakePage() throws {
        let js = try #require(JSContext())
        var thrown: String?
        js.exceptionHandler = { _, e in thrown = e?.toString() }
        js.evaluateScript("""
        var video = {paused: false, currentTime: 42, duration: 180, play: function(){this.paused=false;}, pause: function(){this.paused=true;}};
        var clicked = '';
        var document = {title: '(2) Song - YouTube',
          querySelectorAll: function(){ return [video]; },
          querySelector: function(q){ if (q.indexOf('ytp-next-button') >= 0) return {click: function(){clicked='next';}}; return q.indexOf('video') === 0 ? video : null; }};
        var navigator = {mediaSession: {metadata: {title: 'Song', artist: 'Band', album: '', artwork: [{src: 'https://img/s.jpg'}]}}};
        var location = {href: 'https://www.youtube.com/watch?v=abc'};
        """)
        let live = BrowserMedia.parse(js.evaluateScript(BrowserMedia.probe)?.toString() ?? "", tab: "7")
        #expect(live?.playing == true && live?.position == 42 && live?.duration == 180 && live?.title == "Song"
                && live?.artist == "Band" && live?.artworkURL?.absoluteString == "https://img/s.jpg")
        js.evaluateScript(BrowserMedia.script(for: .playPause))
        #expect(js.evaluateScript("video.paused")?.toBool() == true)
        js.evaluateScript(BrowserMedia.script(for: .playPause))
        #expect(js.evaluateScript("video.paused")?.toBool() == false)
        js.evaluateScript(BrowserMedia.script(for: .next))
        #expect(js.evaluateScript("clicked")?.toString() == "next")
        js.evaluateScript(BrowserMedia.script(for: .previous))
        #expect(js.evaluateScript("video.currentTime")?.toInt32() == 0, "previous restarts when there's no previous button")
        js.evaluateScript("navigator.mediaSession = undefined; video.paused = true; video.currentTime = 0")
        #expect(js.evaluateScript(BrowserMedia.probe)?.toString() == "", "untouched media reports nothing")
        #expect(thrown == nil)
    }
}

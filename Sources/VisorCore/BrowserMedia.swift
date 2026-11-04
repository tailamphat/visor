import Foundation

/// Media playing in a browser tab (YouTube, YouTube Music, SoundCloud, ...),
/// read by running a small script in the tab through the browser's AppleScript.
public struct BrowserMedia: Equatable, Sendable {
    public var tab: String
    public var playing: Bool
    public var position: Double
    public var duration: Double
    public var title: String
    public var artist: String
    public var album: String
    public var artworkURL: URL?
    public var site: String

    public init(tab: String, playing: Bool, position: Double, duration: Double, title: String,
                artist: String = "", album: String = "", artworkURL: URL? = nil, site: String = "") {
        self.tab = tab
        self.playing = playing
        self.position = position
        self.duration = duration
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.site = site
    }

    /// Sites worth looking at. Running a script in every open tab would be slow.
    public static let sites = ["youtube.com", "youtu.be", "soundcloud.com", "open.spotify.com", "music.apple.com",
                               "twitch.tv", "vimeo.com", "bandcamp.com", "deezer.com", "tidal.com",
                               "mixcloud.com", "music.amazon.", "pandora.com"]

    public static func isMediaSite(_ url: String) -> Bool { sites.contains { url.contains($0) } }

    /// Page scripts off: whether the media tab is playing, judged from the
    /// browser's sound. A browser plays every tab through one audio process,
    /// so its sound alone can't say which tab makes it. Silence means paused.
    /// Sound means playing, unless the browser is also using the microphone
    /// (a call): then the sound may be the call, and what was shown before
    /// (the last press in the notch, say) stands.
    public static func playingFromSound(audible: Bool, inCall: Bool, shown: Bool?) -> Bool {
        guard audible else { return false }
        return inCall ? shown ?? false : true
    }

    /// Runs in the page. Prefers the Media Session metadata sites publish for
    /// the system media controls, falling back to the page title. Single quotes
    /// only, so it can sit inside an AppleScript string.
    public static let probe = """
    (function(){var all=[].slice.call(document.querySelectorAll('video,audio'));\
    var m=all.filter(function(e){return !e.paused;})[0]||all.filter(function(e){return e.currentTime>0;})[0];\
    if(!m)return '';var s=navigator.mediaSession&&navigator.mediaSession.metadata;\
    var a=s&&s.artwork&&s.artwork.length?s.artwork[s.artwork.length-1].src:'';\
    return JSON.stringify({p:!m.paused,t:m.currentTime||0,d:isFinite(m.duration)?m.duration:0,\
    title:(s&&s.title)||document.title,artist:(s&&s.artist)||'',album:(s&&s.album)||'',art:a,url:location.href});})()
    """

    public enum Command: Sendable { case playPause, next, previous }

    /// Runs in the page to control playback. Next/previous click the site's own
    /// buttons; previous restarts the track when there is none.
    public static func script(for command: Command) -> String {
        switch command {
        case .playPause:
            return "(function(){var all=[].slice.call(document.querySelectorAll('video,audio'));var m=all.filter(function(e){return !e.paused;})[0]||all.filter(function(e){return e.currentTime>0;})[0]||all[0];if(!m)return '';if(m.paused){m.play();}else{m.pause();}return 'ok';})()"
        case .next:
            return "(function(){var b=document.querySelector('.ytp-next-button, ytmusic-player-bar .next-button, .skipControl__next, [data-testid=\\'control-button-skip-forward\\'], button[aria-label=\\'Next\\']');if(b){b.click();return 'ok';}return '';})()"
        case .previous:
            return "(function(){var b=document.querySelector('ytmusic-player-bar .previous-button, .skipControl__previous, [data-testid=\\'control-button-skip-back\\'], button[aria-label=\\'Previous\\']');if(b){b.click();return 'ok';}var m=document.querySelector('video,audio');if(m){m.currentTime=0;}return 'ok';})()"
        }
    }

    /// Parses what `probe` returned for one tab.
    public static func parse(_ json: String, tab: String) -> BrowserMedia? {
        guard !json.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let url = object["url"] as? String ?? ""
        var title = object["title"] as? String ?? ""
        // Page titles carry the site name ("Song - YouTube") and an unread count ("(3) Song").
        if title.hasSuffix(" - YouTube") { title = String(title.dropLast(10)) }
        if title.hasPrefix("("), let close = title.firstIndex(of: ")"), title[title.index(after: title.startIndex)..<close].allSatisfy(\.isNumber) {
            title = String(title[title.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !title.isEmpty else { return nil }
        var artwork = (object["art"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        if artwork == nil, let id = youTubeID(url) {
            artwork = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
        return BrowserMedia(tab: tab,
                            playing: object["p"] as? Bool ?? false,
                            position: (object["t"] as? NSNumber)?.doubleValue ?? 0,
                            duration: (object["d"] as? NSNumber)?.doubleValue ?? 0,
                            title: title,
                            artist: object["artist"] as? String ?? "",
                            album: object["album"] as? String ?? "",
                            artworkURL: artwork,
                            site: site(url))
    }

    /// The tab title when scripts aren't allowed in the browser.
    public static func fromTitle(_ pageTitle: String, url: String, tab: String, playing: Bool) -> BrowserMedia? {
        let json = (try? JSONSerialization.data(withJSONObject: ["title": pageTitle, "url": url, "p": playing]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return parse(json, tab: tab)
    }

    static func youTubeID(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let host = components.host else { return nil }
        if host.hasSuffix("youtu.be") { return components.path.split(separator: "/").first.map(String.init) }
        guard host.contains("youtube.com") else { return nil }
        return components.queryItems?.first { $0.name == "v" }?.value
    }

    static func site(_ url: String) -> String {
        guard let host = URLComponents(string: url)?.host else { return "" }
        if host.contains("music.youtube") { return "YouTube Music" }
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("soundcloud") { return "SoundCloud" }
        if host.contains("spotify") { return "Spotify Web" }
        if host.contains("twitch") { return "Twitch" }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

/// Play or pause pressed in the notch, trusted until the player confirms it.
/// Browsers keep their audio stream open for a few seconds after pausing, so
/// "still making sound" right after a pause doesn't mean it's still playing.
public struct PlaybackIntent: Sendable {
    public static let window: TimeInterval = 8

    private var expected: Bool?
    private var since = Date.distantPast

    public init() {}

    public mutating func pressed(playing: Bool, at date: Date) {
        expected = playing
        since = date
    }

    /// The state to show, given what the player looks like right now.
    public mutating func resolve(observed: Bool, now: Date) -> Bool {
        guard let expected, now.timeIntervalSince(since) < Self.window else {
            self.expected = nil
            return observed
        }
        // Confirmed: from here on, what the player says goes.
        if observed == expected { self.expected = nil }
        return expected
    }
}

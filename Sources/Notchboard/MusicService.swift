import AppKit
import CoreAudio
import NotchboardCore

/// Now playing and playback controls for Spotify, Apple Music and browsers.
///
/// - Spotify and Music announce every change with a distributed notification,
///   so they are never polled.
/// - Browsers announce nothing. Core Audio says (cheaply, without permission)
///   which browser is making sound; only then is that browser asked, through
///   AppleScript, which media tab is playing and what.
///
/// AppleScript runs on a background queue, and only against apps that are
/// already running: scripting a closed app would launch it.
@MainActor
final class MusicService {
    private let model: AppModel
    private let scripts = DispatchQueue(label: "notchboard.music", qos: .userInitiated)
    private var timers: [Timer] = []
    private var artworkKey: String?

    /// The latest state from each kind of source; the notch shows one of them.
    private var native: NowPlaying?
    private var browser: NowPlaying?
    private var browserBusy = false
    private var lastBrowserCheck = Date.distantPast
    private var audible: Set<String> = []

    private nonisolated static let nativeIDs: [NowPlaying.Source: String] = [.spotify: "com.spotify.client", .music: "com.apple.Music"]

    /// Chromium-family browsers share one AppleScript dictionary (tabs with
    /// URL/title, "execute javascript"); Safari has its own.
    nonisolated static let chromium = ["com.google.Chrome", "com.google.Chrome.beta", "company.thebrowser.Browser",
                                       "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac",
                                       "com.vivaldi.Vivaldi"]
    nonisolated static let safari = "com.apple.Safari"

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNative(.spotify) }
        }
        center.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNative(.music) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appQuit(id) }
        }
        for source in [NowPlaying.Source.music, .spotify] where Self.isRunning(Self.nativeIDs[source]!) { refreshNative(source) }

        // Core Audio is a microsecond-cheap check, so it can run every second.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioTick() }
        })
        // Catch seeks and drift in native players while playing; skipped when paused.
        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let native = self.native, native.isPlaying else { return }
                self.refreshNative(native.source)
            }
        })
        timers[0].tolerance = 0.3
        timers[1].tolerance = 2
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func appQuit(_ id: String?) {
        guard let id else { return }
        if let native, Self.nativeIDs[native.source] == id { self.native = nil }
        if case .browser(let browserID, _, _) = browser?.source, browserID == id { browser = nil }
        show()
    }

    /// Picks what to show: whatever is playing (the browser wins a tie, since
    /// it was started more recently in practice), else the last thing seen.
    private func show() {
        let pick: NowPlaying?
        switch (native, browser) {
        case let (n?, b?): pick = b.isPlaying || !n.isPlaying ? b : n
        case let (n, b): pick = n ?? b
        }
        if pick != model.nowPlaying { model.nowPlaying = pick }
        guard let pick else {
            artworkKey = nil
            model.artwork = nil
            return
        }
        let key = "\(pick.sourceName)|\(pick.title)|\(pick.album)"
        if key != artworkKey {
            artworkKey = key
            model.artwork = nil
            loadArtwork(for: pick, key: key)
        }
    }

    // MARK: Spotify and Music

    private func refreshNative(_ source: NowPlaying.Source) {
        guard let id = Self.nativeIDs[source], Self.isRunning(id) else { return }
        scripts.async {
            let state = Self.readNative(source)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let state {
                        // Don't let a paused app replace one that is playing.
                        if let native = self.native, native.source != source, native.isPlaying, !state.isPlaying { return }
                        self.native = state
                    } else if self.native?.source == source {
                        self.native = nil
                    }
                    self.show()
                }
            }
        }
    }

    private nonisolated static func readNative(_ source: NowPlaying.Source) -> NowPlaying? {
        guard let id = nativeIDs[source] else { return nil }
        // Spotify reports duration in milliseconds, Music in seconds.
        let script = """
        tell application id "\(id)"
          set s to player state as string
          if s is "stopped" then return {s}
          set t to current track
          return {s, name of t as string, artist of t as string, album of t as string, duration of t, player position}
        end tell
        """
        guard let list = run(script).result, list.numberOfItems >= 6,
              let state = list.atIndex(1)?.stringValue else { return nil }
        var duration = list.atIndex(5)?.doubleValue ?? 0
        if source == .spotify { duration /= 1000 }
        return NowPlaying(source: source, sourceName: source == .spotify ? "Spotify" : "Music",
                          title: list.atIndex(2)?.stringValue ?? "",
                          artist: list.atIndex(3)?.stringValue ?? "",
                          album: list.atIndex(4)?.stringValue ?? "",
                          duration: duration,
                          position: list.atIndex(6)?.doubleValue ?? 0,
                          positionAt: Date(),
                          isPlaying: state == "playing")
    }

    // MARK: Browsers

    private func audioTick() {
        let now = Self.audibleBrowsers()
        let changed = now != audible
        audible = now
        // Ask a browser only when it starts or stops making sound, every few
        // seconds while it plays (new track), and now and then while a paused
        // tab is shown (it may have been closed).
        let since = Date().timeIntervalSince(lastBrowserCheck)
        let showing = browser != nil
        if changed || (!now.isEmpty && since >= 4) || (showing && since >= 15) {
            refreshBrowsers(audible: now)
        }
    }

    private func refreshBrowsers(audible: Set<String>) {
        guard !browserBusy else { return }
        // Browsers making sound first, then the one already shown.
        var targets = Array(audible).sorted()
        if case .browser(let id, _, _) = browser?.source, !targets.contains(id), Self.isRunning(id) { targets.append(id) }
        guard !targets.isEmpty else {
            if browser?.isPlaying == true, var paused = browser {
                paused.position = paused.position(at: Date())
                paused.positionAt = Date()
                paused.isPlaying = false
                browser = paused
                show()
            }
            return
        }
        browserBusy = true
        lastBrowserCheck = Date()
        scripts.async {
            var found: NowPlaying?
            for id in targets {
                let state = Self.readBrowser(id, audible: audible.contains(id))
                if let state, found == nil || (state.isPlaying && found?.isPlaying != true) { found = state }
                if found?.isPlaying == true { break }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.browserBusy = false
                    self.browser = found
                    self.show()
                }
            }
        }
    }

    /// Which browsers are sending sound to an output right now. Browsers play
    /// from helper processes whose bundle ids don't name the browser (Arc and
    /// Dia share "company.thebrowser.browser.helper"), so each helper is traced
    /// to the app bundle it lives in. Safari plays from WebKit's system GPU
    /// process, which is attributed to Safari when Safari is running.
    private static func audibleBrowsers() -> Set<String> {
        var found = Set<String>()
        for process in audioOutputProcesses() {
            if let app = owningApp(pid: process.pid), chromium.contains(app) || app == safari {
                found.insert(app)
            } else if process.bundleID.hasPrefix("com.apple.WebKit") && isRunning(safari) {
                found.insert(safari)
            }
        }
        return found
    }

    /// The bundle id of the outermost .app containing a process's executable.
    private static func owningApp(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        return Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
    }

    private static func audioOutputProcesses() -> [(pid: pid_t, bundleID: String)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return processes.compactMap { process in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                            mScope: kAudioObjectPropertyScopeGlobal,
                                                            mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { return nil }
            var bundleID: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var idAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            let id = AudioObjectGetPropertyData(process, &idAddress, 0, nil, &idSize, &bundleID) == noErr
                ? (bundleID?.takeRetainedValue() as String?) ?? "" : ""
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid)
            return (pid, id)
        }
    }

    /// Error AppleScript raises when the browser's "Allow JavaScript from Apple Events" is off.
    private nonisolated static func scriptsBlocked(_ error: NSDictionary?) -> Bool {
        let message = (error?[NSAppleScript.errorMessage] as? String ?? "").lowercased()
        return message.contains("javascript") || message.contains("apple events")
    }

    /// Finds the media tab in one browser. Tabs are tried on media sites only.
    private nonisolated static func readBrowser(_ id: String, audible: Bool) -> NowPlaying? {
        let name = appName(id)
        let sites = BrowserMedia.sites.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let probe = appleScriptString(BrowserMedia.probe)
        // Each match comes back as "tab reference<TAB>result".
        let script: String
        if id == safari {
            script = """
            tell application id "\(id)"
              set out to {}
              repeat with w in windows
                set urls to URL of tabs of w
                repeat with i from 1 to count of urls
                  set u to (item i of urls) as string
                  if \(sites) then set end of out to ((id of w) as string) & ":" & i & (character id 9) & (do JavaScript \(probe) in tab i of w)
                end repeat
              end repeat
              return out
            end tell
            """
        } else {
            script = """
            tell application id "\(id)"
              set out to {}
              repeat with w in windows
                set urls to URL of tabs of w
                repeat with i from 1 to count of urls
                  set u to (item i of urls) as string
                  if \(sites) then
                    set t to tab i of w
                    set end of out to ((id of t) as string) & (character id 9) & (execute t javascript \(probe))
                  end if
                end repeat
              end repeat
              return out
            end tell
            """
        }
        let (list, error) = run(script)
        if let list {
            var best: BrowserMedia?
            for i in stride(from: 1, through: list.numberOfItems, by: 1) {
                guard let line = list.atIndex(i)?.stringValue, let split = line.firstIndex(of: "\t") else { continue }
                guard let media = BrowserMedia.parse(String(line[line.index(after: split)...]), tab: String(line[..<split])) else { continue }
                if best == nil || (media.playing && best?.playing != true) { best = media }
            }
            return best.map { nowPlaying($0, browser: id, name: name, scriptable: true) }
        }
        // Scripts are off in this browser: fall back to the tab title, with
        // "playing" taken from whether the browser is making sound. A paused
        // tab stays shown (so it can be resumed) until its tab is closed.
        guard scriptsBlocked(error) else { return nil }
        let titles = """
        tell application id "\(id)"
          set out to {}
          repeat with w in windows
            set urls to URL of tabs of w
            repeat with i from 1 to count of urls
              set u to (item i of urls) as string
              if \(sites) then set end of out to u & (character id 9) & ((\(id == safari ? "name" : "title") of tab i of w) as string)
            end repeat
          end repeat
          return out
        end tell
        """
        guard let found = run(titles).result, found.numberOfItems > 0,
              let line = found.atIndex(1)?.stringValue, let split = line.firstIndex(of: "\t"),
              let media = BrowserMedia.fromTitle(String(line[line.index(after: split)...]), url: String(line[..<split]),
                                                 tab: "", playing: audible) else { return nil }
        return nowPlaying(media, browser: id, name: name, scriptable: false)
    }

    private nonisolated static func nowPlaying(_ media: BrowserMedia, browser id: String, name: String, scriptable: Bool) -> NowPlaying {
        NowPlaying(source: .browser(bundleID: id, tab: media.tab, scriptable: scriptable),
                   sourceName: media.site.isEmpty ? name : "\(name) · \(media.site)",
                   title: media.title,
                   artist: media.artist,
                   album: media.album,
                   duration: media.duration,
                   position: media.position,
                   positionAt: Date(),
                   isPlaying: media.playing,
                   artworkURL: media.artworkURL)
    }

    private nonisolated static func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "Browser" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// A Swift string as an AppleScript string literal.
    private nonisolated static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Controls

    func perform(_ command: MusicCommand) {
        guard let now = model.nowPlaying else { return }
        // Media keys need Accessibility; ask first, change nothing until granted.
        if now.usesMediaKeys, !MediaKeys.isAllowed {
            MediaKeys.requestPermission()
            return
        }
        if command == .playPause {
            // Answer instantly; the player confirms a moment later.
            var next = now
            next.position = now.position(at: Date())
            next.positionAt = Date()
            next.isPlaying.toggle()
            if case .browser = now.source { browser = next } else { native = next }
            show()
        }
        switch now.source {
        case .spotify, .music:
            let id = Self.nativeIDs[now.source]!
            let verb = command == .playPause ? "playpause" : command == .next ? "next track" : "previous track"
            scripts.async {
                _ = Self.run("tell application id \"\(id)\" to \(verb)")
                DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshNative(now.source) } }
            }
        case .browser(let id, _, false):
            MediaKeys.send(command)
            // Sound starts or stops a moment later; read the new state then.
            DispatchQueue.main.asyncAfter(deadline: .now() + (command == .playPause ? 0.6 : 1.5)) {
                MainActor.assumeIsolated { self.refreshBrowsers(audible: Self.audibleBrowsers().union(command == .playPause ? [] : [id])) }
            }
        case .browser(let id, let tab, true):
            let js = Self.appleScriptString(BrowserMedia.script(for: command == .playPause ? .playPause : command == .next ? .next : .previous))
            let script: String
            if id == Self.safari {
                let parts = tab.split(separator: ":")
                guard parts.count == 2 else { return }
                script = "tell application id \"\(id)\" to do JavaScript \(js) in tab \(parts[1]) of (first window whose id is \(parts[0]))"
            } else {
                script = """
                tell application id "\(id)"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if ((id of t) as string) is "\(tab)" then return execute t javascript \(js)
                    end repeat
                  end repeat
                end tell
                """
            }
            scripts.async {
                _ = Self.run(script)
                // Give the page a moment, then read the new state.
                DispatchQueue.main.asyncAfter(deadline: .now() + (command == .playPause ? 0.3 : 1.2)) {
                    MainActor.assumeIsolated { self.refreshBrowsers(audible: self.audible.union([id])) }
                }
            }
        }
    }

    // MARK: AppleScript and artwork (scripts queue)

    private nonisolated static func run(_ source: String) -> (result: NSAppleEventDescriptor?, error: NSDictionary?) {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (error == nil ? result : nil, error)
    }

    private func loadArtwork(for item: NowPlaying, key: String) {
        let show: @Sendable (Data?) -> Void = { data in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.artworkKey == key else { return }
                    self.model.artwork = image
                }
            }
        }
        let download: @Sendable (URL?) -> Void = { url in
            guard let url else { return show(nil) }
            URLSession.shared.dataTask(with: url) { data, _, _ in show(data) }.resume()
        }
        switch item.source {
        case .spotify:
            scripts.async {
                download(Self.run("tell application id \"com.spotify.client\" to artwork url of current track").result?
                    .stringValue.flatMap(URL.init(string:)))
            }
        case .music:
            scripts.async {
                show(Self.run("tell application id \"com.apple.Music\" to raw data of artwork 1 of current track").result?.data)
            }
        case .browser:
            download(item.artworkURL)
        }
    }
}

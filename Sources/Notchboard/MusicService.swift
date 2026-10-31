import AppKit

/// Now playing and playback controls for Spotify and Apple Music.
///
/// Both apps announce every track and play/pause change with a distributed
/// notification, so nothing is polled while music is idle. Details (position,
/// artwork) come from AppleScript on a background queue, and only for an app
/// that is already running: scripting a closed app would launch it.
@MainActor
final class MusicService {
    private let model: AppModel
    private let scripts = DispatchQueue(label: "notchboard.music", qos: .userInitiated)
    private var resync: Timer?
    private var artworkKey: String?

    private nonisolated static let ids: [NowPlaying.Player: String] = [.spotify: "com.spotify.client", .music: "com.apple.Music"]

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(.spotify) }
        }
        center.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(.music) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let player = self.model.nowPlaying?.player, Self.ids[player] == id else { return }
                self.model.nowPlaying = nil
                self.model.artwork = nil
                self.artworkKey = nil
            }
        }
        for player in [NowPlaying.Player.music, .spotify] where Self.isRunning(player) { refresh(player) }
        // Catch seeks and drift while playing; cheap, and skipped when paused.
        resync = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let now = self.model.nowPlaying, now.isPlaying else { return }
                self.refresh(now.player)
            }
        }
        resync?.tolerance = 2
    }

    private static func isRunning(_ player: NowPlaying.Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ids[player]!).isEmpty
    }

    private func refresh(_ player: NowPlaying.Player) {
        guard Self.isRunning(player) else { return }
        scripts.async {
            let state = Self.readState(player)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(state, from: player) } }
        }
    }

    private func apply(_ state: NowPlaying?, from player: NowPlaying.Player) {
        let current = model.nowPlaying
        // Don't let a paused app replace one that is playing.
        if let current, current.player != player, current.isPlaying, state?.isPlaying != true { return }
        guard let state else {
            if current?.player == player { model.nowPlaying = nil; model.artwork = nil; artworkKey = nil }
            return
        }
        if state != current { model.nowPlaying = state }
        let key = "\(player.rawValue)|\(state.title)|\(state.album)"
        if key != artworkKey {
            artworkKey = key
            loadArtwork(player, key: key)
        }
    }

    func perform(_ command: MusicCommand) {
        guard let now = model.nowPlaying else { return }
        let verb: String
        switch command {
        case .playPause:
            verb = "playpause"
            // Answer instantly; the app's notification confirms a moment later.
            var next = now
            next.position = now.position(at: Date())
            next.positionAt = Date()
            next.isPlaying.toggle()
            model.nowPlaying = next
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        let player = now.player
        scripts.async {
            _ = Self.run("tell application id \"\(Self.ids[player]!)\" to \(verb)")
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh(player) } }
        }
    }

    // MARK: AppleScript (scripts queue only)

    private nonisolated static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private nonisolated static func readState(_ player: NowPlaying.Player) -> NowPlaying? {
        let id = ids[player]!
        // Spotify reports duration in milliseconds, Music in seconds.
        let source = """
        tell application id "\(id)"
          set s to player state as string
          if s is "stopped" then return {s}
          set t to current track
          return {s, name of t as string, artist of t as string, album of t as string, duration of t, player position}
        end tell
        """
        guard let list = run(source), list.numberOfItems >= 6,
              let state = list.atIndex(1)?.stringValue else { return nil }
        var duration = list.atIndex(5)?.doubleValue ?? 0
        if player == .spotify { duration /= 1000 }
        return NowPlaying(player: player,
                          title: list.atIndex(2)?.stringValue ?? "",
                          artist: list.atIndex(3)?.stringValue ?? "",
                          album: list.atIndex(4)?.stringValue ?? "",
                          duration: duration,
                          position: list.atIndex(6)?.doubleValue ?? 0,
                          positionAt: Date(),
                          isPlaying: state == "playing")
    }

    private func loadArtwork(_ player: NowPlaying.Player, key: String) {
        let show: @Sendable (Data?) -> Void = { data in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.artworkKey == key else { return }
                    self.model.artwork = image
                }
            }
        }
        scripts.async {
            switch player {
            case .spotify:
                // Download off the script queue so play/pause never waits on the network.
                guard let url = Self.run("tell application id \"com.spotify.client\" to artwork url of current track")?
                    .stringValue.flatMap(URL.init(string:)) else { return show(nil) }
                URLSession.shared.dataTask(with: url) { data, _, _ in show(data) }.resume()
            case .music:
                show(Self.run("tell application id \"com.apple.Music\" to raw data of artwork 1 of current track")?.data)
            }
        }
    }
}

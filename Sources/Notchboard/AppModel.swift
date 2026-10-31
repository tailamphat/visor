import AppKit
import NotchboardCore
import Observation

enum Tab: String, CaseIterable {
    case agents, usage, music

    var symbol: String {
        switch self {
        case .agents: return "sparkles"
        case .usage: return "gauge.with.dots.needle.50percent"
        case .music: return "music.note"
        }
    }
}

struct NowPlaying: Equatable {
    enum Source: Hashable {
        case spotify, music
        /// A browser tab. `tab` is the browser's tab reference; `scriptable` is
        /// false when the browser doesn't allow JavaScript from Apple Events.
        case browser(bundleID: String, tab: String, scriptable: Bool)
    }
    var source: Source
    /// Shown under the controls, e.g. "Spotify" or "Chrome · YouTube".
    var sourceName: String
    var title: String
    var artist: String
    var album: String
    /// Seconds; 0 when unknown.
    var duration: Double
    var position: Double
    /// When `position` was read, so progress can run on locally.
    var positionAt: Date
    var isPlaying: Bool
    /// Browsers: artwork from the page (Media Session or the YouTube thumbnail).
    var artworkURL: URL? = nil

    /// A browser that can't be scripted is controlled with the media keys,
    /// which go to whatever macOS considers the Now Playing app.
    var usesMediaKeys: Bool {
        if case .browser(_, _, let scriptable) = source { return !scriptable }
        return false
    }

    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        let now = position + date.timeIntervalSince(positionAt)
        return duration > 0 ? min(duration, now) : now
    }
}

/// Everything the notch shows. Lives on the main thread; services feed it.
@MainActor @Observable
final class AppModel {
    // Notch state
    var expanded = false
    var tab: Tab = .agents
    /// Keeps the panel open regardless of the pointer (debug screenshots).
    var pinned = false

    // Agents
    var board = AgentBoard()
    var approvals: [ApprovalRequest] = []
    var hooksInstalled = false
    /// Briefly true after an agent finishes, for the check mark in the notch.
    var justFinished = false

    // Usage
    var plan: PlanUsage?
    var planName: String?
    var planError: String?
    var planUpdated: Date?
    var spend: SpendSummary?

    // Music
    var nowPlaying: NowPlaying?
    var artwork: NSImage?
    /// The artwork's colour, for the music panel's glow.
    var artworkTint: NSColor?
    /// Blurred artwork behind the music panel.
    var artworkBackdrop: NSImage?
    /// System output volume, 0...1; nil until read.
    var volume: Double?

    /// Set by the hook server; answers an approval.
    var decide: ((ApprovalRequest, ApprovalRequest.Decision?) -> Void)?
    var musicCommand: ((MusicCommand) -> Void)?
    var setVolume: ((Double) -> Void)?
    var refreshVolume: (() -> Void)?
    var installHooks: (() -> Void)?
    var refreshPlan: (() -> Void)?

    var hasActivity: Bool { board.working + board.waiting > 0 || !approvals.isEmpty }
    var isPlaying: Bool { nowPlaying?.isPlaying == true }
    /// The music panel is the one showing (an approval card takes over otherwise).
    var showsMusic: Bool { expanded && tab == .music && approvals.isEmpty }
}

enum MusicCommand { case playPause, next, previous }

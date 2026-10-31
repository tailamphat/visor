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
    enum Player: String { case spotify = "Spotify", music = "Music" }
    var player: Player
    var title: String
    var artist: String
    var album: String
    /// Seconds.
    var duration: Double
    var position: Double
    /// When `position` was read, so progress can run on locally.
    var positionAt: Date
    var isPlaying: Bool

    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + date.timeIntervalSince(positionAt))
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

    /// Set by the hook server; answers an approval.
    var decide: ((ApprovalRequest, ApprovalRequest.Decision?) -> Void)?
    var musicCommand: ((MusicCommand) -> Void)?
    var installHooks: (() -> Void)?
    var refreshPlan: (() -> Void)?

    var hasActivity: Bool { board.working + board.waiting > 0 || !approvals.isEmpty }
    var isPlaying: Bool { nowPlaying?.isPlaying == true }
}

enum MusicCommand { case playPause, next, previous }

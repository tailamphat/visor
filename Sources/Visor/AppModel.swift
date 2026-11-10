import AppKit
import SwiftUI
import VisorCore
import Observation

enum Tab: String, CaseIterable {
    case agents, usage, music, bar, clipboard

    var symbol: String {
        switch self {
        case .agents: return "sparkles"
        case .usage: return "gauge.with.dots.needle.50percent"
        case .music: return "music.note"
        case .bar: return "square.grid.2x2"
        case .clipboard: return "doc.on.clipboard"
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

    /// The spend chart's day under the pointer, if any.
    var spendHover: Int?
    /// The OpenCode tokens chart's day under the pointer, if any.
    var openCodeHover: Int?

    // Agents
    var board = AgentBoard()
    var approvals: [ApprovalRequest] = []
    var hooksInstalled = false
    var antigravityHooksInstalled = false
    /// A few seconds of news in the closed notch: an agent finished, or a question was answered.
    var peek: Peek?

    // Usage
    var plan: PlanUsage?
    var planName: String?
    var planError: String?
    var planUpdated: Date?
    var spend: SpendSummary?
    /// Copilot plans with premium requests, company (*.ghe.com) first.
    var copilot: [CopilotUsage] = []
    /// Antigravity quotas, read on demand from `agy -p /usage`.
    var antigravity: AntigravityUsage?
    var antigravityError: String?
    var antigravityUpdated: Date?
    var antigravityLoading = false
    /// OpenCode's local token usage and cost, from its SQLite database.
    var openCode: OpenCodeUsage?
    var openCodeError: String?
    var openCodeUpdated: Date?
    /// OpenCode Go limits, when the user signed in with a Go key.
    var openCodeGo: OpenCodeGoUsage?

    /// Connected agent quotas displayed side-by-side in the closed notch's right ear.
    var quotas: [NotchQuota] {
        NotchQuotaSummary.make(plan: plan, antigravity: antigravity, copilot: copilot, openCode: openCodeGo)
    }

    // Clipboard
    var clips = ClipHistory()
    /// Typed while the clipboard tab is open: filters the history.
    var clipQuery = ""
    /// The row arrows move and Return pastes.
    var clipSelection: UUID?
    /// The row under the pointer, which shows its delete button.
    var clipHover: UUID?
    /// "Deleted…" while undo is possible.
    var clipUndo: String?
    /// The clipboard tab has the keyboard: typing goes to the search, which shows a caret.
    var clipTyping = false
    /// Gives the clipboard tab the keyboard (a click on the search).
    var focusClipSearch: (() -> Void)?
    var clipboardActions: ClipboardService?
    /// Pastes into the app you were using (closes the notch first).
    var pasteClip: ((ClipItem, Bool) -> Void)?

    // Bar
    var bar = BarLayout()
    /// Something is being dragged over the bar (highlights the drop area).
    var barTargeted = false
    /// The tile something is being dragged onto.
    var barTargetTile: UUID?
    var shortcutNames: [String] = []
    var cpuUsage: Double?
    var battery: (percent: Int, charging: Bool)?
    /// A running timer ends at this date; a paused one keeps its time left.
    var timerEnds: Date?
    var timerPaused: TimeInterval?
    var barActions: BarService?

    /// Host app icons by name ("Ghostty"), for the closed notch.
    var hostIcons: [String: NSImage] = [:]

    // Music
    var nowPlaying: NowPlaying?
    var artwork: NSImage?
    /// The artwork's colour, for the music panel's glow.
    var artworkTint: NSColor?
    /// Blurred artwork behind the music panel.
    var artworkBackdrop: NSImage?
    /// Whether the media keys can be pressed (Accessibility permission).
    var mediaKeysAllowed = MediaKeys.isAllowed
    /// System output volume, 0...1; nil until read.
    var volume: Double?

    /// Set by the hook server; answers an approval.
    var decide: ((ApprovalRequest, ApprovalRequest.Decision?) -> Void)?
    /// Brings an agent's terminal forward, where it asks or works.
    var focusAgent: ((AgentSession) -> Void)?
    var musicCommand: ((MusicCommand) -> Void)?
    var setVolume: ((Double) -> Void)?
    var refreshVolume: (() -> Void)?
    var installHooks: (() -> Void)?
    var refreshPlan: (() -> Void)?

    var hasActivity: Bool { board.working + board.waiting > 0 || !approvals.isEmpty }
    var isPlaying: Bool { nowPlaying?.isPlaying == true }
    /// An approval card has the panel; it stays open until dealt with.
    var showsCard: Bool { !approvals.isEmpty }
    /// The music panel is the one showing (a card takes over otherwise).
    var showsMusic: Bool { expanded && tab == .music && !showsCard }

    /// What the closed notch's right side shows when someone needs you: the
    /// app to go to, badged "!" (approve) or "?" (answer). An approval outranks a question.
    var attentionNote: (kind: Attention, help: String, icon: NSImage?)? {
        let approving = board.sessions.filter { session in
            session.state.attention == .approval || approvals.contains { $0.sessionID == session.id }
        }
        if !approvals.isEmpty || !approving.isEmpty {
            let host = approving.lazy.compactMap(\.host).first
            return (.approval, host.map { "Approve: \($0)" } ?? "Approve", host.flatMap { hostIcons[$0] })
        }
        let asking = board.sessions.filter { $0.state.attention == .question }
        guard !asking.isEmpty else { return nil }
        // Only point at an app when every asking session is in a known one.
        if let host = asking.lazy.compactMap(\.host).first, asking.allSatisfy({ $0.host != nil }) {
            return (.question, "In \(host)", hostIcons[host])
        }
        return (.question, "Question", nil)
    }
}

/// News the closed notch shows for a few seconds.
enum Peek: Equatable {
    case done(FinishedTurn)
    case answered(agent: String)
}

enum MusicCommand { case playPause, next, previous }

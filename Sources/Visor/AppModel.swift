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

    // Agents
    var board = AgentBoard()
    var approvals: [ApprovalRequest] = []
    /// Questions agents asked, answered in the terminal; the card shows until handed off.
    var questions: [AgentQuestion] = []
    /// Sessions whose question was handed to the terminal, by session id: the host app's name.
    var handedOff: [String: String] = [:]
    /// Questions Visor can answer: their held permission step, by session id.
    var questionHolds: [String: ApprovalRequest] = [:]
    /// Options picked on the open card, per question index.
    var questionPicks: [Int: Set<Int>] = [:] { didSet { if questionPicks.isEmpty { questionPage = 0 } } }
    /// Which of the open card's questions shows.
    var questionPage = 0
    var hooksInstalled = false
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
    /// Hands a question to the terminal; true also brings the terminal to the front.
    var handOff: ((AgentQuestion, Bool) -> Void)?
    /// Sends the picked options as the answer.
    var answer: ((AgentQuestion) -> Void)?
    var musicCommand: ((MusicCommand) -> Void)?
    var setVolume: ((Double) -> Void)?
    var refreshVolume: (() -> Void)?
    var installHooks: (() -> Void)?
    var refreshPlan: (() -> Void)?

    var hasActivity: Bool { board.working + board.waiting > 0 || !approvals.isEmpty }
    var isPlaying: Bool { nowPlaying?.isPlaying == true }
    /// The question card to show, if any (one not yet handed to the terminal).
    var openQuestion: AgentQuestion? { questions.first { handedOff[$0.sessionID] == nil } }
    /// An approval or question card has the panel; it stays open until dealt with.
    var showsCard: Bool { !approvals.isEmpty || openQuestion != nil }
    /// The music panel is the one showing (a card takes over otherwise).
    var showsMusic: Bool { expanded && tab == .music && !showsCard }

    /// What the closed notch says beside the agent marks when someone needs you.
    var attentionNote: (text: String, color: Color)? {
        if !approvals.isEmpty || board.sessions.contains(where: { $0.state.attention == .approval }) {
            return ("Approve", Theme.warning)
        }
        let asking = board.sessions.filter { $0.state.attention == .question }
        guard !asking.isEmpty else { return nil }
        if let host = asking.lazy.compactMap({ self.handedOff[$0.id] }).first, asking.allSatisfy({ self.handedOff[$0.id] != nil }) {
            return ("In \(host)", Theme.question.opacity(0.75))
        }
        return ("Question", Theme.question)
    }
}

/// News the closed notch shows for a few seconds.
enum Peek: Equatable {
    case done(FinishedTurn)
    case answered(agent: String)
}

enum MusicCommand { case playPause, next, previous }

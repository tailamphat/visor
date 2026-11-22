import AppKit
import SwiftUI
import VisorCore
import Observation

enum TokensPage: String, CaseIterable {
    case overview, models, daily, tools
}

enum Tab: String, CaseIterable {
    case agents, usage, music, bar, clipboard, plugins

    var symbol: String {
        switch self {
        case .agents: return "sparkles"
        case .usage: return "gauge.with.dots.needle.50percent"
        case .music: return "music.note"
        case .bar: return "square.grid.2x2"
        case .clipboard: return "doc.on.clipboard"
        case .plugins: return "puzzlepiece.extension"
        }
    }

    /// The puzzle piece is wide and short; drawn a little larger it matches the
    /// other icons' height and weight.
    var symbolSize: CGFloat { self == .plugins ? 13.5 : 12 }

    /// The tabs in the top bar. Bar is hidden for now; its code stays so it can come back.
    /// Plugins sits on the right of the notch, once a plugin is installed.
    static let shown: [Tab] = [.agents, .usage, .music, .clipboard]
}

struct NowPlaying: Equatable {
    enum Source: Hashable {
        case spotify, music
        /// A browser tab. `tab` is the browser's tab reference; `scriptable` is
        /// false when the browser doesn't allow JavaScript from Apple Events.
        case browser(bundleID: String, tab: String, scriptable: Bool)
        /// A tab reported by the Visor Media extension in the browser `bundleID`.
        case `extension`(bundleID: String, tab: String)
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
    /// False when Visor can't tell playing from paused (a browser without page
    /// scripts that is also in a call): the notch shows a neutral play/pause.
    var stateKnown = true
    /// Browsers: artwork from the page (Media Session or the YouTube thumbnail).
    var artworkURL: URL? = nil

    /// Pause while playing, play while paused, both when unknown.
    var playPauseSymbol: String { !stateKnown ? "playpause.fill" : isPlaying ? "pause.fill" : "play.fill" }
    /// Equalizer bars move only when it's surely playing.
    var surelyPlaying: Bool { stateKnown && isPlaying }

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
    var expanded = false {
        // The turn summary is for the moment it finished; once the notch closes it's gone.
        didSet { if !expanded && oldValue { summary = nil; helpersOpen = nil; radarPlans = false } }
    }
    /// A turn that just finished, shown as its summary when the notch opens
    /// during its "done" peek.
    var summary: FinishedTurn?
    /// Opens a diff of the files a turn changed.
    var viewDiff: ((FinishedTurn) -> Void)?
    var tab: Tab = .agents
    /// Keeps the panel open regardless of the pointer (debug screenshots).
    var pinned = false
    /// The first-launch hello is in the open notch, until "Get started".
    var welcome = false
    /// The hello's title has come into focus (its entrance animation ran).
    var welcomeSettled = false

    /// "Get started": the hello goes and the notch closes.
    func dismissWelcome() {
        welcome = false
        pinned = false
        expanded = false
    }

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
    /// A used-up limit that just reset: the open notch shows it for a few seconds.
    var limitBack: LimitReturn?
    /// Newer releases of installed tools, shown in Usage until dismissed.
    var releaseOffers: [ReleaseUpdate] = []
    var dismissRelease: ((ReleaseUpdate) -> Void)?
    var updateRelease: ((ReleaseUpdate) -> Void)?
    /// Opened from a release peek: Usage shows plans (the card) this time, without
    /// changing the saved Tokens choice.
    var radarPlans = false
    /// Usage shows Tokens: the saved choice, unless a release peek opened it.
    var showsTokens: Bool { usageTokens && !radarPlans }

    // Usage
    var plan: PlanUsage? {
        didSet { plan?.limits.forEach { usageHistory.record(UsageKey.claude($0.kind), used: $0.percentUsed) } }
    }
    var planName: String?
    var planError: String?
    var planUpdated: Date?
    var spend: SpendSummary?
    /// Copilot plans with premium requests, company (*.ghe.com) first.
    var copilot: [CopilotUsage] = [] {
        didSet {
            for usage in copilot where usage.isTracked && !usage.premiumUnlimited {
                usageHistory.record(UsageKey.copilot(usage.host), used: 100 - usage.percentLeft)
            }
        }
    }
    /// Antigravity quotas, read on demand from `agy -p /usage`.
    var antigravity: AntigravityUsage? {
        didSet { antigravity?.limits.forEach { usageHistory.record(UsageKey.antigravity($0.id), used: $0.percentUsed) } }
    }
    var antigravityError: String?
    var antigravityUpdated: Date?
    var antigravityLoading = false
    /// OpenCode's local token usage and cost, from its SQLite database.
    var openCode: OpenCodeUsage?
    var openCodeError: String?
    var openCodeUpdated: Date?
    /// OpenCode Go limits, when the user signed in with a Go key.
    var openCodeGo: OpenCodeGoUsage? {
        didSet { openCodeGo?.limits.forEach { usageHistory.record(UsageKey.openCode($0.id), used: $0.percentUsed) } }
    }
    /// Recent readings of every limit, for the burn-rate forecasts.
    @ObservationIgnored var usageHistory = UsageHistory()

    /// When a limit runs out at the current pace, or what's left at its reset.
    func forecast(_ key: String, used: Double, resetsAt: Date?, window: TimeInterval?) -> BurnForecast? {
        BurnForecast.make(used: used, resetsAt: resetsAt, window: window, history: usageHistory.samples(key))
    }

    /// Connected agent quotas displayed side-by-side in the closed notch's right ear.
    var quotas: [NotchQuota] {
        NotchQuotaSummary.make(plan: plan, antigravity: antigravity, copilot: copilot, openCode: openCodeGo,
                               forecast: forecast)
            .filter { quota in ConnectionProvider.allCases.contains { $0.agent == quota.agent && shows($0) } }
            .enumerated()
            .sorted { a, b in
                let ia = providerOrder.firstIndex { $0.agent == a.element.agent } ?? 0
                let ib = providerOrder.firstIndex { $0.agent == b.element.agent } ?? 0
                return ia != ib ? ia < ib : a.offset < b.offset
            }
            .map(\.element)
    }

    // Connected accounts
    /// The Usage tab shows the accounts list instead of the numbers.
    var showAccounts = false

    // Plugins
    /// Every plugin found in the Plugins folder, running or not.
    var plugins: [PluginInfo] = []
    /// Plugins switched off; remembered.
    var disabledPlugins = Set(UserDefaults.standard.stringArray(forKey: "disabledPlugins") ?? []) {
        didSet { UserDefaults.standard.set(disabledPlugins.sorted(), forKey: "disabledPlugins") }
    }
    var pluginActions: PluginService?
    /// The plugin row under the pointer.
    var pluginHover: String?
    /// The Plugins tab's measured content height, for the panel's size.
    var pluginsContentHeight: CGFloat = 0
    /// A picker's choice, shown at once while the plugin handles it ("<plugin>/<action>").
    var pluginChoices: [String: String] = [:]
    /// The badges plugins want on the closed notch.
    var pluginBadges: [PluginBadge] { plugins.compactMap(\.output.badge) }
    /// The Agents tab as an office of little people instead of a list; remembered.
    var agentsOffice = UserDefaults.standard.bool(forKey: "agentsOffice") {
        didSet { UserDefaults.standard.set(agentsOffice, forKey: "agentsOffice") }
    }
    /// Keep awake: Auto (while agents work), On or Off; and its two settings. Remembered.
    var awakeMode = KeepAwake.Mode(saved: UserDefaults.standard.string(forKey: "awakeMode")) {
        didSet { UserDefaults.standard.set(awakeMode.rawValue, forKey: "awakeMode"); awakeChanged?() }
    }
    /// On by default: with only the Mac awake, the display still sleeps and the screen locks.
    var awakeScreen = UserDefaults.standard.object(forKey: "awakeScreen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(awakeScreen, forKey: "awakeScreen"); awakeChanged?() }
    }
    var awakeBatteryLimit = UserDefaults.standard.object(forKey: "awakeBatteryLimit") as? Bool ?? true {
        didSet { UserDefaults.standard.set(awakeBatteryLimit, forKey: "awakeBatteryLimit"); awakeChanged?() }
    }
    /// Visor is holding off sleep right now.
    var keepingAwake = false
    var awakeChanged: (() -> Void)?
    /// Open incidents on the tools you use, by agent ("Claude Code", "Copilot CLI").
    var incidents: [String: ProviderIncident] = [:]
    /// Sessions changing the same file right now (`ClashWatch`), newest first.
    var clashes: [Clash] = []
    var dismissClash: ((Clash) -> Void)?
    /// The Agents list's one clock: every card's time reads it, and one timer
    /// moves it each second only while the list is on screen.
    var agentsNow = Date()
    /// The Agents list shows every session, past the cap of 8 cards.
    var agentsShowAll = false
    /// The session whose subagents are listed under the cards (its ⑂ button).
    var helpersOpen: String?
    /// The office's world picker is open over the room.
    var officePicker = false
    /// How the office looks: the night studio or a film world; remembered.
    var officeWorld = OfficeWorld(saved: UserDefaults.standard.string(forKey: "officeWorld")) {
        didSet { UserDefaults.standard.set(officeWorld.rawValue, forKey: "officeWorld") }
    }
    /// The Usage tab's Tokens view instead of plan limits; remembered.
    var usageTokens = UserDefaults.standard.bool(forKey: "usageTokens") {
        didSet { UserDefaults.standard.set(usageTokens, forKey: "usageTokens") }
    }
    /// Every token used, by day, tool and model.
    var tokenLedger = TokenLedger()
    /// The Tokens view's page, range (days; nil for all time) and the chart day under the pointer.
    var tokensPage: TokensPage = .overview
    var tokensRange: Int? = nil
    var tokensHover: String?
    /// Whether the Agents tab shows the office right now: chosen, and someone to show.
    var showsOffice: Bool { tab == .agents && agentsOffice && !board.sessions.isEmpty }
    /// What the last read of Claude Code's sign-in found; nil until it finishes.
    var claudeLookup: KeychainLookup?
    var claudeUsesAPIKey = false
    var claudeInstalled = true
    var copilotInstalled = false
    var copilotAccounts = 0
    var copilotDenied = false
    /// Why any Copilot account couldn't be read.
    var copilotProblems: [CopilotProblem] = []
    var antigravityInstalled = false
    var openCodeInstalled = false
    /// Tools switched off under Connected accounts: not read, not shown.
    var hiddenProviders = ConnectionProvider.hidden(from: UserDefaults.standard.stringArray(forKey: "hiddenProviders") ?? []) {
        didSet { UserDefaults.standard.set(ConnectionProvider.store(hiddenProviders), forKey: "hiddenProviders") }
    }
    /// Connected accounts actions, wired by the app delegate.
    var connectionAction: ((ConnectionProvider, ConnectionState.Action) -> Void)?

    /// Switched on under Connected accounts.
    func chosen(_ provider: ConnectionProvider) -> Bool { !hiddenProviders.contains(provider) }

    /// The tools' order, set by dragging under Connected accounts; used by Usage and the closed notch.
    var providerOrder = ConnectionProvider.order(from: UserDefaults.standard.stringArray(forKey: "providerOrder") ?? []) {
        didSet { UserDefaults.standard.set(providerOrder.map(\.rawValue), forKey: "providerOrder") }
    }
    /// The tools the Usage tab shows a section for, in order: chosen, installed and with something to show.
    var usageSections: [ConnectionProvider] {
        providerOrder.filter(shows).filter(hasContent)
    }

    /// Whether a provider has numbers, an error or a loading state to show.
    func hasContent(_ provider: ConnectionProvider) -> Bool {
        switch provider {
        case .claude: return true
        case .copilot: return !copilot.isEmpty
        case .antigravity: return antigravity != nil || antigravityError != nil || antigravityLoading
        case .openCode: return openCode != nil || openCodeGo != nil || openCodeError != nil
        }
    }
    /// The Connected accounts row being dragged, and how far.
    var accountsDrag: (provider: ConnectionProvider, translation: CGFloat)?

    func installed(_ provider: ConnectionProvider) -> Bool {
        switch provider {
        case .claude: return claudeInstalled
        case .copilot: return copilotInstalled
        case .antigravity: return antigravityInstalled
        case .openCode: return openCodeInstalled
        }
    }

    /// Read and shown: switched on, and on this Mac. A tool that isn't installed stays out of
    /// the Usage tab and the notch; Connected accounts still lists it as not installed.
    func shows(_ provider: ConnectionProvider) -> Bool { chosen(provider) && installed(provider) }

    func connection(_ provider: ConnectionProvider) -> ConnectionState {
        switch provider {
        case .claude:
            if !claudeInstalled { return .notInstalled }
            return .claude(lookup: claudeLookup, usesAPIKey: claudeUsesAPIKey, planLoaded: plan != nil,
                           planName: planName, error: planError)
        case .copilot:
            return .copilot(installed: copilotInstalled, accounts: copilotAccounts, usage: copilot, denied: copilotDenied,
                            problems: copilotProblems)
        case .antigravity:
            return .antigravity(installed: antigravityInstalled, loaded: antigravity != nil, error: antigravityError)
        case .openCode:
            return .openCode(installed: openCodeInstalled, local: openCode != nil, go: openCodeGo != nil)
        }
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

    /// What each side of the closed notch shows, measured by the view, so
    /// the sides can be sized with the same inset around anything.
    var leftEarContent: CGFloat = 0
    var rightEarContent: CGFloat = 0

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
    /// Now Playing in its compact panel. The full one stays while the media keys
    /// still need permission, so the hint has room.
    var compactMusic: Bool {
        guard tab == .music, approvals.isEmpty, let now = nowPlaying else { return false }
        return !(now.usesMediaKeys && !mediaKeysAllowed) && exactControlBrowser == nil
    }

    /// Now Playing has the panel: it's narrow, with the tabs split around the camera.
    var narrowMusic: Bool {
        tab == .music && approvals.isEmpty && limitBack == nil && nowPlaying != nil
    }

    /// The browser Visor can reopen with page access, so play, pause and the
    /// icon are exact (Dia without its launch flag). nil when not offered.
    var exactControlBrowser: String? {
        guard !exactControlDismissed, let now = nowPlaying, case .browser(let id, _, false) = now.source,
              BrowserMedia.exactControlArguments(for: id) != nil else { return nil }
        return now.sourceName.components(separatedBy: " · ").first
    }
    var exactControlDismissed = UserDefaults.standard.bool(forKey: "exactControlDismissed") {
        didSet { UserDefaults.standard.set(exactControlDismissed, forKey: "exactControlDismissed") }
    }
    /// The browser is being quit and reopened.
    var exactControlBusy = false
    var enableExactControl: (() -> Void)?

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
    /// News from a plugin: its icon (or the peek's) on the left, the title on the right.
    case plugin(icon: String, PluginPeek)
    /// Two sessions just changed the same file.
    case clash(Clash)
    /// A provider's status page reports an incident on a tool you use.
    case status(agent: String, ProviderIncident)
    /// A tool installed on this Mac has a newer release.
    case release(ReleaseUpdate)

    var isRelease: Bool { if case .release = self { return true } else { return false } }
}

enum MusicCommand { case playPause, next, previous }

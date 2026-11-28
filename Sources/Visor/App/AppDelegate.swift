import AppKit
import Darwin
import VisorCore
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var lastUpdateClick: Date?
    let model = AppModel()
    lazy var notch = NotchController(model: model)
    lazy var usage = UsageService(model: model)
    private lazy var music = MusicService(model: model)
    lazy var plugins = PluginService(model: model)
    /// In-app updates from the appcast in Info.plist (SUFeedURL), signed with
    /// the EdDSA key in SUPublicEDKey: checked every 6 hours, downloaded and
    /// installed when Visor quits (unless turned off in the menu). Only an app
    /// bundle can update itself, so a bare debug binary doesn't start it.
    lazy var updater = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.bundleURL.pathExtension == "app", updaterDelegate: UpdateFeed.shared, userDriverDelegate: nil)
    private lazy var bar = BarService(model: model)
    private lazy var clipboard = ClipboardService(model: model)
    private let intro = IntroController()
    private lazy var status = StatusService(model: model)
    private let radar = RadarService()
    private let approvalLog = ApprovalLogger()
    private lazy var awake = AwakeService(model: model)
    /// Two sessions changing the same file within ten minutes.
    private var clashWatch = ClashWatch()
    private var clashExpiry: DispatchWorkItem?
    private var stuckWatch = StuckWatch()
    private var stuckExpiry: DispatchWorkItem?
    /// Later and peeked limit windows; the card itself is re-derived each time.
    private var handoffGate = HandoffGate()
    /// One wake-up at the shown handoff's reset, so it clears without waiting for a reading.
    private var handoffExpiry: DispatchWorkItem?
    private var handoffCopiedWork: DispatchWorkItem?
    /// The screen lock under way and the turns that finished during it; memory only.
    private var awayWatch = AwayWatch()
    #if DEBUG
    /// `_away` "backdate": how much later the next debug unlock counts, so a short test reads as a long absence.
    private var debugAwayShift: TimeInterval = 0
    /// `_handoff`: a fake Claude limit and pace, and fake other quotas, used in place of the real ones.
    private var debugHandoff: (plan: PlanUsage, runsOutAt: Date, others: [NotchQuota])?
    #endif
    private var clipboardHotKey: HotKey?
    private let hooks = HookServer()
    /// Codex CLI and OpenCode sessions, read from their own files (no hooks).
    private let fileAgents = FileAgentsService()
    /// MCP servers from the agents' configs and the MCP calls seen in hooks.
    private lazy var mcp = MCPService(model: model)
    var statusItem: NSStatusItem?
    weak var aboutPanel: NSWindow?
    private var pruneTimer: Timer?
    private var finishedWork: DispatchWorkItem?

    /// Every agent session, updated on each hook event. The notch gets a copy
    /// only when something it shows changes: most tool calls just move the
    /// last-event time, and redrawing for those would be wasted work.
    private var agents = AgentBoard()

    private var lastPublish = Date.distantPast
    private var publishPending = false

    /// At most a few redraws a second: many subagents calling tools at once
    /// would otherwise redraw the notch on every event.
    private func publishAgents() {
        guard agents.differsVisibly(from: model.board), !publishPending else { return }
        let wait = 0.25 - Date().timeIntervalSince(lastPublish)
        if wait > 0 {
            publishPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.publishPending = false
                self?.publishAgents()
            }
            return
        }
        lastPublish = Date()
        model.board = agents
        pruneAway()
        refreshHarness()
        mcp.sessionsChanged(agents.sessions)
        saveAgentsSoon()
        awake.update()
    }

    // MARK: Sessions across restarts

    nonisolated private static var sessionsURL: URL {
        #if DEBUG
        HookServer.directory.appendingPathComponent("sessions-debug.json")
        #else
        HookServer.directory.appendingPathComponent("sessions.json")
        #endif
    }
    private var saveAgentsWork: DispatchWorkItem?

    /// At most once a second, off the main thread.
    private func saveAgentsSoon() {
        guard saveAgentsWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveAgentsWork = nil
                guard let data = try? self.agents.saved() else { return }
                DispatchQueue.global(qos: .utility).async { try? data.write(to: Self.sessionsURL, options: .atomic) }
            }
        }
        saveAgentsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The agents that were running before Visor (re)started.
    private func restoreAgents() {
        guard let data = try? Data(contentsOf: Self.sessionsURL) else { return }
        agents = AgentBoard.restored(from: data) { kill($0, 0) == 0 || errno == EPERM }
        for session in agents.sessions {
            guard let host = session.host, model.hostIcons[host] == nil,
                  let app = ProcessTree.hostAppPath(of: session.pid) else { continue }
            model.hostIcons[host] = NSWorkspace.shared.icon(forFile: app)
        }
        publishAgents()
    }

    // MARK: Copilot approvals

    /// Copilot's "Always" choices, per project (Copilot's hooks can't save rules).
    private lazy var copilotRules: CopilotRules = {
        guard let data = try? Data(contentsOf: Self.copilotRulesURL),
              let rules = try? JSONDecoder().decode(CopilotRules.self, from: data) else { return CopilotRules() }
        return rules
    }()
    private static var copilotRulesURL: URL { HookServer.directory.appendingPathComponent("copilot-rules.json") }

    private func saveCopilotRules() {
        guard let data = try? JSONEncoder().encode(copilotRules) else { return }
        try? data.write(to: Self.copilotRulesURL, options: .atomic)
    }

    /// Menu bar switch for every agent's approvals; on by default.
    static var approvalsInNotch: Bool {
        get { UserDefaults.standard.object(forKey: "approvalsInNotch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "approvalsInNotch") }
    }

    /// How long the short hello stays before the notch closes by itself.
    private static let helloShown: TimeInterval = 3

    /// The intro on the screen with the notch, then the hello in the open notch:
    /// the full welcome, or (`brief`) a short hello that closes by itself.
    private func playIntro(brief: Bool = false) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        intro.play(on: screen) { [weak self] in
            guard let self else { return }
            self.model.welcomeSettled = false
            self.model.welcomeBrief = brief
            self.model.welcome = true
            self.model.pinned = true
            self.notch.expand()
            guard brief else { return }
            self.model.helloCount += 1
            let hello = self.model.helloCount
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.helloShown) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.welcomeBrief, self.model.helloCount == hello else { return }
                    self.model.endBriefHello()
                    // Stays open for an approval or the pointer, like the "limit is back" card.
                    self.notch.collapseIfAway()
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let folder = ProcessInfo.processInfo.environment["VISOR_EXPORT_CAST"] { FilmCast.export(to: folder); exit(0) }
        #endif
        _ = updater  // starts the daily update check
        model.pluginActions = plugins
        plugins.onPeek = { [weak self] id, news in
            guard let self, let info = self.model.plugins.first(where: { $0.id == id }) else { return }
            self.show(.plugin(icon: info.icon, news), for: 4)
        }
        plugins.start()
        HookServer.migrateFromNotchboard()
        model.hooksInstalled = HookInstaller.isInstalled
        model.antigravityHooksInstalled = HookInstaller.antigravityInstalled
        // Keep the script current with this version of the app.
        if model.hooksInstalled { try? HookInstaller.install() }
        if HookInstaller.copilotInstalled { try? HookInstaller.installCopilot() }
        if model.antigravityHooksInstalled { try? HookInstaller.installAntigravity() }
        model.installHooks = { [weak self] in self?.installHooks() }
        model.refreshPlan = { [weak self] in self?.usage.refreshIfStale() }
        model.connectionAction = { [weak self] provider, action in self?.usage.perform(action, for: provider) }
        model.musicCommand = { [weak self] in self?.music.perform($0) }
        model.enableExactControl = { [weak self] in self?.music.enableExactControl() }
        model.setVolume = { [weak self] in self?.music.setVolume($0) }
        model.refreshVolume = { [weak self] in self?.music.refreshVolume() }
        model.decide = { [weak self] request, decision in self?.decide(request, decision) }
        model.focusAgent = { [weak self] session in self?.focus(session) }
        model.viewDiff = { [weak self] turn in self?.openDiff(turn) }
        status.onNew = { [weak self] agent, incident in self?.show(.status(agent: agent, incident), for: 6) }
        status.start()
        radar.onOffers = { [weak self] offers in
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                if model.releaseOffers != offers { model.releaseOffers = offers }
                // "Updating…" lasts until its card confirms or goes.
                if let tool = model.updatingTool, !offers.contains(where: { $0.toolID == tool && !$0.updated }) { model.updatingTool = nil }
            }
        }
        radar.onNew = { [weak self] update in MainActor.assumeIsolated { self?.show(.release(update), for: 8) } }
        model.dismissRelease = { [weak self] update in self?.radar.dismiss(update.toolID) }
        model.updateRelease = { [weak self] update in self?.runUpdate(update) }
        radar.start()
        model.awakeChanged = { [weak self] in self?.awake.update() }
        awake.start()
        model.dismissClash = { [weak self] clash in
            self?.clashWatch.dismiss(clash)
            self?.refreshClashes()
        }
        model.ignoreStuck = { [weak self] stuck in
            self?.stuckWatch.ignore(stuck)
            self?.refreshStuck()
        }
        model.laterHandoff = { [weak self] handoff in
            self?.handoffGate.later(handoff)
            self?.refreshHandoff()
        }
        model.copyHandoff = { [weak self] handoff in self?.copyHandoff(handoff) }
        model.dismissAway = { [weak self] in self?.dismissAway() }
        model.openAway = { [weak self] in self?.openAway() }
        // Screen lock and unlock only (not sleep and wake): the recap is about being away from the desk.
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockedScreen() }
        }
        center.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlockedScreen() }
        }

        restoreAgents()
        // Every launch: the intro, then the full welcome the first time and a short hello after.
        let introKind = IntroGate.kind(seen: UserDefaults.standard.bool(forKey: "introShown"), environment: ProcessInfo.processInfo.environment)
        if introKind != .off {
            UserDefaults.standard.set(true, forKey: "introShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.playIntro(brief: introKind == .hello) }
        }
        hooks.onMessage = { [weak self] message, approval in self?.received(message, approval) }
        hooks.onApprovalGone = { [weak self] id, reason in self?.approvalGone(id, reason) }
        do { try hooks.start() } catch { NSLog("Visor: hook socket failed: \(error)") }

        usage.onLimitBack = { [weak self] in self?.showLimitBack($0) }
        notch.onExpand = { [weak self] tab in
            if tab == .usage { self?.usage.refreshIfStale() }
            if tab == .music { self?.music.refreshVolume() }
        }
        model.barActions = bar
        bar.start()
        model.clipboardActions = clipboard
        model.pasteClip = { [weak self] item, plain in
            guard let self else { return }
            self.clipboard.paste(item, plain: plain) { self.closeClipboard() }
        }
        model.focusClipSearch = { [weak self] in self?.notch.openWithKeyboard(.clipboard) }
        clipboard.start()
        clipboardHotKey = HotKey.clipboard { [weak self] in
            MainActor.assumeIsolated { self?.openClipboard() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let key = event
            let handled = MainActor.assumeIsolated { self?.welcomeKey(key) == true || self?.approvalKey(key) == true || self?.clipboardKey(key) == true }
            return handled ? nil : event
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.notch.clickedAt(NSEvent.mouseLocation) }
        }
        watchBarVisibility()
        watchHandoff()
        notch.start()
        usage.start()
        // VISOR_NO_MUSIC=1 keeps a test run from scripting your players (and asking for permission).
        if ProcessInfo.processInfo.environment["VISOR_NO_MUSIC"] == nil { music.start() }
        setUpStatusItem()

        model.mcpShown = { [weak self] in self?.mcp.listShown() }
        mcp.start()
        fileAgents.onScan = { [weak self] agent, sessions in self?.fileAgentsRead(agent, sessions) }
        fileAgents.scan()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fileAgents.scan()
                let alive = { (pid: Int32) in kill(pid, 0) == 0 || errno == EPERM }
                let gone = self.agents.sessions.filter { $0.pid > 0 && !alive($0.pid) }.map(\.id)
                self.agents.prune(isAlive: alive)
                self.publishAgents()
                self.forgetCostsOfEndedSessions()
                // An agent that exited is no longer stuck, and its counts go.
                let generation = self.stuckWatch.generation
                self.stuckWatch.forget(keeping: Set(self.agents.sessions.map(\.id)))
                if self.stuckWatch.generation != generation { self.refreshStuck() }
                for session in gone { self.hooks.releaseApprovals(session: session, event: "agent exited") }
            }
        }
        pruneTimer?.tolerance = 1
    }

    /// The bar's live widgets sample only while the Bar tab is on screen.
    private func watchBarVisibility() {
        withObservationTracking {
            bar.setVisible(model.expanded && model.tab == .bar && !model.showsCard)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchBarVisibility() } }
        }
    }

    // MARK: Clipboard

    private func openClipboard() {
        if model.expanded && model.tab == .clipboard && notch.keyboardOpen {
            closeClipboard()
            return
        }
        model.clipQuery = ""
        model.clipSelection = model.clips.items.first?.id
        notch.openWithKeyboard(.clipboard)
    }

    private func closeClipboard() {
        model.clipQuery = ""
        model.clipSelection = nil
        notch.close()
    }

    /// Return presses the hello's Get started, like Allow on an approval.
    private func welcomeKey(_ event: NSEvent) -> Bool {
        guard model.expanded, model.welcome, !model.welcomeBrief, model.approvals.isEmpty, [36, 76].contains(event.keyCode) else { return false }
        model.dismissWelcome()
        return true
    }

    /// Return, A or Esc answers the card shown while the pointer is over it
    /// (the panel has the keyboard only then). Returns true when handled.
    private func approvalKey(_ event: NSEvent) -> Bool {
        guard model.expanded, let request = model.approvals.first else { return false }
        let modified = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        guard let decision = ApprovalKeys.decision(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                                   modified: modified, canAlways: request.alwaysAllowLabel != nil) else { return false }
        decide(request, decision)
        return true
    }

    /// Keys while the clipboard tab has the keyboard. Returns true when handled.
    private func clipboardKey(_ event: NSEvent) -> Bool {
        guard model.expanded, model.tab == .clipboard, !model.showsCard else { return false }
        let shown = model.clips.search(model.clipQuery)
        let index = shown.firstIndex { $0.id == model.clipSelection }
        let selected = index.map { shown[$0] }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // Esc
            if model.clipQuery.isEmpty { closeClipboard() } else { model.clipQuery = ""; model.clipSelection = model.clips.items.first?.id }
        case 125: // ↓
            if !shown.isEmpty { model.clipSelection = shown[min((index ?? -1) + 1, shown.count - 1)].id }
        case 126: // ↑
            if !shown.isEmpty { model.clipSelection = shown[max((index ?? 1) - 1, 0)].id }
        case 36, 76: // Return: paste; ⌥Return: as plain text
            if let selected { model.pasteClip?(selected, flags.contains(.option)) }
        case 51, 117: // Delete: edit the search, or delete the selected item
            if !model.clipQuery.isEmpty {
                model.clipQuery.removeLast()
                model.clipSelection = model.clips.search(model.clipQuery).first?.id
            } else if let selected, let i = index {
                let next = shown.indices.contains(i + 1) ? shown[i + 1].id : (i > 0 ? shown[i - 1].id : nil)
                clipboard.delete(selected.id)
                model.clipSelection = next
            }
        default:
            if flags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "p": if let selected { clipboard.togglePin(selected.id) }
                case "c": if let selected { clipboard.copy(selected) }
                case "z": clipboard.undo()
                default: return false
                }
            } else if let text = event.characters, !text.isEmpty, !flags.contains(.control),
                      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                model.clipQuery += text
                model.clipSelection = model.clips.search(model.clipQuery).first?.id
            } else {
                return false
            }
        }
        return true
    }

    // MARK: Limit is back

    /// Opens the notch on the refilled meter for a few seconds. Not over an
    /// approval, and not while you're already using the open notch.
    private func showLimitBack(_ back: LimitReturn) {
        guard !model.expanded, !model.showsCard else { return }
        model.limitBack = back
        notch.expand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.limitBack == back else { return }
                self.model.limitBack = nil
                self.notch.collapseIfAway()
            }
        }
    }

    // MARK: Limit handoff

    /// Re-derives the handoff whenever a limit reading or the sessions change.
    /// Only the inputs are tracked, so the card and peek it writes don't call it again.
    private func watchHandoff() {
        withObservationTracking {
            _ = (model.plan, model.quotas, model.antigravityUpdated, model.unmeteredAgents, model.board)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchHandoff() } }
        }
        refreshHandoff()
    }

    /// Shows exactly what `HandoffPlanner.decide` returns from the current
    /// readings and the live sessions (`agents`, which also has the files,
    /// tests and last-event times the notch's copy skips), minus a window put
    /// off with Later: no stored
    /// "shown" state, so it clears once the limit resets, the pace recovers,
    /// another agent takes over or the session ends.
    private func refreshHandoff() {
        let now = Date()
        var plan = model.plan
        var quotas = model.quotas
        var forecast: (String, Double, Date?, TimeInterval?) -> BurnForecast? = model.forecast
        #if DEBUG
        if let fake = debugHandoff {
            plan = fake.plan
            quotas = fake.others
            forecast = { _, _, _, _ in .runsOut(at: fake.runsOutAt) }
        }
        #endif
        let inputs = HandoffInputs.make(quotas: quotas, antigravityUpdated: model.antigravityUpdated,
                                        installed: model.unmeteredAgents, now: now)
        let decided = HandoffPlanner.decide(plan: plan, forecast: forecast, others: inputs.others,
                                            unmetered: inputs.unmetered, sessions: agents.sessions, now: now)
        let (shown, peek) = handoffGate.update(decided, now: now)
        if shown != model.handoff { model.handoff = shown }
        if case .handoff(let peeked)? = model.peek, !HandoffGate.keepsPeek(peekID: peeked.id, shown: shown) { model.peek = nil }
        if let shown, peek { show(.handoff(shown), for: 6) }
        handoffExpiry?.cancel()
        handoffExpiry = nil
        // One wake-up: the limit resets, or an Antigravity reading offered as room turns stale.
        guard let shown else { return }
        let stale = HandoffInputs.staleAt(antigravityUpdated: model.antigravityUpdated, others: inputs.others)
        let next = min(shown.resetsAt, stale ?? .distantFuture)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshHandoff() } }
        handoffExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSince(now) + 1), execute: work)
    }

    /// Only copies: Visor never types into a terminal. Marked concealed and
    /// transient so clipboard managers, Visor's own history included, skip it.
    private func copyHandoff(_ handoff: Handoff) {
        let pasteboard = NSPasteboard.general
        let marks = HandoffPlanner.pasteboardTypes.map { NSPasteboard.PasteboardType($0) }
        pasteboard.clearContents()
        pasteboard.declareTypes([.string] + marks, owner: nil)
        pasteboard.setString(HandoffPlanner.note(for: handoff, sessions: agents.sessions), forType: .string)
        for mark in marks { pasteboard.setData(Data(), forType: mark) }
        model.handoffCopied = handoff.id
        handoffCopiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.model.handoffCopied = nil } }
        handoffCopiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Context window

    private let contextQueue = DispatchQueue(label: "visor.context", qos: .utility)
    private var contextPending: Set<String> = []
    /// Sessions that had an event while their read ran: read again once it's done.
    private var contextDirty: [String: String] = [:]
    /// Running cost per session; used on `contextQueue` only.
    private let costReader = SessionCostReader()
    /// Sessions the cost reader holds a tally for, as far as the main thread knows.
    private var costSessions: Set<String> = []

    /// After a Claude Code reply, reads how full the session's context is from
    /// the end of its transcript, and the cost of what was appended, off the
    /// main thread, once per burst of events.
    private func readContextSoon(_ message: HookMessage) {
        guard message.provider == "claude", ["PostToolUse", "Stop", "SessionStart", "UserPromptSubmit"].contains(message.event),
              let session = message.sessionID, let path = message.payload["transcript_path"] as? String else { return }
        // Only Claude Code's own project folders: the path comes from a hook payload.
        guard ProjectHistory.isProjectFolder((path as NSString).deletingLastPathComponent, roots: Self.claudeProjectRoots) else { return }
        readContext(session: session, path: path)
    }

    private func readContext(session: String, path: String) {
        transcripts[session] = path
        guard contextPending.insert(session).inserted else {
            // The read may already be past this event's write; read again after it.
            contextDirty[session] = path
            return
        }
        // Claude Code may still be writing the reply when the hook runs.
        let costReader = costReader
        contextQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let (reading, model, cost, xray, helperStats, lastReply) = autoreleasepool {
                let cost = costReader.read(transcript: path, session: session)
                return (Self.contextReading(at: path), Self.claudeModelSetting(), cost, costReader.xray(session: session),
                        costReader.helperStats(session: session), costReader.lastReply(session: session))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.contextPending.remove(session)
                    self.costSessions.insert(session)
                    self.agents.setContext(tokens: reading.tokens, model: model, provenWindow: reading.provenWindow, session: session)
                    // A transcript missing for a moment keeps the last cost.
                    // The last reply rides along for the cache clock; the board republishes when it changes.
                    if let cost { self.agents.setCost(cost, lastReply: lastReply, session: session) }
                    if let xray { self.gotXRay(xray, session: session, path: path) }
                    self.agents.setHelperStats(helperStats, session: session)
                    self.publishAgents()
                    if let again = self.contextDirty.removeValue(forKey: session) { self.readContext(session: session, path: again) }
                }
            }
        }
    }

    // MARK: Harness X-ray

    /// Earlier sessions of each project, read once per file; used on `adviceQueue` only,
    /// so a long scan never holds up the context and cost reads.
    private let projectHistory = ProjectHistory()
    private let adviceQueue = DispatchQueue(label: "visor.xray-advice", qos: .utility)
    /// Each Claude Code session's transcript, as its hooks name it.
    private var transcripts: [String: String] = [:]
    /// What the Harness line was last built from, so unrelated publishes skip it.
    private var harnessInputs: [String] = []
    /// Sessions whose earlier sessions were scanned for the MCP advice.
    private var adviceScanned: Set<String> = []
    /// The MCP advice per session id.
    private var harnessAdvice: [String: MCPAdvice] = [:]

    /// A session's first reply was read: keep its X-ray, then, once, look at the
    /// project's earlier sessions for an MCP server it carries but never calls.
    private func gotXRay(_ xray: HarnessXRay, session: String, path: String) {
        agents.setXRay(xray, session: session)
        guard let project = agents.sessions.first(where: { $0.id == session })?.project,
              adviceScanned.insert(session).inserted else { return }
        let history = projectHistory
        let folder = (path as NSString).deletingLastPathComponent
        // Only Claude Code's own project folders: the path comes from a hook payload.
        guard ProjectHistory.isProjectFolder(folder, roots: Self.claudeProjectRoots) else { return }
        let live = Set(agents.sessions.compactMap { transcripts[$0.id] })
        adviceQueue.async { [weak self] in
            let advice = MCPAdvice.make(current: xray, project: project,
                                        past: history.earlier(in: folder, excluding: path, live: live))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let advice else { return }
                    self.harnessAdvice[session] = advice
                    self.refreshHarness()
                }
            }
        }
    }

    /// The Harness line from the shown sessions; built only when a session with an X-ray,
    /// its folder or the advice changed, and written only when it differs.
    private func refreshHarness() {
        // Pruned by the live sessions, which may be newer than the shown ones.
        let ids = Set(agents.sessions.map(\.id))
        harnessAdvice = harnessAdvice.filter { ids.contains($0.key) }
        adviceScanned.formIntersection(ids)
        transcripts = transcripts.filter { ids.contains($0.key) }
        let inputs = model.board.sessions.filter { $0.xray != nil }.map { "\($0.id) \($0.agent) \($0.cwd)" }
            + harnessAdvice.keys.sorted()
        guard inputs != harnessInputs else { return }
        harnessInputs = inputs
        let summary = HarnessSummary.make(sessions: model.board.sessions, advice: harnessAdvice)
        if model.harness != summary { model.harness = summary }
        if summary == nil && model.harnessOpen { model.harnessOpen = false }
    }

    /// The session called the server its advice named: the advice no longer holds.
    private func dropAnsweredAdvice(_ message: HookMessage) {
        guard message.provider == "claude", message.event == "PreToolUse", let session = message.sessionID,
              let tool = message.toolName, let advice = harnessAdvice[session], advice.isAnswered(byTool: tool) else { return }
        harnessAdvice[session] = nil
        refreshHarness()
    }

    /// Claude Code's transcript folders' parent: `~/.claude/projects`, or under
    /// `CLAUDE_CONFIG_DIR`. Debug builds also take `VISOR_CLAUDE_PROJECTS` (a fixture folder).
    private static var claudeProjectRoots: [String] {
        let env = ProcessInfo.processInfo.environment
        var roots = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path]
        if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            roots.append(((dir as NSString).expandingTildeInPath as NSString).appendingPathComponent("projects"))
        }
        #if DEBUG
        if let dir = env["VISOR_CLAUDE_PROJECTS"], !dir.isEmpty { roots.append(dir) }
        #endif
        return roots
    }

    /// Drops the running cost of sessions that left the board (exited, ended, /clear).
    /// `costSessions` is filled when a read finishes, so a read queued before the
    /// session ended is still forgotten on a later tick.
    private func forgetCostsOfEndedSessions() {
        let ids = Set(agents.sessions.map(\.id))
        guard !costSessions.isSubset(of: ids) else { return }
        costSessions.formIntersection(ids)
        contextDirty = contextDirty.filter { ids.contains($0.key) }
        let costReader = costReader
        contextQueue.async { costReader.forget(keeping: ids) }
    }

    private nonisolated static func contextReading(at path: String) -> (tokens: Int?, provenWindow: Int?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail = UInt64(ContextUsage.tailBytes)
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        return (try? handle.readToEnd()).map(ContextUsage.reading(inTail:)) ?? (nil, nil)
    }

    /// The model Claude Code is set to ("opus[1m]" asks for the 1M window).
    private nonisolated static func claudeModelSetting() -> String? {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["model"] as? String
    }

    // MARK: Agents

    private func received(_ message: HookMessage, _ approval: ApprovalRequest?) {
        #if DEBUG
        // Debug builds: {"event":"_decide","raw":{"decision":"allow|always|deny"}} answers the first approval.
        if message.event == "_decide", let first = model.approvals.first {
            let answer = message.payload["decision"] as? String
            decide(first, answer == "deny" ? .deny : answer == "always" ? .allowAlways : .allow)
            return
        }
        // {"event":"_musicCommand","raw":{"command":"playPause|next|previous"}} presses a music button.
        if message.event == "_musicCommand" {
            let command: MusicCommand = switch message.payload["command"] as? String {
            case "next": .next
            case "previous": .previous
            default: .playPause
            }
            model.musicCommand?(command)
            return
        }
        // {"event":"_music","raw":{"title":..,"artist":..,"art":"/path.png","playing":true,"known":false,"tab":"<Dia tab id>"}} fakes a song.
        if message.event == "_music" {
            let p = message.payload
            let image = (p["art"] as? String).flatMap { NSImage(contentsOfFile: $0) }
            // "tab": a real Dia tab id, so the buttons script that tab.
            let tab = p["tab"] as? String ?? ""
            model.nowPlaying = NowPlaying(source: .browser(bundleID: "company.thebrowser.dia", tab: tab, scriptable: !tab.isEmpty),
                                          sourceName: p["source"] as? String ?? "Dia · YouTube",
                                          title: p["title"] as? String ?? "", artist: p["artist"] as? String ?? "",
                                          album: "", duration: (p["duration"] as? NSNumber)?.doubleValue ?? 0,
                                          position: (p["position"] as? NSNumber)?.doubleValue ?? 0, positionAt: Date(),
                                          isPlaying: p["playing"] as? Bool ?? true)
            model.nowPlaying?.stateKnown = p["known"] as? Bool ?? true
            model.artwork = image
            model.artworkTint = image.flatMap(MusicService.tint(of:))
            model.artworkBackdrop = image.flatMap(MusicService.backdrop(of:))
            if let allowed = p["mediaKeysAllowed"] as? Bool { model.mediaKeysAllowed = allowed }
            return
        }
        // {"event":"_limitback","raw":{}} shows the "limit is back" card with a sample Claude limit.
        if message.event == "_limitback" {
            showLimitBack(LimitReturn(agent: "Claude Code", title: "Session (5h)", percentLeft: 100,
                                      ranOutAt: Date().addingTimeInterval(-3 * 3600), nextReset: Date().addingTimeInterval(5 * 3600)))
            return
        }
        // {"event":"_stuck","raw":{"press":"ignore|open"}} presses a button on the first Stuck? card.
        if message.event == "_stuck", let first = model.stuck.first {
            if message.payload["press"] as? String == "open" {
                if let session = model.board.sessions.first(where: { $0.id == first.session }) { model.focusAgent?(session) }
            } else {
                model.ignoreStuck?(first)
            }
            return
        }
        // {"event":"_away","raw":{"do":"lock|unlock"}} calls the same lockedScreen()/unlockedScreen() as the real
        // lock notifications (never post those); "backdate":42 makes the next unlock count 42 min later;
        // "press":"gotit|open" presses the away card's buttons.
        if message.event == "_away" {
            let p = message.payload
            if let minutes = (p["backdate"] as? NSNumber)?.doubleValue { debugAwayShift = minutes * 60 }
            switch p["do"] as? String {
            case "lock": lockedScreen()
            case "unlock":
                unlockedScreen(at: Date().addingTimeInterval(debugAwayShift))
                debugAwayShift = 0
            default: break
            }
            switch p["press"] as? String {
            case "gotit": model.dismissAway?()
            case "open": model.openAway?()
            default: break
            }
            return
        }
        // {"event":"_handoff","raw":{"used":85,"runsOutIn":1200,"resetsIn":2400,"others":[{"agent":"Copilot CLI","left":45}]}}
        // fakes a Claude session limit running out (resetsIn below 0: it has reset); "clear":true drops the
        // fake, "press":"later|copy" presses the handoff card's buttons.
        if message.event == "_handoff" {
            let p = message.payload
            if let press = p["press"] as? String {
                guard let shown = model.handoff else { return }
                if press == "later" { model.laterHandoff?(shown) } else { model.copyHandoff?(shown) }
                return
            } else if p["clear"] as? Bool == true {
                debugHandoff = nil
            } else {
                let now = Date()
                let number = { (key: String, fallback: Double) in (p[key] as? NSNumber)?.doubleValue ?? fallback }
                let others = (p["others"] as? [[String: Any]] ?? []).compactMap { entry -> NotchQuota? in
                    guard let agent = entry["agent"] as? String else { return nil }
                    return NotchQuota(agent: agent, percentLeft: (entry["left"] as? NSNumber)?.doubleValue ?? 50, label: "")
                }
                let plan = PlanUsage(limits: [PlanLimit(kind: "session", percentUsed: number("used", 85),
                                                        resetsAt: now + number("resetsIn", 2400))])
                debugHandoff = (plan, now + number("runsOutIn", 1200), others)
            }
            refreshHandoff()
            return
        }
        // {"event":"_clipdelete","raw":{}} deletes the newest clipboard item.
        if message.event == "_clipdelete", let first = model.clips.items.first {
            clipboard.delete(first.id)
            return
        }
        // {"event":"_incident","raw":{"agent":"Claude Code","title":"…","major":true}} fakes a status-page incident; no title clears it.
        if message.event == "_incident", let agent = message.payload["agent"] as? String {
            if let title = message.payload["title"] as? String {
                let incident = ProviderIncident(id: UUID().uuidString, title: title,
                                                severity: message.payload["major"] as? Bool == true ? .major : .minor,
                                                since: Date(), link: "https://status.claude.com")
                model.incidents[agent] = incident
                show(.status(agent: agent, incident), for: 6)
            } else {
                model.incidents[agent] = nil
            }
            return
        }
        // {"event":"_radar","raw":{"tool":"claude","installed":"2.1.311","latest":"2.1.312","notes":"- A\n- B"}} fakes a release offer;
        // "clear":true resets the radar, "dismiss":"<tool>" presses a card's x, "update":"<tool>" presses its Update, "expand":true opens the notch like a click,
        // "probeRedirect":true GETs a GitHub URL that redirects to another host (logged as refused), "check":true checks now.
        if message.event == "_radar" {
            let p = message.payload
            if p["clear"] as? Bool == true { radar.debugClear() }
            if let tool = p["tool"] as? String, let installed = p["installed"] as? String, let latest = p["latest"] as? String {
                radar.debugFake(toolID: tool, installed: installed, latest: latest, notes: p["notes"] as? String)
            }
            if let tool = p["dismiss"] as? String { radar.dismiss(tool) }
            if let tool = p["update"] as? String, let offer = model.releaseOffers.first(where: { $0.toolID == tool }) {
                // "fakeCommand" (debug only) swaps in a harmless command to see the Terminal path run; never a real installer.
                if let fake = p["fakeCommand"] as? String { launchInTerminal(update: offer, toolName: offer.name, command: fake, binary: "sh") }
                else { model.updateRelease?(offer) }
            }
            if p["expand"] as? Bool == true { notch.expandFromPointer() }
            if p["probeRedirect"] as? Bool == true { radar.debugProbeRedirect() }
            if p["check"] as? Bool == true { radar.debugCheckNow() }
            return
        }
        // {"event":"_intro","raw":{"kind":"hello"}} plays the short hello; without it, the full welcome.
        if message.event == "_intro" {
            playIntro(brief: message.payload["kind"] as? String == "hello")
            return
        }
        // {"event":"_show","raw":{"tab":"usage"}} opens a tab; tab "none" collapses; "keyboard":true focuses the clipboard search; "accounts":true shows Connected accounts; "helpers":"<session id>" opens that session's subagents ("helperRow":"<helper id>" selects a row and logs its card's line count to helpers-debug.log); "office":true/false switches the Agents tab ("world":"galaxy" picks its world); "tokens":true/false the Usage tab ("page":"models" picks its view); "clipHover":n hovers a clipboard row; "mcp":true/false opens or closes the MCP server list; "xray":true/false the Harness list.
        if message.event == "_show" {
            let tab = message.payload["tab"] as? String
            model.pinned = tab != nil && tab != "none"
            if let tab = tab.flatMap(Tab.init(rawValue:)) { model.tab = tab; notch.expand() } else { model.expanded = false }
            if message.payload["keyboard"] as? Bool == true { model.focusClipSearch?() }
            model.showAccounts = message.payload["accounts"] as? Bool == true
            if let helpers = message.payload["helpers"] as? String { model.helpersOpen = helpers.isEmpty ? nil : helpers }
            if let row = message.payload["helperRow"] as? String, let session = model.board.sessions.first(where: { $0.id == model.helpersOpen }) {
                model.helperSelected = row.isEmpty ? nil : row
                model.helperSelectedTurn = session.turnStart
                let lines = HelpersList.detail(for: session, model: model)?.lines.count ?? 0
                let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Visor/helpers-debug.log")
                try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("\(Date().timeIntervalSince1970) helperRow \(row) lines \(lines)\n".utf8).write(to: log)
            }
            if let office = message.payload["office"] as? Bool { model.agentsOffice = office }
            if let world = message.payload["world"] as? String { model.officeWorld = OfficeWorld(saved: world) }
            if let picker = message.payload["worldPicker"] as? Bool { model.officePicker = picker }
            if let tokens = message.payload["tokens"] as? Bool { model.usageTokens = tokens }
            if let open = message.payload["mcp"] as? Bool { model.mcpOpen = open && model.mcp != nil }
            if let open = message.payload["xray"] as? Bool { model.harnessOpen = open && model.harness != nil }
            if let page = (message.payload["page"] as? String).flatMap(TokensPage.init(rawValue:)) { model.tokensPage = page }
            // "clipHover": n hovers the clipboard's nth row (0-based).
            if let row = (message.payload["clipHover"] as? NSNumber)?.intValue, model.clips.items.indices.contains(row) {
                model.clipHover = model.clips.items[row].id
            }
            return
        }
        #endif
        var message = message
        message.pid = ProcessTree.agentAncestor(of: message.pid)
        // Only a PostToolUseFailure can fail a helper: compare the board then (copy on write).
        let before = HelperFailure.mayFail(message) ? agents : nil
        agents.apply(message)
        mcp.record(message)
        noteEdit(message)
        dropAnsweredAdvice(message)
        noteStuck(message)
        // After noteStuck: a helper failing is the more specific news for the same event.
        if let before { noteHelperFailure(before) }
        readContextSoon(message)
        if let session = message.sessionID, agents.sessions.first(where: { $0.id == session })?.host == nil {
            if let app = ProcessTree.hostAppPath(of: message.pid) {
                let host = ProcessTree.appName(at: app)
                if model.hostIcons[host] == nil { model.hostIcons[host] = NSWorkspace.shared.icon(forFile: app) }
                agents.setHost(host, session: session)
            }
        }
        // The session moved on (answered in the terminal, interrupted, new prompt): its approvals are moot.
        hooks.releaseApprovals(after: message)
        noteAnsweredQuestion(message)
        if let approval {
            let route = ApprovalRoute.of(approval, inNotch: Self.approvalsInNotch, rules: copilotRules)
            approvalLog.write(approval, route == .notch ? "card" : route == .allow ? "allowed by Always rule" : "asked in terminal")
            switch route {
            case .terminal:
                // A question, or approvals are off: the terminal's own prompt answers it.
                hooks.reply(approval, nil)
            case .allow:
                // Allowed before with "Always": answer at once, no card.
                hooks.reply(approval, .allow)
                agents.resolveApproval(session: approval.sessionID)
            case .notch:
                model.approvals.append(approval)
                notch.expand()
            }
        }
        publishAgents()
        if let done = agents.finished(message) {
            awayWatch.noteFinished(done, at: Date())
            // Its summary waits behind the peek, unless the notch is already open for something else.
            if !model.expanded && !done.stats.isEmpty { model.summary = done }
            show(.done(done), for: 5)
        }
    }

    /// Sessions read from an agent's files: onto the board, with the host app
    /// of its process when one runs there, and the "Finished" peek for turns that ended.
    private func fileAgentsRead(_ agent: String, _ sessions: [ScannedSession]) {
        let finished = agents.sync(agent: agent, scanned: sessions)
        for session in agents.sessions where session.agent == agent && session.pid > 0 && session.host == nil {
            guard let app = ProcessTree.hostAppPath(of: session.pid) else { continue }
            let host = ProcessTree.appName(at: app)
            if model.hostIcons[host] == nil { model.hostIcons[host] = NSWorkspace.shared.icon(forFile: app) }
            agents.setHost(host, session: session.id)
        }
        publishAgents()
        for done in finished { awayWatch.noteFinished(done, at: Date()) }
        if let done = finished.last { show(.done(done), for: 5) }
    }

    /// A question answered in the terminal shows "Answered" in the closed notch.
    private func noteAnsweredQuestion(_ message: HookMessage) {
        guard message.toolName == AgentQuestion.tool,
              message.event == "PostToolUse" || message.event == "PostToolUseFailure",
              let session = message.sessionID,
              let agent = agents.sessions.first(where: { $0.id == session })?.agent else { return }
        show(.answered(agent: agent), for: 2.5)
    }

    /// An edit to a file another session changed in the last ten minutes: peek
    /// once, and mark both sessions until it goes quiet.
    private func noteEdit(_ message: HookMessage) {
        guard let path = TurnStats.editedPath(message), let id = message.sessionID else { return }
        let agent = agents.sessions.first { $0.id == id }?.agent ?? AgentBoard.agentName(message.provider)
        if let clash = clashWatch.record(session: id, agent: agent, path: path, at: Date()) { show(.clash(clash), for: 6) }
        refreshClashes()
    }

    /// The clashes still going, and one wake-up when the next goes quiet (no polling).
    private func refreshClashes() {
        let now = Date()
        let active = clashWatch.active(at: now)
        if active != model.clashes { model.clashes = active }
        clashExpiry?.cancel()
        guard let next = clashWatch.nextChange(after: now) else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshClashes() } }
        clashExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSince(now) + 0.5), execute: work)
    }

    /// A hook agent failing or repeating the same call: peek once, and keep the
    /// card while the events say it's still going round.
    private func noteStuck(_ message: HookMessage) {
        guard let id = message.sessionID else { return }
        let agent = agents.sessions.first { $0.id == id }?.agent ?? AgentBoard.agentName(message.provider)
        let generation = stuckWatch.generation
        let peek = stuckWatch.record(message, agent: agent, at: Date())
        // Most events change no warning: nothing to republish or re-arm.
        if stuckWatch.generation != generation { refreshStuck() }
        if let peek { show(.stuck(peek), for: 6) }
    }

    /// The warnings still standing, the peek withdrawn once its warning has
    /// cleared, and one wake-up for the fallback timeout (no polling).
    private func refreshStuck() {
        let now = Date()
        let active = stuckWatch.active(at: now)
        if active != model.stuck { model.stuck = active }
        pruneAway()
        if case .stuck(let shown)? = model.peek, !active.contains(where: { $0.id == shown.id }) { model.peek = nil }
        stuckExpiry?.cancel()
        stuckExpiry = nil
        guard let next = stuckWatch.nextChange(after: now) else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshStuck() } }
        stuckExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSince(now) + 0.5), execute: work)
    }

    // MARK: While you were away

    /// The screen locked: start noting what finishes.
    private func lockedScreen() {
        awayWatch.lock(at: Date())
    }

    /// The screen unlocked: after 10+ minutes with something changed, the card
    /// on top of the Agents tab and a 6 s peek. A closed notch switches to the
    /// Agents tab so opening it shows the card; it never opens by itself.
    private func unlockedScreen(at now: Date = Date()) {
        let stuck = stuckWatch.active(at: Date())
        guard var digest = awayWatch.unlock(at: now, board: agents, stuck: stuck) else { return }
        // A card still up from an earlier lock keeps what is still unhandled.
        if let earlier = model.away?.pruned(board: agents, stuck: stuck) { digest = digest.adding(earlier) }
        model.away = digest
        // The rows' "ago" reads the list's clock, which only ticks while the list shows.
        model.agentsNow = Date()
        // Closed, or open only for an approval card that arrived while locked: the
        // Agents tab is what shows next. The notch never opens for this.
        if !model.expanded || model.showsCard { model.tab = .agents }
        // A turn summary from while locked belonged to its "done" peek, which this
        // one replaces: opening during the peek shows the recap, not that summary.
        if !model.expanded { model.summary = nil }
        show(.away(digest), for: 6)
    }

    /// Drops the items that have been handled, from the card and the peek's
    /// count, without restarting the peek's timer. Runs only after a change was
    /// published (board or Stuck), and does nothing without a recap.
    private func pruneAway() {
        guard let away = model.away else { return }
        let next = away.pruned(board: agents, stuck: model.stuck)
        if next != away { model.away = next }
        if case .away(let shown)? = model.peek, shown != next { model.peek = next.map(Peek.away) }
    }

    /// Got it: the card and its peek go.
    private func dismissAway() {
        model.away = nil
        if case .away? = model.peek { model.peek = nil }
    }

    /// The card's primary button: the top item's app comes forward and the item goes.
    private func openAway() {
        guard let away = model.away, let top = away.top else { return }
        if let session = agents.sessions.first(where: { $0.id == top.session }) { focus(session) }
        model.away = away.removing(id: top.id)
        if case .away? = model.peek { model.peek = model.away.map(Peek.away) }
    }

    /// A helper failed: peek for 6 s. More failing in the same session while it
    /// shows add up ("3 helpers failed") instead of peeking again.
    private func noteHelperFailure(_ before: AgentBoard) {
        guard let failure = HelperFailure.new(before: before, after: agents) else { return }
        // More from the same session while it shows: update the text, keep the
        // timer, so a flood of failures can't hold the peek open.
        if case .helperFailed(let current)? = model.peek, current.session == failure.session {
            model.peek = .helperFailed(HelperFailure.merge(shown: current, new: failure))
            return
        }
        show(.helperFailed(failure), for: 6)
    }

    /// The changes a turn made, as a diff in the default text editor.
    private func openDiff(_ turn: FinishedTurn) {
        let files = turn.stats.files, cwd = turn.cwd
        DispatchQueue.global(qos: .userInitiated).async {
            /// Runs git in the project; its output, and whether it exited cleanly.
            func git(_ arguments: [String]) -> (Data, Bool) {
                let output = Shell.run("/usr/bin/git", ["-C", cwd] + arguments)
                return (output?.data ?? Data(), output?.ok ?? false)
            }
            // Tracked files as usual; files git doesn't know yet as new files, without touching the repo.
            var data = git(["diff", "--"] + files).0
            for file in files where !git(["ls-files", "--error-unmatch", "--", file]).1 {
                data.append(git(["diff", "--no-index", "--", "/dev/null", file]).0)
            }
            guard !data.isEmpty else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("visor-\(turn.project).diff")
            guard (try? data.write(to: url)) != nil else { return }
            Shell.launch("/usr/bin/open", ["-t", url.path])
        }
    }

    /// Brings the app an agent runs in to the front, where its prompt is.
    private func focus(_ session: AgentSession) {
        guard let id = ProcessTree.hostBundleID(of: session.pid) else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
    }

    private func show(_ peek: Peek, for seconds: TimeInterval) {
        model.peek = peek
        finishedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.model.peek = nil
                // Not opened in time: the summary goes with the peek.
                if self?.model.expanded == false { self?.model.summary = nil }
            }
        }
        finishedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func decide(_ request: ApprovalRequest, _ decision: ApprovalRequest.Decision?) {
        if decision == .allowAlways && request.provider == "copilot" {
            copilotRules.add(for: request)
            saveCopilotRules()
        }
        let outcome: String
        switch decision {
        case .allow?: outcome = "allowed in notch"
        case .allowAlways?: outcome = "always allowed in notch"
        case .deny?: outcome = "denied in notch"
        case nil: outcome = "handed to terminal"
        }
        hooks.reply(request, decision) { [approvalLog] in approvalLog.write(request, outcome) }
        model.approvals.removeAll { $0.id == request.id }
        if decision != nil { agents.resolveApproval(session: request.sessionID) }
        publishAgents()
        notch.collapseIfAway()
    }

    /// The hook gave up (timed out, or Claude Code was interrupted).
    private func approvalGone(_ id: UUID, _ reason: HookServer.LetGo) {
        if let approval = model.approvals.first(where: { $0.id == id }) {
            switch reason {
            case .allowedInTerminal:
                agents.answeredInTerminal(session: approval.sessionID, allowed: true)
                approvalLog.write(approval, "allowed in terminal")
            case .endedInTerminal:
                agents.answeredInTerminal(session: approval.sessionID, allowed: false)
                approvalLog.write(approval, "ended in terminal")
            case .timedOut:
                approvalLog.write(approval, "let go: timed out")
            case .movedOn(let event):
                approvalLog.write(approval, "let go: \(event)")
            }
            publishAgents()
        }
        model.approvals.removeAll { $0.id == id }
        notch.collapseIfAway()
    }

    private func installHooks() {
        do {
            try HookInstaller.install()
            try? HookInstaller.installCopilot()
            try? HookInstaller.installAntigravity()
            model.hooksInstalled = true
            model.antigravityHooksInstalled = HookInstaller.antigravityInstalled
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't connect Claude Code"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

extension AppDelegate {
    private static let terminalQueue = DispatchQueue(label: "visor.radar.terminal", qos: .userInitiated)

    /// Update on a release card: Terminal runs the catalog command in a new window,
    /// from a private script. Re-derived from the catalog here, so nothing from a
    /// feed or file reaches a shell.
    @MainActor func runUpdate(_ update: ReleaseUpdate) {
        guard let method = update.method,
              let tool = ReleaseTool.all.first(where: { $0.id == update.toolID }),
              let command = tool.updateCommand(method) else { return }
        launchInTerminal(update: update, toolName: tool.name, command: command, binary: tool.binary)
    }

    /// The system Terminal by its fixed path, so a lookalike app with its bundle id can't take over.
    nonisolated private static func terminalURL() -> URL? {
        let fixed = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: fixed.path) { return fixed }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
    }

    /// `command` is always catalog text; the debug `_radar` fake passes a harmless one.
    @MainActor func launchInTerminal(update: ReleaseUpdate, toolName: String, command: String, binary: String) {
        // Fast repeat clicks would open several windows.
        let now = Date()
        if let last = lastUpdateClick, now.timeIntervalSince(last) < 2 { return }
        lastUpdateClick = now
        Self.terminalQueue.async { [weak self] in
            let dir = Shell.which(binary).map { ($0 as NSString).deletingLastPathComponent }
            guard let text = TerminalCommand.script(toolName: toolName, command: command, binaryDir: dir),
                  let url = try? TerminalCommand.write(text),
                  let terminal = Self.terminalURL() else { return }
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.model.updatingTool = update.toolID
                    // Until the card confirms the new version; this only stops it sticking if the binary never changes.
                    DispatchQueue.main.asyncAfter(deadline: .now() + RadarState.updatingFallback) { [weak self] in
                        MainActor.assumeIsolated { if self?.model.updatingTool == update.toolID { self?.model.updatingTool = nil } }
                    }
                }
            }
        }
    }
}

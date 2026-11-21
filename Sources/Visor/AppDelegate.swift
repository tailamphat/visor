import AppKit
import Darwin
import VisorCore
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private lazy var notch = NotchController(model: model)
    private lazy var usage = UsageService(model: model)
    private lazy var music = MusicService(model: model)
    private lazy var plugins = PluginService(model: model)
    /// In-app updates from the appcast in Info.plist (SUFeedURL), signed with
    /// the EdDSA key in SUPublicEDKey: checked every 6 hours, downloaded and
    /// installed when Visor quits (unless turned off in the menu). Only an app
    /// bundle can update itself, so a bare debug binary doesn't start it.
    private lazy var updater = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.bundleURL.pathExtension == "app", updaterDelegate: UpdateFeed.shared, userDriverDelegate: nil)
    private lazy var bar = BarService(model: model)
    private lazy var clipboard = ClipboardService(model: model)
    private let intro = IntroController()
    private lazy var status = StatusService(model: model)
    private lazy var awake = AwakeService(model: model)
    /// Two sessions changing the same file within ten minutes.
    private var clashWatch = ClashWatch()
    private var clashExpiry: DispatchWorkItem?
    private var clipboardHotKey: HotKey?
    private let hooks = HookServer()
    private var statusItem: NSStatusItem?
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
        saveAgentsSoon()
        awake.update()
    }

    // MARK: Sessions across restarts

    private static var sessionsURL: URL {
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

    /// The intro on the screen with the notch, then the hello in the open notch.
    private func playIntro() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        intro.play(on: screen) { [weak self] in
            guard let self else { return }
            self.model.welcomeSettled = false
            self.model.welcome = true
            self.model.pinned = true
            self.notch.expand()
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
        model.awakeChanged = { [weak self] in self?.awake.update() }
        awake.start()
        model.dismissClash = { [weak self] clash in
            self?.clashWatch.dismiss(clash)
            self?.refreshClashes()
        }

        restoreAgents()
        // The first launch: the intro plays once, then the notch says hello.
        if IntroGate.shouldPlay(seen: UserDefaults.standard.bool(forKey: "introShown"), environment: ProcessInfo.processInfo.environment) {
            UserDefaults.standard.set(true, forKey: "introShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.playIntro() }
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
        notch.start()
        usage.start()
        // VISOR_NO_MUSIC=1 keeps a test run from scripting your players (and asking for permission).
        if ProcessInfo.processInfo.environment["VISOR_NO_MUSIC"] == nil { music.start() }
        setUpStatusItem()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let alive = { (pid: Int32) in kill(pid, 0) == 0 || errno == EPERM }
                let gone = self.agents.sessions.filter { $0.pid > 0 && !alive($0.pid) }.map(\.id)
                self.agents.prune(isAlive: alive)
                self.publishAgents()
                for session in gone { self.hooks.releaseApprovals(session: session) }
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
        guard model.expanded, model.welcome, model.approvals.isEmpty, [36, 76].contains(event.keyCode) else { return false }
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

    // MARK: Context window

    private let contextQueue = DispatchQueue(label: "visor.context", qos: .utility)
    private var contextPending: Set<String> = []

    /// After a Claude Code reply, reads how full the session's context is from
    /// the end of its transcript, off the main thread, once per burst of events.
    private func readContextSoon(_ message: HookMessage) {
        guard message.provider == "claude", ["PostToolUse", "Stop", "SessionStart"].contains(message.event),
              let session = message.sessionID, let path = message.payload["transcript_path"] as? String,
              contextPending.insert(session).inserted else { return }
        // Claude Code may still be writing the reply when the hook runs.
        contextQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let (tokens, model) = autoreleasepool { (Self.contextTokens(at: path), Self.claudeModelSetting()) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.contextPending.remove(session)
                    self.agents.setContext(tokens: tokens, model: model, session: session)
                    self.publishAgents()
                }
            }
        }
    }

    private nonisolated static func contextTokens(at path: String) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail = UInt64(ContextUsage.tailBytes)
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        return (try? handle.readToEnd()).flatMap(ContextUsage.tokens(inTail:))
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
        // {"event":"_clipdelete","raw":{}} deletes the newest clipboard item.
        if message.event == "_clipdelete", let first = model.clips.items.first {
            clipboard.delete(first.id)
            return
        }
        // {"event":"_show","raw":{"tab":"usage"}} opens a tab; tab "none" collapses; "keyboard":true focuses the clipboard search; "accounts":true shows Connected accounts; "helpers":"<session id>" opens that session's subagents; "office":true/false switches the Agents tab ("world":"galaxy" picks its world); "tokens":true/false the Usage tab ("page":"models" picks its view); "clipHover":n hovers a clipboard row.
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
        if message.event == "_intro" {
            playIntro()
            return
        }
        if message.event == "_show" {
            let tab = message.payload["tab"] as? String
            model.pinned = tab != nil && tab != "none"
            if let tab = tab.flatMap(Tab.init(rawValue:)) { model.tab = tab; notch.expand() } else { model.expanded = false }
            if message.payload["keyboard"] as? Bool == true { model.focusClipSearch?() }
            model.showAccounts = message.payload["accounts"] as? Bool == true
            if let helpers = message.payload["helpers"] as? String { model.helpersOpen = helpers.isEmpty ? nil : helpers }
            if let office = message.payload["office"] as? Bool { model.agentsOffice = office }
            if let world = message.payload["world"] as? String { model.officeWorld = OfficeWorld(saved: world) }
            if let picker = message.payload["worldPicker"] as? Bool { model.officePicker = picker }
            if let tokens = message.payload["tokens"] as? Bool { model.usageTokens = tokens }
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
        agents.apply(message)
        noteEdit(message)
        readContextSoon(message)
        if let session = message.sessionID, agents.sessions.first(where: { $0.id == session })?.host == nil {
            if let app = ProcessTree.hostAppPath(of: message.pid) {
                let host = ProcessTree.appName(at: app)
                if model.hostIcons[host] == nil { model.hostIcons[host] = NSWorkspace.shared.icon(forFile: app) }
                agents.setHost(host, session: session)
            }
        }
        // The session moved on (answered in the terminal, interrupted, new prompt): its approvals are moot.
        if let session = message.sessionID, let release = ApprovalRelease.after(message) {
            switch release {
            case .all: hooks.releaseApprovals(session: session)
            case .tool(let tool): hooks.releaseApprovals(session: session, tool: tool)
            }
        }
        noteAnsweredQuestion(message)
        if let approval {
            switch ApprovalRoute.of(approval, inNotch: Self.approvalsInNotch, rules: copilotRules) {
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
            // Its summary waits behind the peek, unless the notch is already open for something else.
            if !model.expanded && !done.stats.isEmpty { model.summary = done }
            show(.done(done), for: 5)
        }
    }

    /// A question answered in the terminal shows "Answered" in the closed notch.
    private func noteAnsweredQuestion(_ message: HookMessage) {
        guard message.toolName == AgentQuestion.tool,
              message.event == "PostToolUse" || message.event == "PostToolUseFailure",
              let session = message.sessionID,
              let agent = agents.sessions.first(where: { $0.id == session })?.agent else { return }
        show(.answered(agent: agent), for: 2.5)
    }

    /// Brings the app an agent runs in to the front, where its prompt is.
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

    /// The changes a turn made, as a diff in the default text editor.
    private func openDiff(_ turn: FinishedTurn) {
        let files = turn.stats.files, cwd = turn.cwd
        DispatchQueue.global(qos: .userInitiated).async {
            /// Runs git in the project; its output, and whether it exited cleanly.
            func git(_ arguments: [String]) -> (Data, Bool) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", cwd] + arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return (Data(), false) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (data, process.terminationStatus == 0)
            }
            // Tracked files as usual; files git doesn't know yet as new files, without touching the repo.
            var data = git(["diff", "--"] + files).0
            for file in files where !git(["ls-files", "--error-unmatch", "--", file]).1 {
                data.append(git(["diff", "--no-index", "--", "/dev/null", file]).0)
            }
            guard !data.isEmpty else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("visor-\(turn.project).diff")
            guard (try? data.write(to: url)) != nil else { return }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-t", url.path]
            try? open.run()
        }
    }

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
        hooks.reply(request, decision)
        model.approvals.removeAll { $0.id == request.id }
        if decision != nil { agents.resolveApproval(session: request.sessionID) }
        publishAgents()
        notch.collapseIfAway()
    }

    /// The hook gave up (timed out, or Claude Code was interrupted).
    private func approvalGone(_ id: UUID, _ reason: HookServer.LetGo) {
        if let approval = model.approvals.first(where: { $0.id == id }) {
            switch reason {
            case .allowedInTerminal: agents.answeredInTerminal(session: approval.sessionID, allowed: true)
            case .endedInTerminal: agents.answeredInTerminal(session: approval.sessionID, allowed: false)
            case .timedOut, .movedOn: break
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

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The visor from the app icon, tinted by macOS for light and dark menu bars.
        let icon = Bundle.main.image(forResource: "MenuIcon")
            ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Visor")
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Visor"
        item.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "About Visor", action: #selector(showAbout), keyEquivalent: "").target = self
        if let version = UpdateFeed.shared.readyVersion {
            menu.addItem(withTitle: "Restart to Update to \(version)", action: #selector(installUpdate), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Check for Updates\u{2026}", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        let automatic = menu.addItem(withTitle: "Install Updates Automatically", action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
        automatic.target = self
        automatic.state = updater.updater.automaticallyDownloadsUpdates ? .on : .off
        menu.addItem(.separator())
        // Keep awake: the cup in the Agents tab sets Auto, On or Off; these two refine it.
        menu.addItem(.sectionHeader(title: "Keep Awake"))
        addToggle(to: menu, "Keep the Screen On Too", on: model.awakeScreen, #selector(toggleAwakeScreen))
        addToggle(to: menu, "Only Above 20% Battery", on: model.awakeBatteryLimit, #selector(toggleAwakeBattery))
        menu.addItem(.separator())
        let claude = HookInstaller.isInstalled
        let antigravity = HookInstaller.antigravityInstalled
        model.hooksInstalled = claude
        model.antigravityHooksInstalled = antigravity

        // Agents: a tick means connected; choosing one connects or disconnects it.
        menu.addItem(.sectionHeader(title: "Agents"))
        let claudeItem = addToggle(to: menu, "Claude Code", on: claude, #selector(toggleClaude))
        if !HookInstaller.hasClaudeCode && !claude {
            // Nothing to connect: greyed out, and says why.
            claudeItem.action = nil
            claudeItem.toolTip = "Claude Code isn't installed on this Mac"
        }
        if HookInstaller.hasCopilotCLI {
            addToggle(to: menu, "Copilot CLI", on: HookInstaller.copilotInstalled, #selector(toggleCopilot))
        }
        if HookInstaller.hasAntigravityCLI {
            addToggle(to: menu, "Antigravity CLI", on: antigravity, #selector(toggleAntigravity))
        }
        menu.addItem(.separator())

        let approvals = addToggle(to: menu, "Approvals in the Notch", on: Self.approvalsInNotch, #selector(toggleApprovals))
        approvals.toolTip = "Claude Code and Copilot CLI ask in the notch. Off, they ask in their own terminal. Antigravity always asks in its terminal."
        addToggle(to: menu, "Launch at Login", on: SMAppService.mainApp.status == .enabled, #selector(toggleLogin))
        menu.addItem(.separator())
        let extensionItem = menu.addItem(withTitle: "Browser Extension for Music\u{2026}", action: #selector(showBrowserExtension), keyEquivalent: "")
        extensionItem.target = self
        extensionItem.toolTip = "Show and control music in any browser, Firefox and Zen included"
        menu.addItem(withTitle: "Plugins Folder", action: #selector(openPluginsFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quit Visor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @discardableResult
    private func addToggle(to menu: NSMenu, _ title: String, on: Bool, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleClaude() {
        if HookInstaller.isInstalled {
            try? HookInstaller.uninstall()
        } else {
            do {
                try HookInstaller.install()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't connect Claude Code"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        model.hooksInstalled = HookInstaller.isInstalled
    }

    @objc private func refreshUsage() { usage.refreshPlan() }
    @objc private func openPluginsFolder() { plugins.openFolder() }

    /// Copies the Visor Media extension where it can stay loaded, shows it in
    /// Finder and says how to add it to a browser.
    @objc private func showBrowserExtension() {
        guard let folder = BrowserBridgeServer.copyExtension() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        let alert = NSAlert()
        alert.messageText = "Add Visor Media to your browser"
        alert.informativeText = """
        With it, the notch shows and controls music and video in any browser, Firefox and Zen included, \
        and plays, pauses and skips the exact tab.

        Chrome, Dia, Arc, Brave, Edge: open the Extensions page, turn on Developer mode, choose \
        Load unpacked and pick the Extension folder now shown in Finder.

        Firefox and Zen: open about:debugging, choose This Firefox (This Zen), then Load Temporary \
        Add-on and pick manifest.json in that folder. Firefox forgets it on quit until Visor Media is on Firefox Add-ons.
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// The standard About panel, with the links from `About` under the version.
    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates(nil)
    }

    @objc private func toggleAwakeScreen() { model.awakeScreen.toggle() }
    @objc private func toggleAwakeBattery() { model.awakeBatteryLimit.toggle() }

    @objc private func toggleAutomaticUpdates() {
        updater.updater.automaticallyDownloadsUpdates.toggle()
    }

    @objc private func installUpdate() {
        UpdateFeed.shared.installNow?()
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString()
        for (i, link) in About.links.enumerated() {
            if i > 0 { credits.append(NSAttributedString(string: "   ")) }
            credits.append(NSAttributedString(string: link.title, attributes: [.link: link.url]))
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: centered],
                              range: NSRange(location: 0, length: credits.length))
        // Visor has no Dock icon and macOS may refuse to activate it, so the
        // panel is also put in front by hand or it opens behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        if aboutPanel == nil { aboutPanel = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) } }
        aboutPanel?.orderFrontRegardless()
    }

    private weak var aboutPanel: NSWindow?

    @objc private func toggleApprovals() { Self.approvalsInNotch.toggle() }

    @objc private func toggleCopilot() {
        if HookInstaller.copilotInstalled { try? HookInstaller.uninstallCopilot() } else { try? HookInstaller.installCopilot() }
    }

    @objc private func toggleAntigravity() {
        if HookInstaller.antigravityInstalled {
            try? HookInstaller.uninstallAntigravity()
        } else {
            try? HookInstaller.installAntigravity()
        }
        model.antigravityHooksInstalled = HookInstaller.antigravityInstalled
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Visor: launch at login failed: \(error)")
        }
    }
}

enum ProcessTree {
    /// The app a process runs under (the terminal or editor hosting Claude
    /// Code), found by walking up its parents to the first one inside a .app.
    static func hostAppPath(of pid: Int32) -> String? {
        var current = pid
        for _ in 0..<12 where current > 1 {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(current, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
            }
            guard let parent = parent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    /// The bundle id of that app, to bring it to the front.
    static func hostBundleID(of pid: Int32) -> String? {
        hostAppPath(of: pid).flatMap { Bundle(path: $0)?.bundleIdentifier }
    }

    /// The name that app shows, e.g. "Ghostty".
    static func appName(at app: String) -> String {
        let bundle = Bundle(path: app)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// Works for processes of any user (proc_pidinfo can't read root's, such as /usr/bin/login).
    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The processes a process started, e.g. the shells an agent runs commands in.
    static func children(of pid: Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    /// A process's command line, its arguments joined by spaces, as `ps` shows it.
    static func arguments(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // argc, the executable path, padding, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var fields = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true).dropFirst()
        fields = fields.prefix(Int(argc))
        return fields.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
    }

    /// Hooks may run under an intermediate shell; walk up to the agent's process
    /// (claude, copilot or agy) so its exit can be noticed. Falls back to the pid given.
    static func agentAncestor(of pid: Int32) -> Int32 {
        var current = pid
        for _ in 0..<4 where current > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let lower = name.lowercased()
            if lower.contains("claude") || lower.contains("copilot") || lower == "agy" || lower.contains("antigravity") {
                return current
            }
            current = Int32(info.pbi_ppid)
        }
        return pid
    }
}

/// Where updates come from: Info.plist's SUFeedURL, or VISOR_UPDATE_FEED to
/// try an update from a local appcast before releasing it.
/// A downloaded update waits for Visor to quit; the menu offers to restart now.
final class UpdateFeed: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateFeed()
    private(set) var readyVersion: String?
    private(set) var installNow: (() -> Void)?

    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["VISOR_UPDATE_FEED"]
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        readyVersion = item.displayVersionString
        installNow = immediateInstallHandler
        return true
    }
}

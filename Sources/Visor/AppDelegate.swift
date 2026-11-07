import AppKit
import Darwin
import VisorCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private lazy var notch = NotchController(model: model)
    private lazy var usage = UsageService(model: model)
    private lazy var music = MusicService(model: model)
    private lazy var bar = BarService(model: model)
    private lazy var clipboard = ClipboardService(model: model)
    private var clipboardHotKey: HotKey?
    private let hooks = HookServer()
    private var statusItem: NSStatusItem?
    private var pruneTimer: Timer?
    private var finishedWork: DispatchWorkItem?

    /// Every agent session, updated on each hook event. The notch gets a copy
    /// only when something it shows changes: most tool calls just move the
    /// last-event time, and redrawing for those would be wasted work.
    private var agents = AgentBoard()

    private func publishAgents() {
        if agents.differsVisibly(from: model.board) { model.board = agents }
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

    /// Menu bar switch; on by default.
    static var copilotApprovalsOn: Bool {
        get { UserDefaults.standard.object(forKey: "copilotApprovals") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "copilotApprovals") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HookServer.migrateFromNotchboard()
        model.hooksInstalled = HookInstaller.isInstalled
        if model.hooksInstalled {
            // Keep the script current with this version of the app.
            try? HookInstaller.install()
            if HookInstaller.copilotInstalled { try? HookInstaller.installCopilot() }
        }
        model.installHooks = { [weak self] in self?.installHooks() }
        model.refreshPlan = { [weak self] in self?.usage.refreshIfStale() }
        model.musicCommand = { [weak self] in self?.music.perform($0) }
        model.setVolume = { [weak self] in self?.music.setVolume($0) }
        model.refreshVolume = { [weak self] in self?.music.refreshVolume() }
        model.decide = { [weak self] request, decision in self?.decide(request, decision) }
        model.handOff = { [weak self] question, activate in self?.handOff(question, activate: activate) }
        model.answer = { [weak self] question in self?.answer(question) }

        hooks.onMessage = { [weak self] message, approval in self?.received(message, approval) }
        hooks.onApprovalGone = { [weak self] id in self?.approvalGone(id) }
        do { try hooks.start() } catch { NSLog("Visor: hook socket failed: \(error)") }

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
        clipboard.start()
        clipboardHotKey = HotKey.clipboard { [weak self] in
            MainActor.assumeIsolated { self?.openClipboard() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let key = event
            let handled = MainActor.assumeIsolated { self?.clipboardKey(key) == true }
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
                self.dropStaleQuestions()
                for session in gone {
                    self.model.questionHolds[session] = nil
                    self.hooks.releaseApprovals(session: session)
                }
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

    /// Keys while the clipboard tab has the keyboard. Returns true when handled.
    private func clipboardKey(_ event: NSEvent) -> Bool {
        guard model.expanded, model.tab == .clipboard else { return false }
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

    // MARK: Agents

    private func received(_ message: HookMessage, _ approval: ApprovalRequest?) {
        #if DEBUG
        // Debug builds: {"event":"_decide","raw":{"decision":"allow|always|deny"}} answers the first approval.
        if message.event == "_decide", let first = model.approvals.first {
            let answer = message.payload["decision"] as? String
            decide(first, answer == "deny" ? .deny : answer == "always" ? .allowAlways : .allow)
            return
        }
        // {"event":"_handoff","raw":{}} hides the first question card, as "Hide" does.
        if message.event == "_handoff", let first = model.openQuestion {
            handOff(first, activate: false)
            return
        }
        // {"event":"_pick","raw":{"option":1}} picks an option on the open question; _send sends it.
        if message.event == "_pick", let option = message.payload["option"] as? Int {
            model.questionPicks[model.questionPage, default: []].insert(option)
            return
        }
        if message.event == "_send", let first = model.openQuestion {
            answer(first)
            return
        }
        // {"event":"_music","raw":{"title":..,"artist":..,"art":"/path.png","playing":true}} fakes a song.
        if message.event == "_music" {
            let p = message.payload
            let image = (p["art"] as? String).flatMap { NSImage(contentsOfFile: $0) }
            model.nowPlaying = NowPlaying(source: .browser(bundleID: "company.thebrowser.dia", tab: "", scriptable: false),
                                          sourceName: p["source"] as? String ?? "Dia · YouTube",
                                          title: p["title"] as? String ?? "", artist: p["artist"] as? String ?? "",
                                          album: "", duration: (p["duration"] as? NSNumber)?.doubleValue ?? 0,
                                          position: (p["position"] as? NSNumber)?.doubleValue ?? 0, positionAt: Date(),
                                          isPlaying: p["playing"] as? Bool ?? true)
            model.artwork = image
            model.artworkTint = image.flatMap(MusicService.tint(of:))
            model.artworkBackdrop = image.flatMap(MusicService.backdrop(of:))
            if let allowed = p["mediaKeysAllowed"] as? Bool { model.mediaKeysAllowed = allowed }
            return
        }
        // {"event":"_clipdelete","raw":{}} deletes the newest clipboard item.
        if message.event == "_clipdelete", let first = model.clips.items.first {
            clipboard.delete(first.id)
            return
        }
        // {"event":"_show","raw":{"tab":"usage"}} opens a tab; tab "none" collapses.
        if message.event == "_show" {
            let tab = message.payload["tab"] as? String
            model.pinned = tab != nil && tab != "none"
            if let tab = tab.flatMap(Tab.init(rawValue:)) { model.tab = tab; notch.expand() } else { model.expanded = false }
            return
        }
        #endif
        var message = message
        message.pid = ProcessTree.agentAncestor(of: message.pid)
        agents.apply(message)
        if let session = message.sessionID, agents.sessions.first(where: { $0.id == session })?.host == nil {
            agents.setHost(ProcessTree.hostApp(of: message.pid), session: session)
        }
        // The session moved on (answered in the terminal, interrupted, new prompt): its approvals are moot.
        if let session = message.sessionID, let release = ApprovalRelease.after(message) {
            switch release {
            case .all: hooks.releaseApprovals(session: session)
            case .tool(let tool): hooks.releaseApprovals(session: session, tool: tool)
            }
        }
        noteQuestion(message)
        // A question's card only belongs on screen while its session waits on it.
        dropStaleQuestions()
        if let approval, approval.isQuestion {
            // Held so the card can answer it; the terminal shows the question meanwhile.
            model.questionHolds[approval.sessionID] = approval
        } else if let approval {
            if approval.provider == "copilot" && !Self.copilotApprovalsOn {
                // Off: Copilot asks in its own terminal.
                hooks.reply(approval, nil)
            } else if approval.provider == "copilot" && copilotRules.allows(approval) {
                // Allowed before with "Always": answer at once, no card.
                hooks.reply(approval, .allow)
                agents.resolveApproval(session: approval.sessionID)
            } else {
                model.approvals.append(approval)
                notch.expand()
            }
        }
        publishAgents()
        if let done = agents.finished(message) { show(.done(done), for: 5) }
    }

    /// Questions come and go with the session's events: asked (PreToolUse), answered
    /// in the terminal (PostToolUse), or made moot (a new prompt, a stop).
    private func noteQuestion(_ message: HookMessage) {
        guard let session = message.sessionID else { return }
        if message.event == "PreToolUse" || message.event == "PermissionRequest", let question = AgentQuestion(message) {
            guard !model.questions.contains(question) else { return }
            model.questions.removeAll { $0.sessionID == session }
            model.handedOff[session] = nil
            model.questions.append(question)
            if model.openQuestion == question { model.questionPicks = [:] }
            notch.expand()
            return
        }
        let asked = model.questions.first { $0.sessionID == session }
        switch message.event {
        case "PostToolUse" where message.toolName == AgentQuestion.tool,
             "PostToolUseFailure" where message.toolName == AgentQuestion.tool:
            if let asked { show(.answered(agent: asked.agent), for: 2.5) }
            dropQuestion(session: session)
        case "UserPromptSubmit", "Stop", "SessionEnd":
            dropQuestion(session: session)
        default:
            break
        }
    }

    private func dropQuestion(session: String) {
        guard model.questions.contains(where: { $0.sessionID == session }) || model.handedOff[session] != nil else { return }
        model.questions.removeAll { $0.sessionID == session }
        model.handedOff[session] = nil
        notch.collapseIfAway()
    }

    /// Drops cards for questions whose session answered elsewhere, finished, or
    /// went away; without this an old card stays in the notch for good.
    private func dropStaleQuestions() {
        for question in model.questions where !agents.stillAsking(question) {
            dropQuestion(session: question.sessionID)
        }
    }

    /// "Answer in Ghostty": the terminal already shows the question; hide the card,
    /// keep the "?" until it's answered, and bring the terminal forward if asked.
    private func handOff(_ question: AgentQuestion, activate: Bool) {
        let host = agents.sessions.first { $0.id == question.sessionID }?.host ?? "terminal"
        model.handedOff[question.sessionID] = host
        model.questionPicks = [:]
        // Let go of the held step: the terminal's own prompt answers it.
        if let held = model.questionHolds.removeValue(forKey: question.sessionID) { hooks.reply(held, nil) }
        if activate, let id = ProcessTree.hostBundleID(of: question.pid) {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
        }
        notch.collapseIfAway()
    }

    /// Answers from the card: allow the question with the picked options filled in.
    private func answer(_ question: AgentQuestion) {
        let answers = question.answers(picks: model.questionPicks)
        guard !answers.isEmpty, let held = model.questionHolds.removeValue(forKey: question.sessionID) else { return }
        hooks.reply(held, .answer(answers))
        agents.resolveQuestion(session: question.sessionID)
        publishAgents()
        model.questionPicks = [:]
        model.questions.removeAll { $0.id == question.id }
        show(.answered(agent: question.agent), for: 2.5)
        notch.collapseIfAway()
    }

    private func show(_ peek: Peek, for seconds: TimeInterval) {
        model.peek = peek
        finishedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.model.peek = nil } }
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
    private func approvalGone(_ id: UUID) {
        model.approvals.removeAll { $0.id == id }
        // A question's hook gave up: the card can only point to the terminal now.
        if let session = model.questionHolds.first(where: { $0.value.id == id })?.key { model.questionHolds[session] = nil }
        notch.collapseIfAway()
    }

    private func installHooks() {
        do {
            try HookInstaller.install()
            try? HookInstaller.installCopilot()
            model.hooksInstalled = true
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
        let installed = HookInstaller.isInstalled
        model.hooksInstalled = installed
        menu.addItem(withTitle: installed ? "Claude Code connected" : "Connect Claude Code",
                     action: installed ? nil : #selector(connect), keyEquivalent: "").target = self
        if installed {
            menu.addItem(withTitle: "Disconnect Claude Code", action: #selector(disconnect), keyEquivalent: "").target = self
        }
        if HookInstaller.hasCopilotCLI {
            let copilot = HookInstaller.copilotInstalled
            menu.addItem(withTitle: copilot ? "Disconnect Copilot CLI" : "Connect Copilot CLI",
                         action: #selector(toggleCopilot), keyEquivalent: "").target = self
            if copilot {
                let approvals = menu.addItem(withTitle: "Copilot Approvals in the Notch", action: #selector(toggleCopilotApprovals), keyEquivalent: "")
                approvals.target = self
                approvals.state = Self.copilotApprovalsOn ? .on : .off
            }
        }
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Visor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func connect() { installHooks() }

    @objc private func disconnect() {
        try? HookInstaller.uninstall()
        try? HookInstaller.uninstallCopilot()
        model.hooksInstalled = false
    }

    @objc private func refreshUsage() { usage.refreshPlan() }

    @objc private func toggleCopilotApprovals() { Self.copilotApprovalsOn.toggle() }

    @objc private func toggleCopilot() {
        if HookInstaller.copilotInstalled { try? HookInstaller.uninstallCopilot() } else { try? HookInstaller.installCopilot() }
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
    /// The bundle id of that app, to bring it to the front.
    static func hostBundleID(of pid: Int32) -> String? {
        var current = pid
        for _ in 0..<12 where current > 1 {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(current, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if let range = path.range(of: ".app/") {
                    return Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
                }
            }
            guard let parent = parent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    static func hostApp(of pid: Int32) -> String? {
        var current = pid
        for _ in 0..<12 where current > 1 {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(current, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if let range = path.range(of: ".app/") {
                    let app = String(path[..<range.lowerBound]) + ".app"
                    let bundle = Bundle(path: app)
                    return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                }
            }
            guard let parent = parent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    /// Works for processes of any user (proc_pidinfo can't read root's, such as /usr/bin/login).
    static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Hooks may run under an intermediate shell; walk up to the agent's process
    /// (claude or copilot) so its exit can be noticed. Falls back to the pid given.
    static func agentAncestor(of pid: Int32) -> Int32 {
        var current = pid
        for _ in 0..<4 where current > 1 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let lower = name.lowercased()
            if lower.contains("claude") || lower.contains("copilot") { return current }
            current = Int32(info.pbi_ppid)
        }
        return pid
    }
}

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
        guard agents.differsVisibly(from: model.board) else { return }
        model.board = agents
        saveAgentsSoon()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        restoreAgents()
        hooks.onMessage = { [weak self] message, approval in self?.received(message, approval) }
        hooks.onApprovalGone = { [weak self] id, reason in self?.approvalGone(id, reason) }
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
        model.focusClipSearch = { [weak self] in self?.notch.openWithKeyboard(.clipboard) }
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

    // MARK: Agents

    private func received(_ message: HookMessage, _ approval: ApprovalRequest?) {
        #if DEBUG
        // Debug builds: {"event":"_decide","raw":{"decision":"allow|always|deny"}} answers the first approval.
        if message.event == "_decide", let first = model.approvals.first {
            let answer = message.payload["decision"] as? String
            decide(first, answer == "deny" ? .deny : answer == "always" ? .allowAlways : .allow)
            return
        }
        // {"event":"_music","raw":{"title":..,"artist":..,"art":"/path.png","playing":true,"known":false}} fakes a song.
        if message.event == "_music" {
            let p = message.payload
            let image = (p["art"] as? String).flatMap { NSImage(contentsOfFile: $0) }
            model.nowPlaying = NowPlaying(source: .browser(bundleID: "company.thebrowser.dia", tab: "", scriptable: false),
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
        // {"event":"_clipdelete","raw":{}} deletes the newest clipboard item.
        if message.event == "_clipdelete", let first = model.clips.items.first {
            clipboard.delete(first.id)
            return
        }
        // {"event":"_show","raw":{"tab":"usage"}} opens a tab; tab "none" collapses; "keyboard":true focuses the clipboard search; "accounts":true shows Connected accounts.
        if message.event == "_show" {
            let tab = message.payload["tab"] as? String
            model.pinned = tab != nil && tab != "none"
            if let tab = tab.flatMap(Tab.init(rawValue:)) { model.tab = tab; notch.expand() } else { model.expanded = false }
            if message.payload["keyboard"] as? Bool == true { model.focusClipSearch?() }
            model.showAccounts = message.payload["accounts"] as? Bool == true
            return
        }
        #endif
        var message = message
        message.pid = ProcessTree.agentAncestor(of: message.pid)
        agents.apply(message)
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
        if let done = agents.finished(message) { show(.done(done), for: 5) }
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
    private func focus(_ session: AgentSession) {
        guard let id = ProcessTree.hostBundleID(of: session.pid) else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
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
        let claude = HookInstaller.isInstalled
        let antigravity = HookInstaller.antigravityInstalled
        model.hooksInstalled = claude
        model.antigravityHooksInstalled = antigravity

        // Agents: a tick means connected; choosing one connects or disconnects it.
        menu.addItem(.sectionHeader(title: "Agents"))
        addToggle(to: menu, "Claude Code", on: claude, #selector(toggleClaude))
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

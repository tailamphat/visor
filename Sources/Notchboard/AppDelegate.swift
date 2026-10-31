import AppKit
import Darwin
import NotchboardCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private lazy var notch = NotchController(model: model)
    private lazy var usage = UsageService(model: model)
    private lazy var music = MusicService(model: model)
    private lazy var bar = BarService(model: model)
    private let hooks = HookServer()
    private var statusItem: NSStatusItem?
    private var pruneTimer: Timer?
    private var finishedWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        hooks.onMessage = { [weak self] message, approval in self?.received(message, approval) }
        hooks.onApprovalGone = { [weak self] id in self?.approvalGone(id) }
        do { try hooks.start() } catch { NSLog("Notchboard: hook socket failed: \(error)") }

        notch.onExpand = { [weak self] tab in
            if tab == .usage { self?.usage.refreshIfStale() }
            if tab == .music { self?.music.refreshVolume() }
        }
        model.barActions = bar
        bar.start()
        watchBarVisibility()
        notch.start()
        usage.start()
        // NOTCHBOARD_NO_MUSIC=1 keeps a test run from scripting your players (and asking for permission).
        if ProcessInfo.processInfo.environment["NOTCHBOARD_NO_MUSIC"] == nil { music.start() }
        setUpStatusItem()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var board = self.model.board
                board.prune { kill($0, 0) == 0 || errno == EPERM }
                if board != self.model.board { self.model.board = board }
            }
        }
        pruneTimer?.tolerance = 1
    }

    /// The bar's live widgets sample only while the Bar tab is on screen.
    private func watchBarVisibility() {
        withObservationTracking {
            bar.setVisible(model.expanded && model.tab == .bar && model.approvals.isEmpty)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.watchBarVisibility() } }
        }
    }

    // MARK: Agents

    private func received(_ message: HookMessage, _ approval: ApprovalRequest?) {
        #if DEBUG
        // Debug builds: {"event":"_decide","raw":{"decision":"allow|deny"}} answers the first approval.
        if message.event == "_decide", let first = model.approvals.first {
            decide(first, message.payload["decision"] as? String == "deny" ? .deny : .allow)
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
        model.board.apply(message)
        if let session = message.sessionID, model.board.sessions.first(where: { $0.id == session })?.host == nil {
            model.board.setHost(ProcessTree.hostApp(of: message.pid), session: session)
        }
        // The session moved on (answered in the terminal, interrupted, new prompt): its approvals are moot.
        if let session = message.sessionID, let release = ApprovalRelease.after(message) {
            switch release {
            case .all: hooks.releaseApprovals(session: session)
            case .tool(let tool): hooks.releaseApprovals(session: session, tool: tool)
            }
        }
        if let approval {
            model.approvals.append(approval)
            notch.expand()
        }
        if message.event == "Stop" {
            model.justFinished = true
            finishedWork?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.model.justFinished = false } }
            finishedWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    private func decide(_ request: ApprovalRequest, _ decision: ApprovalRequest.Decision?) {
        hooks.reply(request, decision)
        model.approvals.removeAll { $0.id == request.id }
        if decision != nil { model.board.resolveApproval(session: request.sessionID) }
        notch.collapseIfAway()
    }

    /// The hook gave up (timed out, or Claude Code was interrupted).
    private func approvalGone(_ id: UUID) {
        model.approvals.removeAll { $0.id == id }
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
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Notchboard")
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
        }
        menu.addItem(withTitle: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notchboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func connect() { installHooks() }

    @objc private func disconnect() {
        try? HookInstaller.uninstall()
        try? HookInstaller.uninstallCopilot()
        model.hooksInstalled = false
    }

    @objc private func refreshUsage() { usage.refreshPlan() }

    @objc private func toggleCopilot() {
        if HookInstaller.copilotInstalled { try? HookInstaller.uninstallCopilot() } else { try? HookInstaller.installCopilot() }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Notchboard: launch at login failed: \(error)")
        }
    }
}

enum ProcessTree {
    /// The app a process runs under (the terminal or editor hosting Claude
    /// Code), found by walking up its parents to the first one inside a .app.
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

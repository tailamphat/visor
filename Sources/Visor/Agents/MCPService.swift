import Foundation
import VisorCore

/// MCP health for the Agents tab: configured servers (names only, read off main when the
/// session folders or a config file change) joined with the MCP calls seen in hook events.
/// Event-driven: no timer, no file watcher. Writes `model.mcp` only when it visibly changes.
@MainActor
final class MCPService {
    private let model: AppModel
    private let work = DispatchQueue(label: "visor.mcp", qos: .utility)
    private var stats = MCPStats()
    private var configured: [MCPServerRef] = []
    private var configuredNames: Set<String> = []
    private var refresh = MCPRefresh()
    /// Session folders settle for a second before a re-read (many sessions starting at once).
    private var foldersWork: DispatchWorkItem?
    /// The latest session cwds, newest first.
    private var lastCwds: [String] = []

    init(model: AppModel) {
        self.model = model
    }

    /// The home whose config files are read. Debug builds take `VISOR_MCP_HOME` (a fixture
    /// folder), so test runs and screenshots never show the real server names.
    nonisolated private static var home: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["VISOR_MCP_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func start() {
        run(refresh.request())
    }

    /// The sessions' folders, after each board publish: when the folders worth reading
    /// changed, re-read a second later (newest sessions first, see `MCPConfig.projectFolders`).
    func sessionsChanged(_ sessions: [AgentSession]) {
        lastCwds = sessions.sorted { $0.lastEvent > $1.lastEvent }.map(\.cwd)
        let folders = MCPConfig.projectFolders(lastCwds, home: Self.home.path)
        guard folders != refresh.folders, foldersWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldersWork = nil
                let now = MCPConfig.projectFolders(self.lastCwds, home: Self.home.path)
                if self.refresh.want(folders: now) { self.run(self.refresh.request()) }
            }
        }
        foldersWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The Agents list came on screen: re-read if a config file changed, and drop stale failures.
    func listShown() {
        run(refresh.request())
        publish()
    }

    /// A finished MCP call from a hook event.
    func record(_ message: HookMessage) {
        guard message.event == "PostToolUse" || message.event == "PostToolUseFailure" else { return }
        if stats.record(message, configured: configuredNames, at: Date()) { publish() }
    }

    /// Stats the config files on `work`; reads them only when the folders are new or a stamp changed.
    private func run(_ check: MCPRefresh.Check?) {
        guard let check else { return }
        let home = Self.home
        work.async {
            let result: (MCPConfigStamp, [MCPServerRef]?) = autoreleasepool {
                let now = MCPConfigStamp.of(paths: MCPConfig.paths(home: home, projects: check.folders))
                return (now, now == check.last ? nil : MCPConfig.read(home: home, projects: check.folders))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let refs = result.1, refs != self.configured {
                        self.configured = refs
                        self.configuredNames = Set(refs.map(\.name))
                        self.publish()
                    }
                    self.run(self.refresh.finished(folders: check.folders, stamp: result.0))
                }
            }
        }
    }

    private func publish() {
        let now = Date()
        let summary = MCPSummary.make(health: stats.health(configured: configured, now: now),
                                      failures: stats.failureSummary(now: now))
        if model.mcp != summary { model.mcp = summary }
        if summary == nil { model.mcpOpen = false }
    }
}

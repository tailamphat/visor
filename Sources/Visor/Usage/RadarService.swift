import Foundation
import VisorCore

/// The release radar: every 6 hours (first a couple of minutes after launch),
/// for each AI tool installed on this Mac, reads its version from its own
/// `--version` (only when the binary changed) and the latest version from the
/// feed of the channel it was installed with (npm, Homebrew or GitHub), plus
/// the release notes when it's newer. A new version peeks once; its card stays
/// in Usage until dismissed, or until the tool's binary changes to that version:
/// the folder holding each offered tool's link and the binary itself are
/// watched, a change reruns only `--version` (no network), and a caught-up card
/// says "Updated" for a moment and goes. All work runs on its own queue; the
/// model is written only when the cards change.
final class RadarService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "visor.radar", qos: .utility)
    private var timer: DispatchSourceTimer?
    // Only touched on `queue`.
    private var state = RadarState()
    private var logHandle: FileHandle?
    private lazy var fetcher = ReleaseFetcher { [weak self] in self?.log($0) }
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var refreshItem: DispatchWorkItem?
    /// The folder each offered tool's link was last seen in, kept watched while
    /// an update has the link removed.
    private var linkFolders: [String: String] = [:]
    /// Cards confirming an update, shown for `updatedShown` before they go.
    private var updated: [ReleaseUpdate] = []
    private static let updatedShown: TimeInterval = 3
    /// A brew upgrade touches its folders several times; wait for it to settle.
    private static let settle: TimeInterval = 2

    /// The cards to show changed (main thread).
    var onOffers: (([ReleaseUpdate]) -> Void)?
    /// A version to peek about (main thread).
    var onNew: ((ReleaseUpdate) -> Void)?

    static var stateURL: URL {
        #if DEBUG
        HookServer.directory.appendingPathComponent("release-radar-debug.json")
        #else
        HookServer.directory.appendingPathComponent("release-radar.json")
        #endif
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Visor/radar.log")
    }

    func start() {
        let launch = Date()
        queue.async { [self] in
            // A small file (a few KB); anything far larger isn't ours and is ignored.
            let size = (try? FileManager.default.attributesOfItem(atPath: Self.stateURL.path))?[.size] as? Int ?? 0
            if size > 256_000 {
                log("ignored \(Self.stateURL.lastPathComponent): \(size) bytes")
            } else if let data = try? Data(contentsOf: Self.stateURL), let saved = try? JSONDecoder().decode(RadarState.self, from: data) {
                state = saved
            }
            publish()
            // A tool updated while Visor wasn't running: its card goes now, not at the next check.
            refreshInstalled()
            var delay = max(0, state.nextCheck(now: Date(), launch: launch).timeIntervalSinceNow)
            #if DEBUG
            if ProcessInfo.processInfo.environment["VISOR_RADAR_SOON"] == "1" { delay = 5 }
            #endif
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // Wall clock, so a Mac that slept past a check runs it on wake.
            timer.schedule(wallDeadline: .now() + delay, repeating: RadarState.interval, leeway: .seconds(900))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    /// The card's x.
    func dismiss(_ toolID: String) {
        queue.async { [self] in
            guard state.dismiss(toolID) else { return }
            log("dismissed \(toolID)")
            save()
            publish()
            rewatch()
        }
    }

    // MARK: Checking (on `queue`)

    private func check() {
        autoreleasepool {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var located: [String: String] = [:]
            var links: [String: String] = [:]
            for tool in ReleaseTool.all where !tool.isSkipped {
                guard let path = locate(tool.binary) else { continue }
                links[tool.id] = path
                located[tool.id] = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
            let plan = RadarState.plan(located: located, home: home, formulaTap: Self.formulaTap)
            log("check: found \(located.keys.sorted().joined(separator: ", ")); checking \(plan.map { "\($0.toolID) (\($0.method.rawValue))" }.joined(separator: ", "))")
            var checked: [String: ReleaseUpdate?] = [:]
            for item in plan {
                guard let tool = ReleaseTool.all.first(where: { $0.id == item.toolID }),
                      let link = links[item.toolID], let installed = installedVersion(tool, path: item.path, run: link),
                      let url = tool.versionURL(for: item.method) else { continue }
                guard case .data(let data, _) = fetch(url), let latest = tool.latest(from: data, method: item.method) else { continue }
                var notes: String?
                if installed < latest, let notesURL = tool.notesURL(version: latest), case .data(let body, _) = fetch(notesURL) {
                    notes = tool.github.flatMap { ReleaseFeed.githubRelease(body, tagPrefix: $0.tagPrefix)?.notes }
                }
                let update = ReleaseRadar.update(tool: tool, installed: installed, method: item.method, latest: latest, notes: notes)
                log("\(tool.id): installed \(installed), latest \(latest)" + (update == nil ? "" : ", offer"))
                checked[tool.id] = .some(update)
            }
            state.lastCheck = Date()
            apply(state.merge(checked: checked, installed: Set(plan.map(\.toolID))))
            rewatch()
        }
    }

    /// Where a tool's binary is. Debug builds look in `VISOR_RADAR_PATH` first,
    /// so a proof can swap a fake binary.
    private func locate(_ binary: String) -> String? {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["VISOR_RADAR_PATH"] {
            let path = (dir as NSString).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        #endif
        return Shell.which(binary)
    }

    /// The tap in a Cellar formula's install receipt (a small local file).
    private static func formulaTap(_ path: String) -> String? {
        guard let receipt = BrewReceipt.path(forBinary: path),
              ((try? FileManager.default.attributesOfItem(atPath: receipt))?[.size] as? Int ?? .max) <= 64_000,
              let data = FileManager.default.contents(atPath: receipt) else { return nil }
        return BrewReceipt.tap(data)
    }

    // MARK: After an update (on `queue`)

    /// Reads the version of each offered tool whose binary changed (no network)
    /// and lets a caught-up card confirm and go. Also drops offers for
    /// formulae from another tap.
    private func refreshInstalled() {
        autoreleasepool {
            var located: [String: String] = [:]
            var links: [String: String] = [:]
            for offer in state.offers {
                guard let tool = ReleaseTool.all.first(where: { $0.id == offer.toolID }), let link = locate(tool.binary) else { continue }
                links[tool.id] = link
                located[tool.id] = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
            }
            let before = state
            if state.dropThirdPartyTaps(located: located, formulaTap: Self.formulaTap) { log("dropped offers from other taps") }
            var done: [ReleaseUpdate] = []
            for offer in state.offers {
                guard let tool = ReleaseTool.all.first(where: { $0.id == offer.toolID }),
                      let path = located[tool.id], let link = links[tool.id],
                      let installed = installedVersion(tool, path: path, run: link) else { continue }
                if let confirmed = state.confirm(tool.id, installed: installed) {
                    log("\(tool.id): updated to \(installed)")
                    done.append(confirmed)
                }
            }
            if state != before { save() }
            if state.offers != before.offers {
                updated.removeAll { card in done.contains { $0.toolID == card.toolID } }
                updated += done
                publish()
                if !done.isEmpty {
                    let ids = Set(done.map(\.toolID))
                    queue.asyncAfter(deadline: .now() + Self.updatedShown) { [weak self] in
                        guard let self else { return }
                        updated.removeAll { ids.contains($0.toolID) }
                        publish()
                    }
                }
            }
            rewatch()
        }
    }

    /// Watches the folder holding each visible offer's link (an update relinks
    /// it) and the binary it resolves to (an update replaces it). No offers, no watchers.
    private func rewatch() {
        var paths = Set<String>()
        for offer in state.visibleOffers {
            guard let tool = ReleaseTool.all.first(where: { $0.id == offer.toolID }) else { continue }
            if let link = locate(tool.binary) {
                linkFolders[tool.id] = (link as NSString).deletingLastPathComponent
                paths.insert(URL(fileURLWithPath: link).resolvingSymlinksInPath().path)
            }
            if let folder = linkFolders[tool.id] { paths.insert(folder) }
        }
        linkFolders = linkFolders.filter { id, _ in state.visibleOffers.contains { $0.toolID == id } }
        for path in watchers.keys where !paths.contains(path) { watchers.removeValue(forKey: path)?.cancel() }
        for path in paths where watchers[path] == nil { watch(path) }
    }

    private func watch(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A replaced file is watched again by the refresh's rewatch.
            if !source.data.isDisjoint(with: [.delete, .rename]) { watchers.removeValue(forKey: path)?.cancel() }
            scheduleRefresh()
        }
        source.setCancelHandler { close(fd) }
        watchers[path] = source
        source.resume()
    }

    private func scheduleRefresh() {
        refreshItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refreshInstalled() }
        refreshItem = item
        queue.asyncAfter(deadline: .now() + Self.settle, execute: item)
    }

    /// The tool's own `--version`, run again only when its binary changed.
    /// `run` is the path found in this check (`path` is where it resolves), so
    /// the version is stored under the stamp of the binary that printed it.
    private func installedVersion(_ tool: ReleaseTool, path: String, run: String) -> ToolVersion? {
        guard let stamp = BinaryStamp(path: path) else { return nil }
        if let cached = state.cachedVersion(tool.id, stamp: stamp) { return cached }
        // Node-based CLIs need `node` on PATH; an app gets a bare one.
        var environment = ProcessInfo.processInfo.environment
        let dir = (path as NSString).deletingLastPathComponent
        environment["PATH"] = "\(dir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["NO_COLOR"] = "1"
        guard let output = Shell.probe(run, ["--version"], environment: environment, timeout: 10),
              let version = ToolVersion(output: output) else {
            log("\(tool.id): couldn't read --version")
            return nil
        }
        log("\(tool.id): ran --version -> \(version)")
        state.remember(tool.id, stamp: stamp, version: version)
        return version
    }

    private func fetch(_ url: URL) -> ReleaseFetchResult {
        let result = fetcher.get(url)
        switch result {
        case .data(_, let cached): log("GET \(url.host ?? "")\(url.path): \(cached ? "304" : "200")")
        case .failed(let status): log("GET \(url.host ?? "")\(url.path): failed (\(status))")
        case .refused, .tooLarge: break  // The fetcher logged it.
        }
        return result
    }

    private func apply(_ merge: RadarMerge) {
        save()
        if merge.visibleChanged { publish() }
        if let peek = merge.peek {
            DispatchQueue.main.async { [weak self] in self?.onNew?(peek) }
        }
    }

    private func publish() {
        let offers = state.cards(updated: updated)
        DispatchQueue.main.async { [weak self] in self?.onOffers?(offers) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    /// ~/Library/Logs/Visor/radar.log, started over once it passes 256 KB.
    private func log(_ line: String) {
        if logHandle == nil {
            let fm = FileManager.default
            let url = Self.logURL
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) > 256_000 { try? fm.removeItem(at: url) }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            logHandle = try? FileHandle(forWritingTo: url)
            _ = try? logHandle?.seekToEnd()
        }
        logHandle?.write(Data("\(ISODate.string(Date())) \(line)\n".utf8))
    }

    // MARK: Debug socket

    #if DEBUG
    /// `_radar`: fakes an offer as if a check found it (brew channel).
    func debugFake(toolID: String, installed: String, latest: String, notes: String?) {
        queue.async { [self] in
            guard let tool = ReleaseTool.all.first(where: { $0.id == toolID }),
                  let installed = ToolVersion(installed), let latest = ToolVersion(latest),
                  let method = InstallMethod.allCases.first(where: { tool.versionURL(for: $0) != nil }),
                  let update = ReleaseRadar.update(tool: tool, installed: installed, method: method, latest: latest, notes: notes) else { return }
            log("debug: fake \(toolID) \(installed) -> \(latest)")
            let keep = Set(state.offers.map(\.toolID)).union([toolID])
            apply(state.merge(checked: [toolID: update], installed: keep))
            rewatch()
        }
    }

    func debugClear() {
        queue.async { [self] in
            state = RadarState()
            updated = []
            save()
            publish()
            rewatch()
        }
    }

    /// A real GET that GitHub redirects to codeload.github.com, which must be refused.
    func debugProbeRedirect() {
        queue.async { [self] in
            guard let url = URL(string: "https://api.github.com/repos/anthropics/claude-code/tarball") else { return }
            log("debug: probe redirect \(url.absoluteString) -> \(fetcher.get(url))")
        }
    }

    func debugCheckNow() { queue.async { [self] in check() } }
    #endif
}

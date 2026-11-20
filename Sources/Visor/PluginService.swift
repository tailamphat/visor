import AppKit
import VisorCore

/// Runs the Lua plugins in ~/Library/Application Support/Visor/Plugins/<id>/.
/// Each plugin has its own serial queue; its `visor.every` callbacks run on
/// timers with leeway, so idle plugins cost nothing. Editing a plugin's files
/// reloads it.
@MainActor
final class PluginService {
    nonisolated static var folder: URL { HookServer.directory.appendingPathComponent("Plugins", isDirectory: true) }
    nonisolated static var dataFolder: URL { HookServer.directory.appendingPathComponent("PluginData", isDirectory: true) }
    nonisolated static var logFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Visor", isDirectory: true)
    }

    private let model: AppModel
    var onPeek: ((String, PluginPeek) -> Void)?
    private var runners: [String: PluginRunner] = [:]
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var reloadWork: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        reload()
    }

    /// Stops every plugin and loads them again from disk.
    func reload() {
        for runner in runners.values { runner.stop() }
        runners = [:]
        watchers.forEach { $0.cancel() }
        watchers = []
        var infos: [PluginInfo] = []
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.hasDirectoryPath {
            // The folder for files added or removed; each file for edits in place.
            watch(folder)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where ["lua", "json"].contains(file.pathExtension) { watch(file) }
            do {
                let manifest = try PluginManifest.parse(Data(contentsOf: folder.appendingPathComponent("plugin.json")))
                guard runners[manifest.id] == nil else { continue }
                var info = PluginInfo(id: manifest.id, name: manifest.name, icon: manifest.icon, folder: folder)
                info.accent = manifest.accent
                if model.disabledPlugins.contains(manifest.id) {
                    info.error = "Off"
                } else {
                    let runner = PluginRunner(manifest: manifest, folder: folder, service: self)
                    runners[manifest.id] = runner
                    runner.start()
                }
                infos.append(info)
            } catch {
                let id = folder.lastPathComponent
                var info = PluginInfo(id: id, name: id, icon: "exclamationmark.triangle", folder: folder)
                info.error = "\(error)"
                infos.append(info)
            }
        }
        watch(Self.folder)
        model.plugins = infos
    }

    func openFolder() { NSWorkspace.shared.open(Self.folder) }

    func openDocs() {
        NSWorkspace.shared.open(URL(string: "https://github.com/tailamphat/visor/blob/main/docs/plugins.md")!)
    }

    func openLog(_ id: String) {
        let url = Self.logFolder.appendingPathComponent("\(id).log")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    /// A button, picker or toggle in a plugin's view.
    func act(_ id: String, _ action: String, value: Any?) {
        runners[id]?.act(action, value: value)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        if on { model.disabledPlugins.remove(id) } else { model.disabledPlugins.insert(id) }
        reload()
    }

    /// Reloads shortly after anything in a plugin folder (or the folder list) changes.
    private func watch(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadWork?.cancel()
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
                self?.reloadWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers.append(source)
    }

    // MARK: From runners (main thread)

    fileprivate func update(_ id: String, _ change: (inout PluginInfo) -> Void) {
        guard let index = model.plugins.firstIndex(where: { $0.id == id }) else { return }
        var info = model.plugins[index]
        change(&info)
        if info != model.plugins[index] { model.plugins[index] = info }
    }

    fileprivate func peek(_ id: String, _ peek: PluginPeek) { onPeek?(id, peek) }

    /// Repos the running agents are in, read from their .git folders.
    fileprivate var agentFolders: [String] { Array(Set(model.board.sessions.map(\.cwd))) }
}

/// What the notch shows for one plugin.
struct PluginInfo: Identifiable, Equatable {
    let id: String
    var name: String
    var icon: String
    var folder: URL
    var accent: Int?
    var output = PluginOutput()
    /// Why the plugin couldn't run. With something already shown, the last
    /// view stays and this reads as "couldn't refresh".
    var error: String?
    var updated: Date?
    /// A call into the plugin is running (start, a timer, an action).
    var busy = false
    /// The action whose button is spinning.
    var pendingAction: String?

    var hasOutput: Bool { output.view != nil || !output.sections.isEmpty }
}

/// One running plugin and everything Visor does for it. Lives on its queue.
final class PluginRunner: PluginHost, @unchecked Sendable {
    let manifest: PluginManifest
    private let folder: URL
    private weak var service: PluginService?
    private let queue: DispatchQueue
    private var plugin: LuaPlugin?
    private var timers: [DispatchSourceTimer] = []
    /// Conditional-request cache: an unchanged answer is a free 304.
    private var cache: [URL: (etag: String?, modified: String?, response: PluginResponse)] = [:]
    private var secrets: [String: (value: String?, read: Date)] = [:]
    private var log: FileHandle?

    init(manifest: PluginManifest, folder: URL, service: PluginService) {
        self.manifest = manifest
        self.folder = folder
        self.service = service
        queue = DispatchQueue(label: "visor.plugin.\(manifest.id)", qos: .utility)
    }

    func start() {
        queue.async { [self] in
            openLog()
            do {
                let source = try String(contentsOf: folder.appendingPathComponent(manifest.main), encoding: .utf8)
                let settings = (try? Data(contentsOf: folder.appendingPathComponent("settings.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let store = try? Data(contentsOf: storeURL)
                let plugin = try LuaPlugin(manifest: manifest, source: source, host: self, store: store, settings: settings)
                self.plugin = plugin
                mainUpdate { $0.busy = true }
                defer { mainUpdate { $0.busy = false } }
                try plugin.start()
                for timer in plugin.timers { schedule(timer) }
            } catch {
                failed("\(error)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            timers.forEach { $0.cancel() }
            timers = []
            plugin = nil
            try? log?.close()
        }
    }

    private func schedule(_ timer: LuaPlugin.Timer) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(timer.interval * 1000))
        // Generous leeway lets macOS batch wake-ups with other work.
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(timer.interval * 100)))
        source.setEventHandler { [weak self] in
            guard let self, let plugin = self.plugin else { return }
            self.mainUpdate { $0.busy = true }
            do { try plugin.fire(timer.id) } catch { self.failed("\(error)") }
            self.mainUpdate { $0.busy = false }
        }
        source.resume()
        timers.append(source)
    }

    func act(_ action: String, value: Any?) {
        mainUpdate { $0.pendingAction = action }
        queue.async { [self] in
            do { try plugin?.act(action, value: value) } catch { failed("\(error)") }
            mainUpdate { $0.pendingAction = nil }
        }
    }

    private var storeURL: URL { PluginService.dataFolder.appendingPathComponent("\(manifest.id).json") }

    private func mainUpdate(_ change: @escaping (inout PluginInfo) -> Void) {
        let id = manifest.id
        DispatchQueue.main.async { MainActor.assumeIsolated { self.service?.update(id, change) } }
    }

    // MARK: PluginHost

    func request(_ request: PluginRequest) -> PluginResponse {
        // Visor keeps its own ETag cache below; the system cache would hide changes for
        // up to Cache-Control's max-age (60 s on GitHub), so it's skipped.
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        if urlRequest.value(forHTTPHeaderField: "User-Agent") == nil { urlRequest.setValue("Visor-Plugin/\(manifest.id)", forHTTPHeaderField: "User-Agent") }
        let cached = request.method == "GET" ? cache[request.url] : nil
        if let etag = cached?.etag { urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = cached?.modified { urlRequest.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = PluginResponse(status: 0, body: Data(), headers: [:], cached: false)
        URLSession.shared.dataTask(with: urlRequest) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
                result = PluginResponse(status: http.statusCode, body: data ?? Data(), headers: headers, cached: false)
            }
            done.signal()
        }.resume()
        done.wait()
        if result.status == 304, var old = cached?.response {
            old.cached = true
            return old
        }
        if request.method == "GET", (200..<300).contains(result.status), result.headers["etag"] != nil || result.headers["last-modified"] != nil {
            cache[request.url] = (result.headers["etag"], result.headers["last-modified"], result)
        }
        return result
    }

    func secret(_ name: String, host: String?) -> String? {
        let key = "\(name)|\(host ?? "")"
        if let hit = secrets[key], Date().timeIntervalSince(hit.read) < 1800 { return hit.value }
        guard let template = manifest.secrets[name], let words = PluginSecrets.command(template, host: host),
              let tool = ToolLocator.candidates(words[0], home: FileManager.default.homeDirectoryForCurrentUser.path)
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = Array(words.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        secrets[key] = (value.isEmpty ? nil : value, Date())
        return value.isEmpty ? nil : value
    }

    func repos() -> [PluginRepo] {
        let folders = DispatchQueue.main.sync { MainActor.assumeIsolated { service?.agentFolders ?? [] } }
        var seen = Set<String>()
        return folders.compactMap(Self.repo).filter { seen.insert("\($0.host)/\($0.owner)/\($0.name)/\($0.branch ?? "")").inserted }
    }

    /// The repo a folder is in: walks up to .git (a folder, or a worktree's "gitdir:" file).
    static func repo(in folder: String) -> PluginRepo? {
        var url = URL(fileURLWithPath: folder)
        let fm = FileManager.default
        while url.path != "/" {
            let git = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                var gitDir = git
                var configDir = git
                if !isDir.boolValue, let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") {
                    gitDir = URL(fileURLWithPath: text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: url)
                    // A worktree keeps its HEAD; the config is in the main repo two levels up.
                    configDir = gitDir.deletingLastPathComponent().deletingLastPathComponent()
                }
                guard let config = try? String(contentsOf: configDir.appendingPathComponent("config"), encoding: .utf8),
                      let remote = PluginRepo.originURL(gitConfig: config), let (host, owner, name) = PluginRepo.parseRemote(remote) else { return nil }
                let head = (try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)).flatMap(PluginRepo.branch(head:))
                return PluginRepo(host: host, owner: owner, name: name, branch: head, path: url.path)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        log?.write(Data("\(stamp) \(line)\n".utf8))
    }

    func show(_ output: PluginOutput) {
        mainUpdate {
            $0.output = output
            $0.updated = Date()
            $0.error = nil
        }
    }

    func peek(_ peek: PluginPeek) {
        let id = manifest.id
        DispatchQueue.main.async { MainActor.assumeIsolated { self.service?.peek(id, peek) } }
    }

    func failed(_ message: String) {
        log("error: \(message)")
        mainUpdate { $0.error = message }
    }

    func saveStore(_ data: Data) {
        try? FileManager.default.createDirectory(at: PluginService.dataFolder, withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    /// ~/Library/Logs/Visor/<id>.log, started over once it passes 512 KB.
    private func openLog() {
        let fm = FileManager.default
        try? fm.createDirectory(at: PluginService.logFolder, withIntermediateDirectories: true)
        let url = PluginService.logFolder.appendingPathComponent("\(manifest.id).log")
        if ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) > 512_000 { try? fm.removeItem(at: url) }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        log = try? FileHandle(forWritingTo: url)
        _ = try? log?.seekToEnd()
        log("started \(manifest.name) \(manifest.version)")
    }
}

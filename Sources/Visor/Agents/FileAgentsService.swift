import Foundation
import VisorCore

/// Codex CLI, OpenCode and Gemini CLI sessions, read-only from their own
/// files: Codex rollouts (`$CODEX_HOME/sessions/YYYY/MM/DD/*.jsonl`),
/// OpenCode's `opencode.db` and Gemini CLI chats
/// (`~/.gemini/tmp/<project>/chats/session-*.json(l)`). No hooks and no config
/// edits; nothing here writes to any tool's folders, and nothing of
/// Antigravity's (`~/.gemini/antigravity-cli`, `~/.gemini/config`) is opened.
/// Reads happen only when a file changed: file-system watchers
/// on the live files, plus `scan()` from the app's existing 5 s prune tick to
/// find new rollouts and let old sessions age out. At most one read a second.
final class FileAgentsService: @unchecked Sendable {
    /// One agent's sessions to show, pids filled in; called on main.
    var onScan: ((_ agent: String, _ sessions: [ScannedSession]) -> Void)?

    private let queue = DispatchQueue(label: "visor.file-agents", qos: .utility)
    // Everything below is used on `queue` only.
    private var rollouts: [String: CodexRollout] = [:]
    /// The databases' modification time and the folders OpenCode runs in, at the last read.
    private var openCodeStamp: String?
    private var openCodeSessions: [ScannedSession] = []
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var watchedFolders = Set<String>()
    private var scheduled = false
    private var lastRead = Date.distantPast
    private var trackers: [String: FileAgentTracker] = [:]
    /// Gemini CLI: each chat read so far with the size and date it had then.
    private var geminiChats: [String: (stamp: String, reader: GeminiChat)] = [:]
    /// Gemini CLI: each project folder's chats folder date and session files at the last listing.
    private var geminiListings: [String: (stamp: Date, files: [URL])] = [:]
    /// Gemini CLI: each project folder's `.project_root`, read once.
    private var geminiRoots: [String: String?] = [:]
    private var geminiFolders: (stamp: Date, folders: [URL])?
    /// What each agent last posted to main, without `lastActivity` (it moves on
    /// every line Codex writes, but the board shows nothing for it).
    private var posted: [String: [ScannedSession]] = [:]
    #if DEBUG
    private var loggedOpenCode: String?
    #endif

    /// Read again soon; calls within a second fold into one read.
    func scan() {
        queue.async { self.schedule() }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        let wait = max(0, 1 - Date().timeIntervalSince(lastRead))
        queue.asyncAfter(deadline: .now() + wait) {
            self.scheduled = false
            self.lastRead = Date()
            autoreleasepool { self.read() }
        }
    }

    private func read() {
        let now = Date()
        let sessionsFolder = Self.codexHome.appendingPathComponent("sessions").path
        let databases = openCodeDatabases()
        let hasCodex = FileManager.default.fileExists(atPath: sessionsFolder)
        let geminiTmp = Self.geminiHome.appendingPathComponent("tmp")
        let hasGemini = FileManager.default.fileExists(atPath: geminiTmp.path)
        // Your own processes, only when one of the tools is there at all.
        var names: Set<String> = hasCodex || !databases.isEmpty ? ["codex", "opencode"] : []
        if hasGemini { names.insert("gemini") }
        let nodeScript: ((String) -> String?)? = hasGemini ? { GeminiChat.isGeminiCommand(name: "node", script: $0) ? "gemini" : nil } : nil
        let live = names.isEmpty ? [:] : ProcessTree.processes(named: names, nodeScript: nodeScript)
        let codexLive = live["codex"] ?? [:]
        let openCodeLive = live["opencode"] ?? [:]
        let geminiLive = live["gemini"] ?? [:]
        // The rollout each running Codex has open, however old or wherever it is (`codex resume`).
        var pinnedFiles: [String: Int32] = [:]
        for pid in Set(codexLive.values) {
            for path in ProcessTree.openFiles(of: pid, under: sessionsFolder, ext: "jsonl") { pinnedFiles[path] = pid }
        }
        let (codex, pinned) = hasCodex ? readCodex(now: now, pinnedFiles: pinnedFiles) : ([], [:])
        let openCode = readOpenCode(databases, now: now, liveFolders: Array(openCodeLive.keys))
        post("Codex CLI", codex, live: codexLive, pinned: pinned, now: now)
        post("OpenCode", openCode, live: openCodeLive, pinned: [:], now: now)
        let gemini = hasGemini ? readGemini(geminiTmp, now: now, liveCwds: Array(geminiLive.keys)) : forgetGemini()
        post("Gemini CLI", gemini, live: geminiLive, pinned: [:], now: now)
    }

    /// To main when what the board would show changed; always once per agent,
    /// so sessions restored from the last run are replaced.
    private func post(_ agent: String, _ sessions: [ScannedSession], live: [String: Int32], pinned: [String: Int32], now: Date) {
        var tracker = trackers[agent] ?? FileAgentTracker()
        let shown = tracker.shown(sessions, live: live, pinned: pinned, now: now)
        trackers[agent] = tracker
        let key = shown.map { session -> ScannedSession in
            var session = session
            session.lastActivity = .distantPast
            return session
        }
        guard posted[agent] != key else { return }
        posted[agent] = key
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onScan?(agent, shown) }
        }
    }

    // MARK: Codex CLI

    static var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Today's and yesterday's rollout folders (a session started before midnight keeps its folder).
    private func codexFolders(now: Date) -> [URL] {
        let sessions = Self.codexHome.appendingPathComponent("sessions")
        let calendar = Calendar.current
        return [now, now.addingTimeInterval(-86_400)].map { day in
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            return sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        }
    }

    /// Rollouts changed in the last 30 minutes in today's and yesterday's
    /// folders, plus those a running Codex has open. Returns the sessions and,
    /// by session id, the pid that has each pinned file open.
    private func readCodex(now: Date, pinnedFiles: [String: Int32]) -> ([ScannedSession], [String: Int32]) {
        var seen = Set<String>()
        var out: [ScannedSession] = []
        var pinned: [String: Int32] = [:]
        let folders = codexFolders(now: now)
        // After midnight the day before yesterday's folder is no longer watched.
        for path in watchedFolders.subtracting(folders.map(\.path)) { unwatch(path) }
        watchedFolders.formIntersection(folders.map(\.path))
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]))?
                .filter { $0.pathExtension == "jsonl" } ?? []
            if !files.isEmpty || FileManager.default.fileExists(atPath: folder.path) {
                watch(folder.path)
                watchedFolders.insert(folder.path)
            }
            for url in files where !pinnedFiles.keys.contains(url.path) {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modified = values?.contentModificationDate,
                      now.timeIntervalSince(modified) <= FileAgents.activeWindow else { continue }
                if let session = readRollout(url) { out.append(session) }
                seen.insert(url.path)
            }
        }
        for (path, pid) in pinnedFiles {
            guard let session = readRollout(URL(fileURLWithPath: path)) else { continue }
            out.append(session)
            pinned[session.id] = pid
            seen.insert(path)
        }
        // Rollouts that went quiet are forgotten, and their watchers closed.
        for path in rollouts.keys where !seen.contains(path) {
            rollouts[path] = nil
            unwatch(path)
        }
        return (out, pinned)
    }

    /// One rollout, read on from where the last read stopped, and watched.
    private func readRollout(_ url: URL) -> ScannedSession? {
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let id = url.deletingPathExtension().lastPathComponent
        var reader = rollouts[url.path] ?? CodexRollout(id: id)
        // A file that shrank was rewritten: read it again from the start.
        if size < reader.offset { reader = CodexRollout(id: id) }
        if size > reader.offset, let handle = try? FileHandle(forReadingFrom: url) {
            try? handle.seek(toOffset: reader.offset)
            if let data = try? handle.readToEnd() { reader.read(data) }
            try? handle.close()
        }
        rollouts[url.path] = reader
        watch(url.path)
        return reader.session
    }

    // MARK: OpenCode

    private func openCodeDatabases() -> [String] {
        let dir = UsageService.openCodeDataDir()
        return ["opencode.db", "opencode-next.db"].map { dir.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func readOpenCode(_ paths: [String], now: Date, liveFolders: [String]) -> [ScannedSession] {
        for db in paths {
            watch(db)
            if FileManager.default.fileExists(atPath: db + "-wal") { watch(db + "-wal") }
        }
        guard !paths.isEmpty else { return [] }
        let modified = paths.compactMap { UsageService.modified($0, $0 + "-wal") }.max()
        let stamp = "\(modified?.timeIntervalSince1970 ?? 0) \(liveFolders.sorted())"
        // Nothing changed: the last answer stands (the tracker ages it out by time).
        guard stamp != openCodeStamp else { return openCodeSessions }
        var sessions: [ScannedSession] = []
        var failed = false
        let query = OpenCodeSessions.query(since: now.addingTimeInterval(-FileAgents.activeWindow), directories: liveFolders)
        for db in paths {
            // With pages in the WAL (OpenCode writing), a read-only connection
            // sees them. Otherwise everything is in the main file, and
            // immutable=1 reads it without creating or touching -wal or -shm.
            let walSize = ((try? FileManager.default.attributesOfItem(atPath: db + "-wal"))?[.size] as? NSNumber)?.intValue ?? 0
            let hasShm = FileManager.default.fileExists(atPath: db + "-shm")
            let mode = walSize > 0 && hasShm ? "mode=ro" : "immutable=1"
            let uri = "file:" + (db.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db) + "?" + mode
            guard let data = UsageService.sqlite(uri, query), let read = OpenCodeSessions.parse(data) else {
                failed = true
                continue
            }
            sessions += read
        }
        #if DEBUG
        let line = failed ? "Visor: OpenCode live read failed" : "Visor: OpenCode live read ok, \(sessions.count) recent sessions"
        if line != loggedOpenCode {
            loggedOpenCode = line
            NSLog("%@", line)
        }
        #endif
        // A failed read waits for the next change too, so a database it can't
        // read never costs a sqlite3 run every tick.
        openCodeStamp = stamp
        if failed && sessions.isEmpty { return openCodeSessions }
        openCodeSessions = sessions
        return sessions
    }

    // MARK: Gemini CLI

    /// `$GEMINI_CLI_HOME/.gemini` when set (as Gemini CLI reads it), else `~/.gemini`.
    static var geminiHome: URL {
        let home = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".gemini")
    }

    private static func modified(_ url: URL) -> Date? {
        status(url)?.date
    }

    /// A file's date and size, read fresh with stat (a URL caches its resource values).
    private static func status(_ url: URL) -> (date: Date, size: Int)? {
        var info = Darwin.stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return (Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9), Int(info.st_size))
    }

    /// Chats changed in the last 30 minutes, plus the newest chat of each
    /// project where Gemini CLI runs now. Folders are listed again only when
    /// their date changed; a chat is read again only when its size or date did.
    /// Unverified live: built from Gemini CLI's docs and fixtures.
    private func readGemini(_ tmp: URL, now: Date, liveCwds: [String]) -> [ScannedSession] {
        let fm = FileManager.default
        watch(tmp.path)
        let tmpStamp = Self.modified(tmp) ?? .distantPast
        if geminiFolders?.stamp != tmpStamp {
            let folders = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.isDirectoryKey]))?
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []
            geminiFolders = (tmpStamp, folders)
        }
        var seen = Set<String>()
        var out: [ScannedSession] = []
        for folder in geminiFolders?.folders ?? [] {
            let chats = folder.appendingPathComponent("chats")
            guard let chatsStamp = Self.modified(chats) else { continue }
            if geminiListings[folder.path]?.stamp != chatsStamp {
                let files = ((try? fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)) ?? [])
                    .filter { GeminiChat.isChatFile("tmp/\(folder.lastPathComponent)/chats/\($0.lastPathComponent)") }
                geminiListings[folder.path] = (chatsStamp, files)
                // A new chat may come with a new `.project_root`.
                geminiRoots[folder.path] = nil
            }
            if geminiRoots[folder.path] == nil {
                let root = try? String(contentsOf: folder.appendingPathComponent(".project_root"), encoding: .utf8)
                geminiRoots[folder.path] = .some(root)
            }
            let cwd = GeminiChat.project(folder: folder.lastPathComponent, projectRoot: geminiRoots[folder.path] ?? nil, liveCwds: liveCwds)
            let isLive = !cwd.isEmpty && liveCwds.contains(cwd)
            // Each chat's current date (a resumed chat is written in place,
            // which leaves the folder's date alone). Gemini running in this
            // project makes its newest chat count, however old.
            let dated = (geminiListings[folder.path]?.files ?? []).compactMap { url in
                Self.status(url).map { (url: url, date: $0.date, size: $0.size) }
            }
            let newest = isLive ? dated.max { $0.date < $1.date }?.url : nil
            var active = false
            for chat in dated where chat.url == newest || now.timeIntervalSince(chat.date) <= FileAgents.activeWindow {
                if let session = readGeminiChat(chat.url, date: chat.date, size: chat.size, cwd: cwd) { out.append(session) }
                seen.insert(chat.url.path)
                active = true
            }
            // Only busy projects' folders are watched (an open file each); the
            // 5 s tick finds new chats in the rest.
            if active || isLive { watch(chats.path) } else { unwatch(chats.path) }
        }
        // Chats that went quiet are forgotten, and their watchers closed.
        for path in geminiChats.keys where !seen.contains(path) {
            geminiChats[path] = nil
            unwatch(path)
        }
        return out
    }

    /// One chat: a `.jsonl` read on from where the last read stopped, a `.json` read whole when it changed.
    private func readGeminiChat(_ url: URL, date: Date, size: Int, cwd: String) -> ScannedSession? {
        let stamp = "\(date.timeIntervalSince1970) \(size)"
        let id = url.deletingPathExtension().lastPathComponent
        var reader = geminiChats[url.path]?.reader ?? GeminiChat(id: id)
        if geminiChats[url.path]?.stamp != stamp {
            if url.pathExtension == "jsonl" {
                // A file that shrank was rewritten: read it again from the start.
                if UInt64(size) < reader.offset { reader = GeminiChat(id: id) }
                if UInt64(size) > reader.offset, let handle = try? FileHandle(forReadingFrom: url) {
                    try? handle.seek(toOffset: reader.offset)
                    if let data = try? handle.readToEnd() { reader.read(lines: data) }
                    try? handle.close()
                }
            } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                reader.read(json: data)
            }
            geminiChats[url.path] = (stamp, reader)
        }
        watch(url.path)
        return reader.session(cwd: cwd, fallback: date)
    }

    /// Gemini CLI's folder went away: drop what was read and stop watching.
    private func forgetGemini() -> [ScannedSession] {
        for path in geminiChats.keys { unwatch(path) }
        for path in geminiListings.keys { unwatch(path + "/chats") }
        unwatch(Self.geminiHome.appendingPathComponent("tmp").path)
        geminiChats = [:]
        geminiListings = [:]
        geminiRoots = [:]
        geminiFolders = nil
        return []
    }

    // MARK: Watching

    /// A write, growth, rename or removal of `path` asks for a read. A removed
    /// or renamed file (OpenCode's WAL after a checkpoint) is watched again on the next scan.
    private func watch(_ path: String) {
        guard watchers[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) { self.unwatch(path) }
            self.schedule()
        }
        source.setCancelHandler { close(fd) }
        watchers[path] = source
        source.resume()
    }

    private func unwatch(_ path: String) {
        watchers.removeValue(forKey: path)?.cancel()
    }
}

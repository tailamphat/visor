import Darwin
import Foundation
import VisorCore

/// A Unix socket that agent-hook.sh writes Claude Code hook events to, one JSON
/// line per connection. Most connections are closed as soon as the line is read.
/// A PermissionRequest connection stays open until the user decides; the reply
/// line is what the hook prints back to Claude Code.
final class HookServer: @unchecked Sendable {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Visor", isDirectory: true)
    }
    /// Where the app kept its files when it was called Notchboard.
    static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notchboard", isDirectory: true)
    }

    /// Moves Notchboard's files (bar, Copilot rules, hook script) to Visor's
    /// folder, once. The hooks themselves are re-pointed by HookInstaller.
    static func migrateFromNotchboard() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyDirectory.path), !fm.fileExists(atPath: directory.path) else { return }
        try? fm.moveItem(at: legacyDirectory, to: directory)
        try? fm.removeItem(at: directory.appendingPathComponent("hook.sock"))
    }

    /// Debug builds listen on their own socket, so real agents never reach a
    /// test build: while it runs (and the release is quit), the hook script
    /// finds no socket and the agent asks in its own terminal.
    #if DEBUG
    static var socketPath: String { directory.appendingPathComponent("hook-debug.sock").path }
    #else
    static var socketPath: String { directory.appendingPathComponent("hook.sock").path }
    #endif

    private let queue = DispatchQueue(label: "visor.hooks")
    private var listener: UnixSocketListener?
    /// Open PermissionRequest connections by approval id. Touched on `queue` only.
    private var pending: [UUID: Held] = [:]
    private struct Held {
        var fd: Int32
        var session: String
        /// When it arrived, so a finished call takes the oldest matching card.
        var arrived: UInt64
        /// The exact call, so only it finishing lets the card go.
        var call: ApprovalCall
        var hookPID: Int32
        /// The process that ran the hook (the agent), and the Bash command it
        /// asked to run: once that command starts, it was allowed in the terminal.
        var agentPID: Int32
        var command: String?
    }
    private var watchingHooks = false

    /// Why a held approval went away without an answer from the notch.
    /// `movedOn` names the event that made it moot, for the approvals log.
    enum LetGo { case timedOut, movedOn(String), endedInTerminal, allowedInTerminal }

    /// Called on the main thread for every event, and when an approval goes away
    /// on its own (it timed out or Claude Code moved on).
    var onMessage: (@MainActor (HookMessage, ApprovalRequest?) -> Void)?
    var onApprovalGone: (@MainActor (UUID, LetGo) -> Void)?

    func start() throws {
        listener = try UnixSocketListener(path: Self.socketPath, queue: queue) { [weak self] in self?.read($0) }
    }

    /// Reads one line, then hands it off.
    private func read(_ client: Int32) {
        final class Connection { var buffer = Data(); var handled = false; var held = false }
        let connection = Connection()
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let n = Darwin.read(client, &chunk, chunk.count)
            if n > 0 {
                connection.buffer.append(contentsOf: chunk[0..<n])
                if let newline = connection.buffer.firstIndex(of: 0x0A) {
                    connection.handled = true
                    connection.held = self.handle(line: connection.buffer[..<newline], client: client)
                    source.cancel()
                } else if connection.buffer.count > 4_000_000 {
                    source.cancel()
                }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                // nc half-closes after writing, so EOF can come right after the line.
                if !connection.handled, !connection.buffer.isEmpty {
                    connection.held = self.handle(line: connection.buffer[...], client: client)
                }
                source.cancel()
            }
        }
        // A held approval keeps its socket; reply() or expire() closes it.
        source.setCancelHandler { if !connection.held { close(client) } }
        source.resume()
    }

    /// Returns true when the connection is kept open for an approval.
    private func handle(line: Data, client: Int32) -> Bool {
        guard let message = HookMessage.parse(line) else { return false }
        let approval = ApprovalRequest(message)
        if let approval {
            let command = approval.provider == "claude" && approval.tool == "Bash" ? approval.preview : nil
            pending[approval.id] = Held(fd: client, session: approval.sessionID, arrived: DispatchTime.now().uptimeNanoseconds, call: approval.call,
                                        hookPID: message.hookPID, agentPID: ProcessTree.agentAncestor(of: message.pid), command: command)
            watchHooks()
            // The hook's nc gives up at 110s; let go just before so the card doesn't linger.
            queue.asyncAfter(deadline: .now() + 108) { [weak self] in self?.release(approval.id, .timedOut) }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onMessage?(message, approval) } }
        return approval != nil
    }

    /// Answers a held approval. nil hands the decision back to the terminal.
    /// `sent` runs on main only if the request was still held (not already let go).
    func reply(_ request: ApprovalRequest, _ decision: ApprovalRequest.Decision?, sent: (@MainActor () -> Void)? = nil) {
        queue.async {
            guard let held = self.pending.removeValue(forKey: request.id) else { return }
            if let sent { DispatchQueue.main.async { MainActor.assumeIsolated { sent() } } }
            if let decision {
                let data = request.reply(decision)
                data.withUnsafeBytes { _ = write(held.fd, $0.baseAddress, data.count) }
            }
            close(held.fd)
        }
    }

    /// Lets go of every approval a session holds once it has moved on (its
    /// agent exited). `event` is what made them moot, for the log.
    func releaseApprovals(session: String, event: String) {
        queue.async { self.letGo(session: session, .all, event: event) }
    }

    /// The same for a hook event (`ApprovalRelease`), read here rather than on
    /// main: matching a call serializes its input (a Write's can be large), so
    /// it only happens when the session actually holds an approval.
    func releaseApprovals(after message: HookMessage) {
        queue.async {
            guard let session = message.sessionID, self.pending.values.contains(where: { $0.session == session }),
                  let release = ApprovalRelease.after(message) else { return }
            self.letGo(session: session, release, event: message.event)
        }
    }

    /// queue only.
    private func letGo(session: String, _ release: ApprovalRelease, event: String) {
        let held = pending.filter { $0.value.session == session }.sorted { $0.value.arrived < $1.value.arrived }
        for id in release.releases(from: held.map { (id: $0.key, call: $0.value.call) }) {
            self.release(id, .movedOn(event))
        }
    }

    /// Claude Code stops waiting for the hook when you answer in the terminal.
    /// nc has already half-closed the socket, so a closed connection can't be
    /// seen; instead check four times a second. Denying there ends the hook process;
    /// allowing leaves it running, but the command starts (see TerminalAnswer).
    private func watchHooks() {
        guard !watchingHooks else { return }
        watchingHooks = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.watchingHooks = false
            for (id, held) in self.pending {
                if held.hookPID > 0 && kill(held.hookPID, 0) != 0 && errno == ESRCH {
                    self.release(id, .endedInTerminal)
                } else if let command = held.command, held.agentPID > 1, Self.isRunning(command, under: held.agentPID) {
                    self.release(id, .allowedInTerminal)
                }
            }
            if !self.pending.isEmpty { self.watchHooks() }
        }
    }

    private static func isRunning(_ command: String, under agent: Int32) -> Bool {
        ProcessTree.children(of: agent).contains { pid in
            ProcessTree.arguments(of: pid).map { TerminalAnswer.runs($0, command: command) } ?? false
        }
    }

    /// queue only.
    private func release(_ id: UUID, _ reason: LetGo) {
        guard let held = pending.removeValue(forKey: id) else { return }
        close(held.fd)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onApprovalGone?(id, reason) } }
    }
}

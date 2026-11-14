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
    private var listener: DispatchSourceRead?
    /// Open PermissionRequest connections by approval id. Touched on `queue` only.
    private var pending: [UUID: Held] = [:]
    private struct Held {
        var fd: Int32
        var session: String
        var tool: String
        var hookPID: Int32
        /// The process that ran the hook (the agent), and the Bash command it
        /// asked to run: once that command starts, it was allowed in the terminal.
        var agentPID: Int32
        var command: String?
    }
    private var watchingHooks = false

    /// Why a held approval went away without an answer from the notch.
    enum LetGo { case timedOut, movedOn, endedInTerminal, allowedInTerminal }

    /// Called on the main thread for every event, and when an approval goes away
    /// on its own (it timed out or Claude Code moved on).
    var onMessage: (@MainActor (HookMessage, ApprovalRequest?) -> Void)?
    var onApprovalGone: (@MainActor (UUID, LetGo) -> Void)?

    func start() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = Self.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    private func acceptAll(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            read(client)
        }
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
            pending[approval.id] = Held(fd: client, session: approval.sessionID, tool: approval.tool,
                                        hookPID: message.hookPID, agentPID: ProcessTree.agentAncestor(of: message.pid), command: command)
            watchHooks()
            // The hook's nc gives up at 110s; let go just before so the card doesn't linger.
            queue.asyncAfter(deadline: .now() + 108) { [weak self] in self?.release(approval.id, .timedOut) }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onMessage?(message, approval) } }
        return approval != nil
    }

    /// Answers a held approval. nil hands the decision back to the terminal.
    func reply(_ request: ApprovalRequest, _ decision: ApprovalRequest.Decision?) {
        queue.async {
            guard let held = self.pending.removeValue(forKey: request.id) else { return }
            if let decision {
                let data = request.reply(decision)
                data.withUnsafeBytes { _ = write(held.fd, $0.baseAddress, data.count) }
            }
            close(held.fd)
        }
    }

    /// Lets go of approvals a session is holding (optionally only for one tool)
    /// once it has moved on, e.g. the user answered in the terminal instead.
    func releaseApprovals(session: String, tool: String? = nil) {
        queue.async {
            for (id, held) in self.pending where held.session == session && (tool == nil || held.tool == tool) {
                self.release(id, .movedOn)
            }
        }
    }

    /// Claude Code stops waiting for the hook when you answer in the terminal.
    /// nc has already half-closed the socket, so a closed connection can't be
    /// seen; instead check once a second. Denying there ends the hook process;
    /// allowing leaves it running, but the command starts (see TerminalAnswer).
    private func watchHooks() {
        guard !watchingHooks else { return }
        watchingHooks = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
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

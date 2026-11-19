import AppKit
import Darwin
import Foundation
import VisorCore

/// The Visor Media extension's end in Visor. Each browser with the extension
/// starts a `visor-bridge`, which connects here and stays connected: the
/// extension's tab reports come in as lines, play/pause/skip go back the same way.
final class BrowserBridgeServer: @unchecked Sendable {
    #if DEBUG
    static var socketPath: String { HookServer.directory.appendingPathComponent("browser-debug.sock").path }
    #else
    static var socketPath: String { HookServer.directory.appendingPathComponent("browser.sock").path }
    #endif

    private let queue = DispatchQueue(label: "visor.browser-bridge")
    private var listener: DispatchSourceRead?
    /// Connected bridges by socket, with the browser that started each. `queue` only.
    private var bridges: [Int32: String] = [:]

    /// Main thread: a browser's media tabs, every time they change.
    var onTabs: (@MainActor (_ browser: String, _ tabs: [BrowserBridge.Tab]) -> Void)?
    /// Main thread: a browser's extension went away (browser quit, extension off).
    var onGone: (@MainActor (_ browser: String) -> Void)?

    func start() throws {
        try FileManager.default.createDirectory(at: HookServer.directory, withIntermediateDirectories: true,
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
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
        Self.installHosts()
        // Keep a loaded copy in step with this version of the app.
        if FileManager.default.fileExists(atPath: Self.extensionFolder.path) { Self.copyExtension() }
    }

    /// Sends a command to the tab, through the browser's bridge.
    func send(_ command: BrowserMedia.Command, tab: String, browser: String) {
        let line = BrowserBridge.command(command, tab: tab)
        queue.async {
            for (fd, id) in self.bridges where id == browser {
                line.withUnsafeBytes { _ = write(fd, $0.baseAddress, line.count) }
            }
        }
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

    private func read(_ client: Int32) {
        var buffer = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = Darwin.read(client, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer = Data(buffer[(newline + 1)...])
                    self.handle(line, from: client)
                }
                if buffer.count > 4_000_000 { source.cancel() }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            close(client)
            guard let self, let browser = self.bridges.removeValue(forKey: client) else { return }
            // Another window of the same browser may still be connected.
            guard !self.bridges.values.contains(browser) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onGone?(browser) } }
        }
        source.resume()
    }

    /// queue only.
    private func handle(_ line: Data, from client: Int32) {
        if bridges[client] == nil {
            // The hello: the bridge's parent is the browser.
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "hello", let pid = (object["pid"] as? NSNumber)?.int32Value else { return }
            bridges[client] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "browser.\(pid)"
            return
        }
        guard let browser = bridges[client], let tabs = BrowserBridge.tabs(line) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onTabs?(browser, tabs) } }
    }

    // MARK: Extension

    /// Where the extension is loaded from: a copy outside the app, so it stays
    /// put when the app is replaced. Refreshed from the app on every launch.
    static var extensionFolder: URL { HookServer.directory.appendingPathComponent("Extension", isDirectory: true) }

    @discardableResult
    static func copyExtension() -> URL? {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("Extension"),
              FileManager.default.fileExists(atPath: source.path) else { return nil }
        let fm = FileManager.default
        let target = extensionFolder
        try? fm.removeItem(at: target)
        guard (try? fm.copyItem(at: source, to: target)) != nil else { return nil }
        return target
    }

    // MARK: Host manifests

    /// The helper browsers start: inside the app, or next to a debug build.
    static var bridgePath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/visor-bridge")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("visor-bridge").path
    }

    /// Writes the native messaging host manifest for every installed browser,
    /// so the extension can start the bridge. Rewritten only when it changes
    /// (the app moved, or a debug build ran).
    static func installHosts() {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").path
        let path = bridgePath
        guard fm.isExecutableFile(atPath: path) else { return }
        for dir in BrowserBridge.hostDirectories(support: support, exists: { fm.fileExists(atPath: $0) }) {
            let file = URL(fileURLWithPath: dir.path).appendingPathComponent("\(BrowserBridge.hostName).json")
            let data = BrowserBridge.manifest(path: path, firefox: dir.firefox)
            guard (try? Data(contentsOf: file)) != data else { continue }
            try? fm.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

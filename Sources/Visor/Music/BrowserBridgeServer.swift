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
    private var listener: UnixSocketListener?
    /// Connected bridges by socket, with the browser that started each. `queue` only.
    private var bridges: [Int32: String] = [:]

    /// Main thread: a browser's media tabs, every time they change.
    var onTabs: (@MainActor (_ browser: String, _ tabs: [BrowserBridge.Tab]) -> Void)?
    /// Main thread: a browser's extension went away (browser quit, extension off).
    var onGone: (@MainActor (_ browser: String) -> Void)?

    func start() throws {
        listener = try UnixSocketListener(path: Self.socketPath, queue: queue) { [weak self] in self?.read($0) }
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

    private func read(_ client: Int32) {
        var buffer = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = Darwin.read(client, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    self.handle(Data(buffer[start..<newline]), from: client)
                    start = newline + 1
                }
                if start != buffer.startIndex { buffer = Data(buffer[start...]) }
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

import Foundation
import VisorCore

/// Runs command-line tools and finds them. Blocking: call from a background queue.
enum Shell {
    struct Output {
        var data: Data
        var status: Int32
        var ok: Bool { status == 0 }
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// Runs `path` and waits for it. `mergeStderr` keeps stderr in the output
    /// (`gh auth status` writes there); otherwise it's dropped. A `timeout`
    /// stops a stuck tool. Nil when it couldn't start.
    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil,
                    mergeStderr: Bool = false, timeout: TimeInterval? = nil) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let stop = timeout.map { seconds -> DispatchSourceTimer in
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler { process.terminate() }
            timer.resume()
            return timer
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop?.cancel()
        return Output(data: data, status: process.terminationStatus)
    }

    /// Runs `path` with a hard deadline and capped output (stdout and stderr):
    /// nil when it couldn't start, didn't exit in `timeout`, or its pipe was
    /// still held open then (a grandchild). For tools that may hang, like a
    /// CLI's `--version` behind an npm wrapper.
    static func probe(_ path: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return nil }
        guard let data = BoundedOutput.collect(pipe.fileHandleForReading, exited: exited, timeout: timeout) else {
            if process.isRunning { process.terminate() }
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Starts `path` without waiting for it.
    static func launch(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }

    /// Where a tool is installed: the usual places, since an app doesn't get the login shell's PATH.
    static func which(_ name: String) -> String? {
        ToolLocator.candidates(name, home: FileManager.default.homeDirectoryForCurrentUser.path)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

import Darwin
import Foundation
import VisorCore

// The browser starts this for the Visor Media extension (native messaging) and
// talks to it over stdin/stdout. Each message from the extension goes to Visor
// as one line on its browser socket; each line from Visor goes back framed.
// The first line says which process started it, so Visor knows the browser.
// It ends when the browser closes stdin or Visor goes away.

let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Visor")

/// The debug build's socket first: it's only there while a test build runs.
func connectToVisor() -> Int32? {
    for name in ["browser-debug.sock", "browser.sock"] {
        let path = support.appendingPathComponent(name).path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { continue }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); continue }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected == 0 { return fd }
        close(fd)
    }
    return nil
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

var on: Int32 = 1
guard let visor = connectToVisor() else { exit(1) }
setsockopt(visor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
_ = writeAll(visor, Data(#"{"type":"hello","pid":\#(getppid())}"#.utf8) + Data([0x0A]))

// Visor -> browser, on its own thread.
Thread.detachNewThread {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 16_384)
    while true {
        let n = read(visor, &chunk, chunk.count)
        if n <= 0 { exit(0) }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[(newline + 1)...])
            if !line.isEmpty, !writeAll(STDOUT_FILENO, NativeMessaging.frame(line)) { exit(0) }
        }
    }
}

// Browser -> Visor.
var buffer = Data()
var chunk = [UInt8](repeating: 0, count: 65_536)
while true {
    let n = read(STDIN_FILENO, &chunk, chunk.count)
    if n <= 0 { exit(0) }
    buffer.append(contentsOf: chunk[0..<n])
    for message in NativeMessaging.unframe(&buffer) {
        // One line each: the extension's JSON never holds a raw newline.
        if !writeAll(visor, message + Data([0x0A])) { exit(0) }
    }
}

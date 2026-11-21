import Darwin
import Foundation

/// A listening Unix socket only this user can reach (0600, in a 0700 folder).
/// Each client arrives non-blocking, with SIGPIPE off, on `queue`.
final class UnixSocketListener {
    private let source: DispatchSourceRead

    /// Replaces any old socket at `path`. `onClient` runs on `queue` and owns the descriptor.
    init(path: String, queue: DispatchQueue, onClient: @escaping (Int32) -> Void) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
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
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(client, F_SETFL, O_NONBLOCK)
                onClient(client)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

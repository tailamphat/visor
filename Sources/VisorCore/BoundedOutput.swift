import Foundation

/// Reads a child's output with a hard deadline and a cap. Unlike waiting for
/// end of file, a grandchild that keeps the pipe open (an npm wrapper starting
/// the real binary) can't hold the caller past the deadline.
public enum BoundedOutput {
    public static let maxOutput = 16_384

    /// Waits until `exited` is signalled and the pipe ends, both within
    /// `timeout`; nil if either doesn't happen. At most `maxOutput` bytes.
    public static func collect(_ reader: FileHandle, exited: DispatchSemaphore, timeout: TimeInterval) -> Data? {
        let output = Output()
        let finished = DispatchSemaphore(value: 0)
        // Its own thread: if the pipe never ends, only this read waits.
        Thread.detachNewThread {
            while let chunk = try? reader.read(upToCount: 4096), !chunk.isEmpty {
                output.append(chunk)
            }
            finished.signal()
        }
        let deadline = DispatchTime.now() + timeout
        guard exited.wait(timeout: deadline) == .success, finished.wait(timeout: deadline) == .success else { return nil }
        return output.data
    }

    private final class Output: @unchecked Sendable {
        private var bytes = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) {
            lock.withLock { if bytes.count < BoundedOutput.maxOutput { bytes.append(chunk.prefix(BoundedOutput.maxOutput - bytes.count)) } }
        }
        var data: Data { lock.withLock { bytes } }
    }
}

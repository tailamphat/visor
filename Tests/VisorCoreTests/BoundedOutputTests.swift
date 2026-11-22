import Foundation
import Testing
@testable import VisorCore

@Suite("Bounded output")
struct BoundedOutputTests {
    func exited(_ done: Bool) -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        if done { semaphore.signal() }
        return semaphore
    }

    @Test func readsUntilEnd() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("codex-cli 0.63.0\n".utf8))
        try? pipe.fileHandleForWriting.close()
        #expect(BoundedOutput.collect(pipe.fileHandleForReading, exited: exited(true), timeout: 2) == Data("codex-cli 0.63.0\n".utf8))
    }

    /// The process never exits: back by the deadline.
    @Test func timesOutWhenProcessNeverExits() {
        let pipe = Pipe()
        let start = Date()
        #expect(BoundedOutput.collect(pipe.fileHandleForReading, exited: exited(false), timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        _ = pipe
    }

    /// It exited, but something (a grandchild) still holds the pipe open.
    @Test func timesOutWhenPipeStaysOpen() {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("1.2.3\n".utf8))
        let start = Date()
        #expect(BoundedOutput.collect(pipe.fileHandleForReading, exited: exited(true), timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        try? pipe.fileHandleForWriting.close()
    }

    @Test func capsOutput() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        Thread.detachNewThread {
            writer.write(Data(repeating: 0x61, count: 200_000))
            try? writer.close()
        }
        let data = try #require(BoundedOutput.collect(pipe.fileHandleForReading, exited: exited(true), timeout: 5))
        #expect(data.count == BoundedOutput.maxOutput)
    }
}

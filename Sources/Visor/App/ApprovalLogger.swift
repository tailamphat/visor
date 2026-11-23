import Foundation
import VisorCore

/// ~/Library/Logs/Visor/approvals.log (debug builds: approvals-debug.log): one
/// line when a request arrives and one when it ends, so a card that never
/// showed can be traced. Only agent, project folder, tool and outcome are
/// written (`ApprovalLog`). Writes run on their own queue; the file starts over
/// once it passes 256 KB, checked on every write (approvals are rare).
final class ApprovalLogger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "visor.approvals.log", qos: .utility)
    // Only touched on `queue`.
    private var handle: FileHandle?

    static var url: URL {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Visor")
        #if DEBUG
        return logs.appendingPathComponent("approvals-debug.log")
        #else
        return logs.appendingPathComponent("approvals.log")
        #endif
    }

    func write(_ request: ApprovalRequest, _ outcome: String) {
        let line = ApprovalLog.line(request, outcome, at: Date())
        queue.async { [self] in
            if handle == nil {
                let fm = FileManager.default
                let url = Self.url
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
            }
            if let end = try? handle?.seekToEnd(), end > 256_000 { try? handle?.truncate(atOffset: 0) }
            handle?.write(Data(line.utf8))
        }
    }
}

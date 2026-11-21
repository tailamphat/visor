import Foundation
import Testing
@testable import VisorCore

@Suite("Clash warning")
struct ClashTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let file = "/Users/me/web-shop/src/total.ts"

    /// Two sessions editing the same file within 10 minutes: one clash, reported once.
    @Test func twoSessionsSameFile() {
        var watch = ClashWatch()
        #expect(watch.record(session: "a", agent: "Claude Code", path: file, at: t0) == nil)
        #expect(watch.record(session: "a", agent: "Claude Code", path: file, at: t0.addingTimeInterval(30)) == nil, "the same session is no clash")
        let clash = watch.record(session: "b", agent: "Copilot CLI", path: file, at: t0.addingTimeInterval(60))
        #expect(clash?.path == file && clash?.agents == ["Claude Code", "Copilot CLI"] && clash?.sessions == ["a", "b"])
        #expect(watch.record(session: "a", agent: "Claude Code", path: file, at: t0.addingTimeInterval(90)) == nil, "one peek per clash")
        #expect(watch.active(at: t0.addingTimeInterval(120)).count == 1)
    }

    /// Edits more than 10 minutes apart, or on different files, don't clash.
    @Test func farApartOrDifferentFiles() {
        var watch = ClashWatch()
        _ = watch.record(session: "a", agent: "Claude Code", path: file, at: t0)
        #expect(watch.record(session: "b", agent: "Claude Code", path: file, at: t0.addingTimeInterval(601)) == nil)
        #expect(watch.record(session: "c", agent: "Claude Code", path: "/Users/me/web-shop/src/cart.ts", at: t0.addingTimeInterval(602)) == nil)
    }

    /// A clash lasts until neither session has touched the file for 10 minutes, or it's dismissed.
    @Test func expiresAndDismisses() {
        var watch = ClashWatch()
        _ = watch.record(session: "a", agent: "Claude Code", path: file, at: t0)
        let clash = watch.record(session: "b", agent: "Copilot CLI", path: file, at: t0.addingTimeInterval(60))!
        #expect(watch.active(at: t0.addingTimeInterval(659)).count == 1)
        #expect(watch.active(at: t0.addingTimeInterval(661)).isEmpty)
        #expect(watch.nextChange(after: t0.addingTimeInterval(100)) == t0.addingTimeInterval(660))
        var other = ClashWatch()
        _ = other.record(session: "a", agent: "Claude Code", path: file, at: t0)
        _ = other.record(session: "b", agent: "Copilot CLI", path: file, at: t0.addingTimeInterval(60))
        other.dismiss(clash)
        #expect(other.active(at: t0.addingTimeInterval(120)).isEmpty)
        #expect(other.record(session: "b", agent: "Copilot CLI", path: file, at: t0.addingTimeInterval(130)) == nil, "dismissed stays quiet")
    }

    /// Which file an event edits: only changes count, not reads.
    @Test func onlyEditsCount() {
        func message(_ tool: String, _ input: [String: Any]) -> HookMessage {
            HookMessage(event: "PreToolUse", pid: 1, payload: ["session_id": "a", "tool_name": tool, "tool_input": input])
        }
        #expect(TurnStats.editedPath(message("Edit", ["file_path": file])) == file)
        #expect(TurnStats.editedPath(message("Write", ["file_path": file])) == file)
        #expect(TurnStats.editedPath(message("Read", ["file_path": file])) == nil)
        #expect(TurnStats.editedPath(message("Bash", ["command": "cat \(file)"])) == nil)
    }
}
